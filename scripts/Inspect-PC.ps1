<#
.SYNOPSIS
  Inspects the local Windows PC's hardware/OS against the target spec
  (Intel Core i5, 14th generation; 8GB RAM; 256GB SSD; Windows, activated),
  makes sure the network (Wi-Fi) drivers work and Wi-Fi is configured,
  and uploads one record to a shared Google Sheet via an Apps Script webhook.

.USAGE
  Easiest: double-click PC-Inspection.exe on the flash disk. It runs this
  script as admin with -FlashRoot set to the flash disk folder.

  Manual (admin PowerShell): .\Inspect-PC.ps1 -FlashRoot E:\

  Every run also appends to a local CSV (inspection-log.csv on the flash
  disk) so nothing is lost even if the upload fails (e.g. no internet -
  the backup rows can be pasted into the Sheet later).
#>

param(
    [string]$FlashRoot    = $PSScriptRoot,
    [string]$WebhookUrl,
    [string]$Inspector,
    [string]$ConfigPath,
    [string]$InspectorCachePath,
    [string]$LogPath,
    [string]$DriversDir,
    [switch]$SkipNetwork,
    [switch]$NoUpload
)

if (-not $ConfigPath)         { $ConfigPath         = Join-Path $FlashRoot 'config.json' }
if (-not $InspectorCachePath) { $InspectorCachePath = Join-Path $FlashRoot 'inspector-name.txt' }
if (-not $LogPath)            { $LogPath            = Join-Path $FlashRoot 'inspection-log.csv' }
if (-not $DriversDir)         { $DriversDir         = Join-Path $FlashRoot 'drivers' }

. (Join-Path $PSScriptRoot 'Setup-Network.ps1')

$config = [PSCustomObject]@{}
if (Test-Path $ConfigPath) {
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "config.json is not valid JSON ($($_.Exception.Message)). Fix it and run again." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "No config.json found at $ConfigPath - Wi-Fi setup and upload will be skipped." -ForegroundColor Yellow
}
if (-not $WebhookUrl) { $WebhookUrl = $config.WebhookUrl }

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "            PC INSPECTION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# --- Who is inspecting? Pick from the "Inspectors" list in config.json
# (or type a name). The last one used is remembered; Enter keeps it. ---
if (-not $Inspector) {
    $lastInspector = ''
    if (Test-Path $InspectorCachePath) {
        $lastInspector = (Get-Content $InspectorCachePath -Raw).Trim()
    }
    $names = @($config.Inspectors | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() })

    while (-not $Inspector) {
        if ($names.Count -gt 0) {
            Write-Host "`nWho is inspecting?" -ForegroundColor Cyan
            for ($i = 0; $i -lt $names.Count; $i++) {
                $mark = if ($names[$i] -eq $lastInspector) { '  <- last used' } else { '' }
                Write-Host ("  {0,2}) {1}{2}" -f ($i + 1), $names[$i], $mark)
            }
            Write-Host "   0) Someone else (type name)"
            $prompt = if ($lastInspector) { "Number [Enter = $lastInspector]" } else { 'Number' }
            $typed = (Read-Host $prompt).Trim()
            $num = 0
            if (-not $typed) {
                $Inspector = $lastInspector
            } elseif ([int]::TryParse($typed, [ref]$num)) {
                if ($num -ge 1 -and $num -le $names.Count) { $Inspector = $names[$num - 1] }
                elseif ($num -eq 0) { $Inspector = (Read-Host 'Type your name').Trim() }
                else { Write-Host "  Pick a number from the list." -ForegroundColor Yellow }
            } else {
                $Inspector = $typed   # typed a name directly
            }
        } else {
            $prompt = if ($lastInspector) { "Inspector name [Enter = $lastInspector]" } else { 'Enter your name (inspector)' }
            $typed = (Read-Host $prompt).Trim()
            $Inspector = if ($typed) { $typed } else { $lastInspector }
        }
    }
    Write-Host "  Inspector: $Inspector" -ForegroundColor Green
    if ($Inspector -ne $lastInspector) {
        try { $Inspector | Out-File -FilePath $InspectorCachePath -Encoding UTF8 -NoNewline } catch {}
    }
}

# --- Network drivers + Wi-Fi (before the spec checks, so upload works) ---
if ($SkipNetwork) {
    $network = [ordered]@{ wifiAdapter = ''; wifiDriverVersion = ''; networkDriverStatus = 'Skipped'; wifiConnected = ''; internetOk = (Test-InternetConnection) }
} else {
    $network = Invoke-NetworkSetup -Config $config -DriversDir $DriversDir
}

Write-Host "`n[2/3] Hardware & Windows checks" -ForegroundColor Cyan

function Get-CpuSpecStatus {
    param([string]$CpuName)

    # Target: Intel Core i5, 14th generation (e.g. i5-14400, i5-1440P, "14th Gen Intel(R) Core(TM) i5-...")
    $is14thGenI5 = ($CpuName -match 'i5-14\d{2}') -or ($CpuName -match '14th Gen.*i5')
    if ($is14thGenI5) { return 'Meets spec (i5, 14th gen)' }

    $genMatch = [regex]::Match($CpuName, 'i([3579])-(\d{1,2})\d{3}')
    if ($genMatch.Success) {
        $tier = [int]$genMatch.Groups[1].Value
        $gen  = [int]$genMatch.Groups[2].Value

        if ($tier -eq 5) {
            if ($gen -lt 14) { return "Below spec (i5, ${gen}th gen)" }
            else { return "Above spec (i5, ${gen}th gen)" }
        } elseif ($tier -lt 5) {
            return "Below spec (i$tier, ${gen}th gen)"
        } else {
            return "Above spec (i$tier, ${gen}th gen)"
        }
    }

    return "Unknown - verify manually ($CpuName)"
}

function Get-RamSpecStatus {
    param([double]$RamGB)

    # Windows reports a bit less than a stick's labeled size (some is
    # reserved for the BIOS/integrated graphics), so an "8GB" machine often
    # reads as ~7.7GB. Snap to the nearest standard RAM size instead of
    # comparing the raw reading exactly, same approach as the disk check.
    $standardSizesGB = 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128
    $closest = $standardSizesGB | Sort-Object { [math]::Abs($_ - $RamGB) } | Select-Object -First 1

    if ($closest -lt 8) { return "Below spec (~${closest}GB RAM, raw ${RamGB}GB)" }
    elseif ($closest -eq 8) { return "Meets spec (8GB)" }
    else { return "Above spec (~${closest}GB RAM, raw ${RamGB}GB)" }
}

function Get-PrimaryDiskSizeGB {
    # Disks report raw bytes a bit under their marketed decimal-GB capacity
    # (e.g. a "256GB" SSD reports ~256,060,514,304 bytes), so divide by
    # 1000^3, not 1024^3, to land on the label the box was sold with.
    try {
        $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
        return [math]::Round($disk.Size / 1000000000, 0)
    } catch {
        try {
            $drive = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1
            return [math]::Round($drive.Size / 1000000000, 0)
        } catch {
            return $null
        }
    }
}

function Get-DiskSpecStatus {
    param($DiskGB)

    if ($null -eq $DiskGB) { return "Unknown - verify manually" }

    # Snap the raw reading to the nearest standard drive size so e.g. 238GB
    # raw (a genuine 256GB SSD) doesn't read as "below spec".
    $standardSizesGB = 64, 120, 128, 240, 250, 256, 480, 500, 512, 960, 1000, 1024, 2000, 2048
    $closest = $standardSizesGB | Sort-Object { [math]::Abs($_ - $DiskGB) } | Select-Object -First 1

    if ($closest -lt 256) { return "Below spec (~${closest}GB disk, raw ${DiskGB}GB)" }
    elseif ($closest -eq 256) { return "Meets spec (256GB)" }
    else { return "Above spec (~${closest}GB disk, raw ${DiskGB}GB)" }
}

function Get-PrimaryDiskMediaType {
    try {
        $physicalDisk = Get-Partition -DriveLetter C -ErrorAction Stop |
            Get-Disk -ErrorAction Stop |
            Get-PhysicalDisk -ErrorAction Stop |
            Select-Object -First 1
        if ($physicalDisk -and $physicalDisk.MediaType -and $physicalDisk.MediaType -ne 'Unspecified') {
            return [string]$physicalDisk.MediaType
        }
    } catch {}
    try {
        $physicalDisk = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        if ($physicalDisk -and $physicalDisk.MediaType -and $physicalDisk.MediaType -ne 'Unspecified') {
            return [string]$physicalDisk.MediaType
        }
    } catch {}
    return $null
}

function Get-DiskTypeStatus {
    param([string]$MediaType)

    if (-not $MediaType) { return "Unknown - verify manually" }
    if ($MediaType -eq 'SSD') { return 'Meets spec (SSD)' }
    return "Below spec ($MediaType, not SSD)"
}

function Get-WindowsActivationStatus {
    # ApplicationID below is the fixed "Windows activation technologies" ID,
    # used to filter out any non-Windows entries (e.g. Office) in the table.
    try {
        $product = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        if ($product) {
            $statusMap = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine Grace'; 5 = 'Notification'; 6 = 'Extended Grace' }
            $label = $statusMap[[int]$product.LicenseStatus]
            if ($label) { return $label }
        }
    } catch {}
    return 'Unknown - verify manually (run slmgr /xpr)'
}

function Write-SpecLine {
    param([string]$Label, [string]$Status, [string]$Detail = $Status)

    $color = switch -Wildcard ($Status) {
        'Meets spec*' { 'Green' }
        'Below spec*' { 'Red' }
        'Above spec*' { 'Yellow' }
        default       { 'DarkYellow' }
    }
    Write-Host ("  {0,-12}: {1}" -f $Label, $Detail) -ForegroundColor $color
}

function Write-BoolLine {
    param([string]$Label, [bool]$Pass, [string]$Detail)

    $color = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f $Label, $Detail) -ForegroundColor $color
}

# --- Gather hardware/OS info ---
$bios = Get-CimInstance Win32_BIOS
$cs   = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

$serialNumber = $bios.SerialNumber.Trim()
$hostname     = $env:COMPUTERNAME
$cpuModel     = $cpu.Name.Trim()
$ramGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$osCaption    = $os.Caption
$osBuild      = $os.BuildNumber
$isWindows    = $osCaption -match 'Windows'

Write-Host "`nInspecting $hostname (serial: $serialNumber) as $Inspector..." -ForegroundColor Cyan
Write-BoolLine "OS" $isWindows $osCaption

# Best-effort "new / unused" check: disk power-on hours (when the storage
# driver exposes reliability counters) plus OS install date as a fallback
# signal. This cannot prove a machine is factory-new - flag for manual
# confirmation when the signal is unavailable.
$installDate = $os.InstallDate
$daysSinceInstall = if ($installDate) { (New-TimeSpan -Start $installDate -End (Get-Date)).Days } else { $null }

$powerOnHours = $null
try {
    $counters = Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
    if ($counters) {
        $powerOnHours = ($counters | Where-Object { $_.PowerOnHours -ne $null } | Measure-Object -Property PowerOnHours -Minimum).Minimum
    }
} catch {
    $powerOnHours = $null
}

if ($null -ne $powerOnHours) {
    $condition = if ($powerOnHours -le 24) { "Likely new (disk power-on hours: $powerOnHours)" }
                 else { "Likely used (disk power-on hours: $powerOnHours)" }
} elseif ($null -ne $daysSinceInstall) {
    $condition = "Unverified - manual check needed (Windows installed $daysSinceInstall day(s) ago)"
} else {
    $condition = "Unverified - manual check needed"
}
$conditionColor = if ($condition -like 'Likely new*') { 'Green' } elseif ($condition -like 'Likely used*') { 'Gray' } else { 'DarkYellow' }
Write-Host ("  {0,-12}: {1}" -f "Condition", $condition) -ForegroundColor $conditionColor

$activationStatus = Get-WindowsActivationStatus
$isActivated    = $activationStatus -eq 'Licensed'
Write-BoolLine "Activation" $isActivated $activationStatus

$cpuSpecStatus  = Get-CpuSpecStatus -CpuName $cpuModel
Write-SpecLine "CPU" $cpuSpecStatus "$cpuModel -> $cpuSpecStatus"

$ramSpecStatus  = Get-RamSpecStatus -RamGB $ramGB
Write-SpecLine "RAM" $ramSpecStatus "${ramGB}GB -> $ramSpecStatus"

$diskGB         = Get-PrimaryDiskSizeGB
$diskSpecStatus = Get-DiskSpecStatus -DiskGB $diskGB
Write-SpecLine "Disk size" $diskSpecStatus

$diskMediaType  = Get-PrimaryDiskMediaType
$diskTypeStatus = Get-DiskTypeStatus -MediaType $diskMediaType
Write-SpecLine "Disk type" $diskTypeStatus "$diskMediaType -> $diskTypeStatus"

# "Above spec" (e.g. a 512GB disk when 256GB is the minimum) is a pass, not
# a failure - only "Below spec" (and unreadable/"Unknown") statuses count
# against a PC. Everything else exceeds or meets the requirement.
function Test-SpecOk {
    param([string]$Status)
    return ($Status -like 'Meets spec*') -or ($Status -like 'Above spec*')
}

# A PC must have a working Wi-Fi card + network drivers unless config.json
# sets "RequireWifi": false.
$requireWifi = $config.RequireWifi -ne $false
$networkOk = $SkipNetwork -or (-not $requireWifi) -or ($network.wifiAdapter -and $network.networkDriverStatus -eq 'OK')

$overallPass = $isWindows -and $isActivated -and $networkOk -and
    (Test-SpecOk $cpuSpecStatus) -and
    (Test-SpecOk $ramSpecStatus) -and
    (Test-SpecOk $diskSpecStatus) -and
    (Test-SpecOk $diskTypeStatus)
$overallResult = if ($overallPass) { 'PASS' } else { 'FAIL' }

$notes = @()
if (-not $isWindows) { $notes += "OS is not Windows ($osCaption)" }
if (-not $isActivated) { $notes += "Windows not activated ($activationStatus)" }
if (-not $networkOk) { $notes += "Network: $($network.networkDriverStatus)" }
if (-not (Test-SpecOk $cpuSpecStatus)) { $notes += $cpuSpecStatus }
if (-not (Test-SpecOk $ramSpecStatus)) { $notes += $ramSpecStatus }
if (-not (Test-SpecOk $diskSpecStatus)) { $notes += $diskSpecStatus }
if (-not (Test-SpecOk $diskTypeStatus)) { $notes += $diskTypeStatus }
if ($condition -like 'Unverified*') { $notes += 'Condition needs manual confirmation' }
$notesText = ($notes -join '; ')

$overallColor = if ($overallPass) { 'Green' } else { 'Red' }
Write-Host ("`n  === OVERALL: {0} ===" -f $overallResult) -ForegroundColor $overallColor
if ($notesText) { Write-Host "  Reasons: $notesText" -ForegroundColor Yellow }

$record = [ordered]@{
    timestamp         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    inspector         = $Inspector
    serialNumber      = $serialNumber
    hostname          = $hostname
    os                = $osCaption
    osBuild           = $osBuild
    activationStatus  = $activationStatus
    cpuModel          = $cpuModel
    cpuSpecStatus     = $cpuSpecStatus
    ramGB             = $ramGB
    ramSpecStatus     = $ramSpecStatus
    diskGB            = $diskGB
    diskSpecStatus    = $diskSpecStatus
    diskMediaType     = $diskMediaType
    diskTypeStatus    = $diskTypeStatus
    condition         = $condition
    diskPowerOnHours  = $powerOnHours
    overallResult     = $overallResult
    notes             = $notesText
    wifiAdapter       = $network.wifiAdapter
    wifiDriverVersion = $network.wifiDriverVersion
    networkDriverStatus = $network.networkDriverStatus
    wifiConnected     = $network.wifiConnected
    internetOk        = [bool]$network.internetOk
}

# --- Local backup log (always written, even if the upload fails) ---
try {
    [PSCustomObject]$record | Export-Csv -Path $LogPath -Append -Force -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host "  Logged to: $LogPath" -ForegroundColor DarkGray
} catch {
    Write-Warning "  Could not write $LogPath ($($_.Exception.Message))"
}

# --- Upload to Google Sheet ---
# Rows that could not be uploaded (no internet) wait in pending-uploads.txt
# on the flash disk, one JSON row per line, and are sent automatically the
# next time any PC is online.
$pendingPath = Join-Path $FlashRoot 'pending-uploads.txt'

function Send-InspectionRow {
    # Returns 'ok', 'duplicate:<message>' or throws on network/server error.
    param([string]$Json)
    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -TimeoutSec 30 `
        -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -ContentType 'application/json; charset=utf-8'
    if ($response.status -eq 'duplicate') { return "duplicate:$($response.message)" }
    return 'ok'
}

Write-Host "`n[3/3] Saving result" -ForegroundColor Cyan
if ($NoUpload) {
    Write-Host "  Upload skipped (-NoUpload).`n" -ForegroundColor DarkGray
} elseif (-not $WebhookUrl) {
    Write-Host "  No WebhookUrl in config.json - result only saved to $LogPath`n" -ForegroundColor Yellow
} else {
    # 1) Older rows waiting from offline PCs
    if (Test-Path $pendingPath) {
        $stillPending = @()
        $sent = 0
        foreach ($line in (Get-Content $pendingPath -Encoding UTF8 | Where-Object { $_.Trim() })) {
            try { Send-InspectionRow $line | Out-Null; $sent++ } catch { $stillPending += $line }
        }
        if ($stillPending.Count) { $stillPending | Set-Content $pendingPath -Encoding UTF8 }
        else { Remove-Item $pendingPath -ErrorAction SilentlyContinue }
        if ($sent) { Write-Host "  Sent $sent saved result(s) from earlier offline PCs." -ForegroundColor Green }
    }

    # 2) This PC
    $json = $record | ConvertTo-Json -Depth 3 -Compress
    try {
        $status = Send-InspectionRow $json
        if ($status -like 'duplicate:*') {
            Write-Host "  NOT SAVED: $($status.Substring(10))`n" -ForegroundColor Red
        } else {
            Write-Host "  Uploaded to Google Sheet.`n" -ForegroundColor Green
        }
    } catch {
        try { Add-Content -Path $pendingPath -Value $json -Encoding UTF8 } catch {}
        Write-Warning "  Upload FAILED - saved on the flash disk, it will upload automatically the next time a PC is online. Error: $($_.Exception.Message)"
        Write-Host ""
    }
}

if ($overallPass) { exit 0 } else { exit 2 }
