<#
.SYNOPSIS
  Runs while the flash disk is still plugged in. Copies to this PC only the
  driver this PC actually needs (matched by the Wi-Fi card's hardware ID),
  and checks the copy against drivers\checksums.sha256, so the flash disk
  can be removed in a few seconds instead of after a 240 MB copy.

  - Wi-Fi already working            -> copies no drivers
  - Wi-Fi card without a driver      -> copies the matching driver folder(s)
  - no way to tell (e.g. no adapter) -> copies all drivers (safe fallback)
  - -AllDrivers                      -> copies all drivers
#>
param(
    [Parameter(Mandatory)][string]$UsbRoot,
    [Parameter(Mandatory)][string]$LocalDir,
    [string[]]$HardwareIds,      # tests only; normally read from this PC
    [switch]$AllDrivers
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Setup-Network.ps1')

# [IO.Path] calls: they don't care whether the drive letter exists.
# GetFullPath also turns "E:\PC-Inspection\." into "E:\PC-Inspection".
$usbDrivers   = [IO.Path]::GetFullPath([IO.Path]::Combine($UsbRoot, 'drivers'))
$localDrivers = [IO.Path]::GetFullPath([IO.Path]::Combine($LocalDir, 'drivers'))

function Get-DriverKeys {
    # "PCI\VEN_10EC&DEV_B852&SUBSYS_..." -> "VEN_10EC&DEV_B852" (also USB VID/PID)
    param([string[]]$Ids)
    $keys = foreach ($id in $Ids) {
        foreach ($m in [regex]::Matches("$id", '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})|(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})')) { $m.Value.ToUpper() }
    }
    return @($keys | Select-Object -Unique)
}

function Find-DriverFolders {
    # Folders (package = folder holding the .inf) whose .inf mentions a key.
    param([string]$Root, [string[]]$Keys)
    $found = @{}
    foreach ($inf in Get-ChildItem -Path $Root -Filter *.inf -Recurse -ErrorAction SilentlyContinue) {
        if ($Keys.Count -eq 0) { $found[$inf.DirectoryName] = $true; continue }
        $text = [IO.File]::ReadAllText($inf.FullName)   # detects UTF-16 by BOM
        foreach ($k in $Keys) {
            if ($text.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found[$inf.DirectoryName] = $true; break }
        }
    }
    return @($found.Keys | Sort-Object)
}

function Copy-DriverFolder {
    param([string]$Folder)
    $rel = $Folder.Substring($usbDrivers.TrimEnd('\').Length).TrimStart('\')
    $dst = Join-Path $localDrivers $rel
    & robocopy.exe $Folder $dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying '$rel' failed (robocopy code $LASTEXITCODE)" }
    return $rel
}

function Test-CopiedDriver {
    # Compares the copied files with drivers\checksums.sha256. A damaged file
    # is copied again once; returns the files that are still wrong.
    param([string]$Rel, $Hashes)
    $bad = @()
    $localFolder = Join-Path $localDrivers $Rel
    foreach ($f in Get-ChildItem -Path $localFolder -File -Recurse) {
        $key = ($f.FullName.Substring($localDrivers.TrimEnd('\').Length).TrimStart('\') -replace '\\', '/')
        if (-not $Hashes.ContainsKey($key)) { continue }
        if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -eq $Hashes[$key]) { continue }
        Copy-Item -LiteralPath (Join-Path $usbDrivers ($key -replace '/', '\')) -Destination $f.FullName -Force -ErrorAction SilentlyContinue
        if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ne $Hashes[$key]) { $bad += $key }
    }
    return $bad
}

if (-not [IO.Directory]::Exists($usbDrivers)) { exit 0 }

# What does this PC need?
if ($AllDrivers) {
    $keys = @(); $reason = 'all drivers requested'
} else {
    if (-not $HardwareIds) {
        $adapter  = Get-WifiAdapter
        $problems = @(Get-ProblemNetworkDevices)
        if ($adapter) { Write-Host "  Wi-Fi driver already installed on this PC - no drivers to copy." -ForegroundColor DarkGray; exit 0 }
        $HardwareIds = @($problems | ForEach-Object { $_.HardwareID })
    }
    $keys = Get-DriverKeys $HardwareIds
    $reason = if ($keys.Count) { "Wi-Fi card " + ($keys -join ', ') } else { 'Wi-Fi card not recognised, copying all drivers' }
}

$folders = @(Find-DriverFolders -Root $usbDrivers -Keys $keys)
if (-not $folders.Count) {
    Write-Host "  No driver on the flash disk matches this PC ($reason)." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Copying the Wi-Fi driver for this PC ($reason) ..." -ForegroundColor DarkGray
$hashes = @{}
$sumFile = Join-Path $usbDrivers 'checksums.sha256'
if ([IO.File]::Exists($sumFile)) {
    foreach ($line in [IO.File]::ReadAllLines($sumFile)) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $hashes[$Matches[2].Trim()] = $Matches[1].ToUpper() }
    }
}

$damaged = @()
foreach ($f in $folders) {
    $rel = Copy-DriverFolder $f
    Write-Host "    $rel" -ForegroundColor DarkGray
    if ($hashes.Count) { $damaged += Test-CopiedDriver -Rel $rel -Hashes $hashes }
}

if ($damaged.Count) {
    Write-Host "  $($damaged.Count) driver file(s) on the flash disk are DAMAGED:" -ForegroundColor Red
    $damaged | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host "  Fix: copy the PC-Inspection folder to the flash disk again, then use 'Eject' before unplugging." -ForegroundColor Yellow
    exit 3
}
if ($hashes.Count) { Write-Host "  Driver files checked: OK" -ForegroundColor DarkGray }
exit 0
