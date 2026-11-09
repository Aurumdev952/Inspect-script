<#
.SYNOPSIS
  Inspects a delivered laptop against the Lot 2 laptops contract
  (000008/G/ICB/2024/2025/RISA, SALTEL, Amendment No. 2): categories 5-8 and
  their approved alternative models, specs in Lot2-Spec.ps1. Makes sure the
  Wi-Fi driver works and Wi-Fi is configured, and uploads one record to a
  shared Google Sheet via an Apps Script webhook.

.USAGE
  Easiest: double-click PC-Inspection.exe on the flash disk. It runs this
  script as admin with -FlashRoot set to the flash disk folder.

  Manual (admin PowerShell): .\Inspect-PC.ps1 -FlashRoot E:\

  Every run also appends to a local CSV (inspection-log.csv) with an
  "uploadStatus" column, so a result is never lost even if the upload fails.
  Every run is uploaded once, by the PC that made it, as a NEW row. A PC that
  is inspected again (e.g. after a Wi-Fi card was added) gets a new row; the
  Sheet numbers them in its "Inspection #" column. Nothing is queued or
  re-sent later, so old failed uploads can't come back as duplicates.
#>

param(
    [string]$FlashRoot    = $PSScriptRoot,
    # Set by the launcher when it copied itself from the flash disk to this
    # PC: the flash disk folder, so results can be copied back at the end.
    [string]$UsbRoot,
    [string]$WebhookUrl,
    [string]$Inspector,
    [string]$ConfigPath,
    [string]$InspectorCachePath,
    [string]$LogPath,
    [string]$DriversDir,
    [string]$ToolVersion = 'dev',
    [switch]$SkipNetwork,
    [switch]$NoUpload
)

if (-not $ConfigPath)         { $ConfigPath         = Join-Path $FlashRoot 'config.json' }
if (-not $InspectorCachePath) { $InspectorCachePath = Join-Path $FlashRoot 'inspector-name.txt' }
if (-not $LogPath)            { $LogPath            = Join-Path $FlashRoot 'inspection-log.csv' }
if (-not $DriversDir)         { $DriversDir         = Join-Path $FlashRoot 'drivers' }

. (Join-Path $PSScriptRoot 'Setup-Network.ps1')
. (Join-Path $PSScriptRoot 'Lot2-Spec.ps1')

$ProgressPreference = 'SilentlyContinue'   # progress bars make web calls and zips much slower
$runTimer = [Diagnostics.Stopwatch]::StartNew()
$runStarted = Get-CatTime
$logsDir  = Join-Path $FlashRoot 'logs'
$runId    = "{0:yyyyMMdd-HHmmss}-{1}" -f $runStarted, $env:COMPUTERNAME
$transcriptPath = Join-Path $logsDir "run-$runId.txt"
$script:DetailLogPath = Join-Path $logsDir "detail-$runId.txt"
try {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    Start-Transcript -Path $transcriptPath -Force | Out-Null
} catch { $transcriptPath = $null }
Write-DetailLog ("RUN START id=$runId version=$ToolVersion computer=$env:COMPUTERNAME user=$env:USERNAME flashRoot=$FlashRoot usbRoot=$UsbRoot args: inspector='$Inspector' skipNetwork=$SkipNetwork noUpload=$NoUpload")
try { Write-DetailLog ("OS: " + (Get-CimInstance Win32_OperatingSystem).Caption + " build " + [Environment]::OSVersion.Version) } catch {}

# --- usage log: one line per run (kept forever, never cleaned up) ---
$usageColumns = 'runId','startedCAT','toolVersion','computer','serialNumber','inspector','overallResult','uploadStatus','wifiAdapter','wifiConnected','internetOk','seconds','exitCode','source','logFile'
$script:UsageWritten = $false
$script:UsageCtx = @{ serialNumber = ''; inspector = ''; overallResult = ''; uploadStatus = ''; wifiAdapter = ''; wifiConnected = ''; internetOk = '' }

function Write-UsageRow {
    param([string]$Outcome, [int]$ExitCode)
    if ($script:UsageWritten) { return }
    $script:UsageWritten = $true
    $row = [ordered]@{
        runId = $runId; startedCAT = $runStarted.ToString('yyyy-MM-dd HH:mm:ss'); toolVersion = $ToolVersion
        computer = $env:COMPUTERNAME; serialNumber = $script:UsageCtx.serialNumber; inspector = $script:UsageCtx.inspector
        overallResult = $(if ($script:UsageCtx.overallResult) { $script:UsageCtx.overallResult } else { $Outcome })
        uploadStatus = $script:UsageCtx.uploadStatus; wifiAdapter = $script:UsageCtx.wifiAdapter
        wifiConnected = $script:UsageCtx.wifiConnected; internetOk = $script:UsageCtx.internetOk
        seconds = [int]$runTimer.Elapsed.TotalSeconds; exitCode = $ExitCode
        source = $(if ($UsbRoot) { 'flash-disk' } else { 'direct' }); logFile = $(if ($transcriptPath) { Split-Path $transcriptPath -Leaf } else { '' })
    }
    try { [PSCustomObject]$row | Export-Csv -Path (Join-Path $logsDir 'usage-log.csv') -Append -Force -NoTypeInformation -Encoding UTF8 -ErrorAction Stop } catch {}
    Write-DetailLog "RUN END outcome=$Outcome exit=$ExitCode seconds=$([int]$runTimer.Elapsed.TotalSeconds)"
    return [PSCustomObject]$row
}

# Anything unexpected is written to the logs instead of vanishing with the window.
trap {
    Write-Host "  Something unexpected went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  The details are saved in the run log: $logsDir" -ForegroundColor Yellow
    Write-DetailLog ("UNEXPECTED ERROR: " + $_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace)
    [void](Write-UsageRow -Outcome 'crashed' -ExitCode 1)
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function Write-Took {
    param([string]$What, [Diagnostics.Stopwatch]$Watch)
    Write-Host ("  ({0}: {1:N0}s)" -f $What, $Watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

$config = [PSCustomObject]@{}
if (Test-Path $ConfigPath) {
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "config.json is not valid JSON ($($_.Exception.Message)). Fix it and run again." -ForegroundColor Red
        Write-DetailLog "config.json invalid: $($_.Exception.Message)"
        [void](Write-UsageRow -Outcome 'config-error' -ExitCode 1)
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
} else {
    Write-Host "No config.json found at $ConfigPath - Wi-Fi setup and upload will be skipped." -ForegroundColor Yellow
}
if (-not $WebhookUrl) { $WebhookUrl = $config.WebhookUrl }
if ($null -ne $config.TimeZoneOffsetHours) { $script:TzOffsetHours = [double]$config.TimeZoneOffsetHours }
Write-DetailLog ("Config: webhook " + $(if ($WebhookUrl) { 'set' } else { 'MISSING' }) + ", inspectors " + @($config.Inspectors).Count + ", wifi networks " + @($config.WifiNetworks).Count)

# Two slow Windows queries (Windows activation, disk power-on hours) run in
# the background while the inspector picks a name and the network is set up.
$slowProbes = Start-Job -ScriptBlock {
    $r = @{ activation = $null; powerOnHours = $null }
    try {
        $product = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        if ($product) {
            $statusMap = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine Grace'; 5 = 'Notification'; 6 = 'Extended Grace' }
            $r.activation = $statusMap[[int]$product.LicenseStatus]
        }
    } catch {}
    try {
        $counters = Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($counters) {
            $r.powerOnHours = ($counters | Where-Object { $null -ne $_.PowerOnHours } | Measure-Object -Property PowerOnHours -Minimum).Minimum
        }
    } catch {}
    $r
}

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

$script:UsageCtx.inspector = $Inspector
Write-DetailLog "Inspector: $Inspector"

# --- Network drivers + Wi-Fi (before the spec checks, so upload works) ---
$netTimer = [Diagnostics.Stopwatch]::StartNew()
if ($SkipNetwork) {
    $network = [ordered]@{ wifiAdapter = ''; wifiDriverVersion = ''; networkDriverStatus = 'Skipped'; wifiConnected = ''; internetOk = (Test-InternetConnection) }
} else {
    $network = Invoke-NetworkSetup -Config $config -DriversDir $DriversDir
}
Write-Took 'network' $netTimer

Write-Host "`n[2/3] Laptop checks (Lot 2 contract)" -ForegroundColor Cyan
$hwTimer = [Diagnostics.Stopwatch]::StartNew()

function Get-PrimaryDiskSizeGB {
    # Decimal GB (1000^3), the unit the disk is sold in.
    try {
        $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
        return [math]::Round($disk.Size / 1000000000, 0)
    } catch {
        try {
            $drive = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1
            return [math]::Round($drive.Size / 1000000000, 0)
        } catch { return $null }
    }
}

function Get-PrimaryDiskMediaType {
    foreach ($get in { Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop },
                     { Get-PhysicalDisk -ErrorAction Stop }) {
        try {
            $d = & $get | Select-Object -First 1
            if ($d -and $d.MediaType -and "$($d.MediaType)" -ne 'Unspecified') { return [string]$d.MediaType }
        } catch {}
    }
    return $null
}

function Get-PanelInfo {
    # Native resolution and size of the built-in screen, from the panel's own
    # EDID data (the Windows desktop resolution can be set lower).
    $r = @{ Width = $null; Height = $null; Inches = $null }
    try {
        $internalTech = [uint32]0x80000000, 6, 11, 13   # internal, LVDS, embedded DisplayPort, embedded UDI
        $conn = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop)
        $names = @($conn | Where-Object { $internalTech -contains [uint32]$_.VideoOutputTechnology } | ForEach-Object InstanceName)
        if (-not $names) { $names = @($conn | ForEach-Object InstanceName) }
        $modes = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop |
            Where-Object { $names -contains $_.InstanceName } | ForEach-Object { $_.MonitorSourceModes })
        $best = $modes | Sort-Object { [int]$_.HorizontalActivePixels * [int]$_.VerticalActivePixels } -Descending | Select-Object -First 1
        if ($best) { $r.Width = [int]$best.HorizontalActivePixels; $r.Height = [int]$best.VerticalActivePixels }
        $p = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop |
            Where-Object { $names -contains $_.InstanceName } | Select-Object -First 1
        if ($p -and $p.MaxHorizontalImageSize -gt 0) {
            $r.Inches = [math]::Round([math]::Sqrt([math]::Pow($p.MaxHorizontalImageSize, 2) + [math]::Pow($p.MaxVerticalImageSize, 2)) / 2.54, 1)
        }
    } catch { Write-DetailLog "Panel info failed: $($_.Exception.Message)" }
    if (-not $r.Width) {
        try {
            $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object CurrentHorizontalResolution |
                Sort-Object CurrentHorizontalResolution -Descending | Select-Object -First 1
            if ($vc) { $r.Width = [int]$vc.CurrentHorizontalResolution; $r.Height = [int]$vc.CurrentVerticalResolution }
        } catch {}
    }
    $r
}

function Get-BatteryDesignWh {
    try {
        $b = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Where-Object DesignedCapacity)
        if ($b) { return [math]::Round(($b | Measure-Object DesignedCapacity -Sum).Sum / 1000, 1) }
    } catch { Write-DetailLog "Battery info failed: $($_.Exception.Message)" }
    return $null
}

function Get-TpmVersion {
    try {
        $t = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1
        if ($t -and $t.SpecVersion) { return ("$($t.SpecVersion)" -split ',')[0].Trim() }
    } catch { Write-DetailLog "TPM info failed: $($_.Exception.Message)" }
    return $null
}

# --- Gather hardware/OS facts ---
$bios = Get-CimInstance Win32_BIOS
$cs   = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$pnp  = @(try { Get-CimInstance Win32_PnPEntity -ErrorAction Stop } catch { })
$panel = Get-PanelInfo

$serialNumber = "$($bios.SerialNumber)".Trim()
$hostname     = $env:COMPUTERNAME
$wifiName     = $network.wifiAdapter
if (-not $wifiName -and $SkipNetwork) { $wifiName = (Get-WifiAdapter).InterfaceDescription }

$facts = @{
    Manufacturer    = "$($cs.Manufacturer)".Trim()
    Model           = "$($cs.Model)".Trim()
    CpuName         = "$($cpu.Name)".Trim()
    RamGB           = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    DiskGB          = Get-PrimaryDiskSizeGB
    DiskMediaType   = Get-PrimaryDiskMediaType
    GpuNames        = @(@(try { Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object Name } catch { }) +
                        @($pnp | Where-Object { $_.PNPClass -eq 'Display' } | ForEach-Object Name) | Where-Object { $_ } | Select-Object -Unique)
    PanelWidth      = $panel.Width
    PanelHeight     = $panel.Height
    PanelInches     = $panel.Inches
    HasTouch        = [bool]($pnp | Where-Object { $_.Name -match 'touch ?screen' })
    WifiAdapter     = $wifiName
    HasBluetooth    = [bool]($pnp | Where-Object { $_.PNPClass -eq 'Bluetooth' })
    HasCamera       = [bool]($pnp | Where-Object { $_.PNPClass -in 'Camera', 'Image' -or $_.Name -match 'camera|webcam' })
    FingerprintName = ($pnp | Where-Object { $_.PNPClass -eq 'Biometric' -or $_.Name -match 'fingerprint|FP Sensor' } | Select-Object -First 1).Name
    TpmVersion      = Get-TpmVersion
    BatteryWh       = Get-BatteryDesignWh
    OsCaption       = $os.Caption
    Activation      = $null
}

# Best-effort "new / unused" check: disk power-on hours (when the storage
# driver exposes reliability counters), else the OS install date. It cannot
# prove a laptop is factory-new, so an unreadable signal asks for a look.
$installDate = $os.InstallDate
$daysSinceInstall = if ($installDate) { (New-TimeSpan -Start $installDate -End (Get-Date)).Days } else { $null }

$probe = $null
if ($slowProbes) {
    if (Wait-Job $slowProbes -Timeout 45) { $probe = Receive-Job $slowProbes -ErrorAction SilentlyContinue | Select-Object -First 1 }
    Remove-Job $slowProbes -Force -ErrorAction SilentlyContinue
}
$powerOnHours = if ($probe) { $probe.powerOnHours } else { $null }
$facts.Activation = if ($probe) { $probe.activation } else { $null }

if ($null -ne $powerOnHours) {
    $condition = if ($powerOnHours -le 24) { "Likely new (disk power-on hours: $powerOnHours)" }
                 else { "Likely used (disk power-on hours: $powerOnHours)" }
} elseif ($null -ne $daysSinceInstall) {
    $condition = "Unverified - manual check needed (Windows installed $daysSinceInstall day(s) ago)"
} else {
    $condition = "Unverified - manual check needed"
}
Write-DetailLog ("Facts: " + ($facts | ConvertTo-Json -Compress))

$eval = Get-Lot2Evaluation -Facts $facts

Write-Host "`nInspecting $hostname (serial: $serialNumber) as $Inspector..." -ForegroundColor Cyan
if ($eval.Model) {
    $alt = if ($eval.Model.Alternative) { ' - approved alternative' } else { '' }
    Write-Host ("  Category {0}: {1}{2}  [{3}]" -f $eval.Category, $eval.Model.Name, $alt, $eval.Source) -ForegroundColor Cyan
}
$checkLabels = [ordered]@{
    model = 'Model'; cpu = 'CPU'; ram = 'RAM'; storage = 'Storage'; gpu = 'Graphics'; display = 'Screen'
    touch = 'Touch'; fingerprint = 'Fingerprint'; battery = 'Battery'; wifi6e = 'Wi-Fi 6E'
    bluetooth = 'Bluetooth'; camera = 'Camera'; tpm = 'TPM'; os = 'Windows'; activation = 'Activation'
}
foreach ($c in $eval.Checks) {
    $color = @{ Meets = 'Green'; Above = 'Green'; Below = 'Red'; Unknown = $(if ($c.Core) { 'Red' } else { 'DarkYellow' }) }[$c.Status]
    Write-Host ("  {0,-12}: {1}" -f $checkLabels[$c.Key], $c.Text) -ForegroundColor $color
}
if (-not $eval.Model) {
    Write-Host ("  {0,-12}: {1}" -f 'Seen', "$($facts.CpuName); $($facts.RamGB)GB RAM; $($facts.DiskGB)GB $($facts.DiskMediaType)") -ForegroundColor Gray
}
$conditionColor = if ($condition -like 'Likely new*') { 'Green' } elseif ($condition -like 'Likely used*') { 'Gray' } else { 'DarkYellow' }
Write-Host ("  {0,-12}: {1}" -f 'Condition', $condition) -ForegroundColor $conditionColor

$overallPass   = $eval.Pass
$overallResult = if ($overallPass) { 'PASS' } else { 'FAIL' }

$notes = @($eval.Failed | ForEach-Object { "$($checkLabels[$_.Key]): $($_.Text)" })
if ($eval.ByHand) { $notes += 'Check by hand: ' + (($eval.ByHand | ForEach-Object { $checkLabels[$_.Key] }) -join ', ') }
if ($condition -like 'Unverified*') { $notes += 'Condition needs manual confirmation' }
$notesText = ($notes -join '; ')

Write-Took 'checks' $hwTimer
$overallColor = if ($overallPass) { 'Green' } else { 'Red' }

function Get-CheckText([string]$Key) { ($eval.Checks | Where-Object Key -eq $Key | Select-Object -First 1).Text }

$record = [ordered]@{
    timestamp         = [DateTime]::UtcNow.AddHours($(if ($null -ne $config.TimeZoneOffsetHours) { [double]$config.TimeZoneOffsetHours } else { 2 })).ToString('yyyy-MM-dd HH:mm:ss')
    inspector         = $Inspector
    serialNumber      = $serialNumber
    hostname          = $hostname
    manufacturer      = $facts.Manufacturer
    model             = $facts.Model
    category          = $eval.Category
    categorySource    = $eval.Source
    contractModel     = if ($eval.Model) { $eval.Model.Name + $(if ($eval.Model.Alternative) { ' (alternative)' } else { '' }) } else { '' }
    overallResult     = $overallResult
    notes             = $notesText
    modelCheck        = Get-CheckText model
    cpuModel          = $facts.CpuName
    cpuCheck          = Get-CheckText cpu
    ramGB             = $facts.RamGB
    ramCheck          = Get-CheckText ram
    diskGB            = $facts.DiskGB
    diskMediaType     = $facts.DiskMediaType
    storageCheck      = Get-CheckText storage
    gpuNames          = ($facts.GpuNames -join '; ')
    gpuCheck          = Get-CheckText gpu
    screen            = $(if ($facts.PanelWidth) { "$($facts.PanelWidth)x$($facts.PanelHeight)" + $(if ($facts.PanelInches) { " $($facts.PanelInches) inch" } else { '' }) } else { '' })
    displayCheck      = Get-CheckText display
    touchScreen       = $(if ($facts.HasTouch) { 'Yes' } else { 'No' })
    touchCheck        = Get-CheckText touch
    fingerprintReader = $facts.FingerprintName
    fingerprintCheck  = Get-CheckText fingerprint
    batteryWh         = $facts.BatteryWh
    batteryCheck      = Get-CheckText battery
    wifi6eCheck       = Get-CheckText wifi6e
    bluetooth         = $(if ($facts.HasBluetooth) { 'Yes' } else { 'No' })
    bluetoothCheck    = Get-CheckText bluetooth
    camera            = $(if ($facts.HasCamera) { 'Yes' } else { 'No' })
    cameraCheck       = Get-CheckText camera
    tpmVersion        = $facts.TpmVersion
    tpmCheck          = Get-CheckText tpm
    biosVersion       = "$($bios.SMBIOSBIOSVersion)"
    os                = $facts.OsCaption
    osBuild           = $os.BuildNumber
    osCheck           = Get-CheckText os
    activationCheck   = Get-CheckText activation
    condition         = $condition
    diskPowerOnHours  = $powerOnHours
    wifiAdapter       = $network.wifiAdapter
    wifiDriverVersion = $network.wifiDriverVersion
    networkDriverStatus = $network.networkDriverStatus
    wifiConnected     = $network.wifiConnected
    internetOk        = [bool]$network.internetOk
    toolVersion       = $ToolVersion
}

$script:UsageCtx.serialNumber = $serialNumber
$script:UsageCtx.overallResult = $overallResult
$script:UsageCtx.wifiAdapter = $network.wifiAdapter
$script:UsageCtx.wifiConnected = $network.wifiConnected
$script:UsageCtx.internetOk = [string][bool]$network.internetOk
Write-DetailLog "Result: $overallResult serial=$serialNumber notes=$notesText"

# --- Upload to the Google Sheet: once, by this PC, no queue --------------
# Every run is sent a single time, as a new row (a PC inspected again keeps
# its earlier rows; the Sheet counts them in "Inspection #"). If the upload
# fails (no internet...), it is NOT queued and NOT retried by other PCs
# later: the row stays in inspection-log.csv (uploadStatus = "failed") and the
# PC is simply inspected again when it is online. The Sheet only refuses a
# row it already has (same serial number AND same timestamp), which can
# happen when the answer to an upload got lost and the upload is repeated.
Write-Host "`n[3/3] Saving result" -ForegroundColor Cyan

function Send-InspectionRow {
    # Returns 'ok' or 'duplicate'; throws on network/server errors.
    param([string]$Json)
    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -TimeoutSec 25 `
        -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -ContentType 'application/json; charset=utf-8'
    if ($response.status -eq 'duplicate') { return 'duplicate' }
    return 'ok'
}

$uploadStatus = 'skipped'
$uploadNote = ''

if ($NoUpload) {
    $uploadNote = 'Upload skipped (-NoUpload).'
} elseif (-not $WebhookUrl) {
    $uploadNote = 'No WebhookUrl in config.json - result saved on this PC only.'
} else {
    $json = $record | ConvertTo-Json -Depth 3 -Compress
    $lastError = ''
    foreach ($attempt in 1..2) {
        try {
            $status = Send-InspectionRow $json
            Write-DetailLog "Upload attempt $attempt answered: $status"
            $uploadStatus = if ($status -eq 'duplicate') { 'already-in-sheet' } else { 'uploaded' }
            break
        } catch {
            $lastError = $_.Exception.Message
            Write-DetailLog "Upload attempt $attempt failed: $($_.Exception.ToString())"
            if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
        }
    }
    switch ($uploadStatus) {
        'uploaded'         { $uploadNote = 'Uploaded to the Google Sheet.' }
        'already-in-sheet' { $uploadNote = 'This exact result is already in the Sheet - nothing added.' }
        default {
            $uploadStatus = 'failed'
            $uploadNote = 'Could not upload (no internet?). Result is saved on this PC - run the inspection again when online.'
            Write-Host "  (detail: $lastError)" -ForegroundColor DarkGray
        }
    }
}

# --- Local log (written after the upload, so it shows what really happened) ---
$record['uploadStatus'] = $uploadStatus
$script:UsageCtx.uploadStatus = $uploadStatus
Write-DetailLog "Upload status: $uploadStatus $uploadNote"
try {
    [PSCustomObject]$record | Export-Csv -Path $LogPath -Append -Force -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Host "  Could not write $LogPath ($($_.Exception.Message))" -ForegroundColor Yellow
}

# --- Summary ------------------------------------------------------------
$uploadColor = switch ($uploadStatus) { 'uploaded' { 'Green' } 'already-in-sheet' { 'Green' } 'failed' { 'Yellow' } default { 'DarkGray' } }
Write-Host ""
Write-Host "==============================================" -ForegroundColor $overallColor
Write-Host ("  RESULT: {0}" -f $overallResult) -ForegroundColor $overallColor
if ($notesText) { Write-Host "  $notesText" -ForegroundColor Yellow }
Write-Host ("  Wi-Fi: {0}   Internet: {1}" -f $(if ($network.wifiConnected) { $network.wifiConnected } else { 'not connected' }), $(if ($network.internetOk) { 'OK' } else { 'none' })) -ForegroundColor Gray
Write-Host "  $uploadNote" -ForegroundColor $uploadColor
Write-Host ("  Done in {0:N0} seconds." -f $runTimer.Elapsed.TotalSeconds) -ForegroundColor DarkGray
Write-Host "==============================================" -ForegroundColor $overallColor

# --- Usage log line + copy result and ALL logs back to the flash disk ---
# (Plain .NET path calls: Join-Path/Test-Path throw once the flash disk's
# drive letter is gone. If the flash disk is gone, everything stays on this
# PC in C:\ProgramData\PC-Inspection\logs - COLLECT-LOGS.bat copies it later.)
$exitCode = if ($overallPass) { 0 } else { 2 }
$usageRow = Write-UsageRow -Outcome $overallResult -ExitCode $exitCode
try { Stop-Transcript | Out-Null } catch {}
if ($UsbRoot) {
    $usbOk = $false
    try { $usbOk = [IO.File]::Exists([IO.Path]::Combine($UsbRoot, 'config.json')) } catch {}
    if ($usbOk) {
        try {
            [PSCustomObject]$record | Export-Csv -Path ([IO.Path]::Combine($UsbRoot, 'inspection-log.csv')) -Append -Force -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            if (Test-Path $InspectorCachePath) { Copy-Item $InspectorCachePath ([IO.Path]::Combine($UsbRoot, 'inspector-name.txt')) -Force }
            $usbLogs = [IO.Path]::Combine($UsbRoot, 'logs')
            [void][IO.Directory]::CreateDirectory($usbLogs)
            # every run of every PC in one list ...
            if ($usageRow) { [PSCustomObject]$usageRow | Export-Csv -Path ([IO.Path]::Combine($usbLogs, 'usage-log.csv')) -Append -Force -NoTypeInformation -Encoding UTF8 }
            # ... and the full logs of this PC, in a folder per computer
            & robocopy.exe $logsDir ([IO.Path]::Combine($usbLogs, $env:COMPUTERNAME)) /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            Write-Host "  Result and logs also copied to the flash disk." -ForegroundColor DarkGray
        } catch {
            Write-Host "  Could not write to the flash disk - result and logs are on this PC: $logsDir" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Flash disk removed - result and logs are on this PC: $logsDir" -ForegroundColor DarkGray
    }
}

exit $exitCode
