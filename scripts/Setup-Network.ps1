<#
.SYNOPSIS
  Network helpers dot-sourced by Inspect-PC.ps1:
    - make sure the Wi-Fi adapter has a working driver (installing from the
      flash disk's drivers\ folder, or from configured download links)
    - add the configured Wi-Fi profiles (SSID + key) and connect
    - check that the internet is reachable

  Everything here needs admin rights (pnputil, netsh wlan ... user=all).
  PC-Inspection.exe elevates itself before calling this.
#>

function Test-InternetConnection {
    param([int]$TimeoutSec = 6)
    # Microsoft's own connectivity probe - the same URL Windows uses for the
    # "No internet" icon. Tiny, plain HTTP, no redirects on a real network.
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' `
            -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($r.Content -like 'Microsoft Connect Test*')
    } catch {
        return $false
    }
}

function Get-WifiAdapter {
    # Physical adapters whose media type or name says Wi-Fi. Only adapters
    # with a working driver show up here at all.
    try {
        return Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
            $_.PhysicalMediaType -match '802\.11' -or
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11'
        } | Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-ProblemNetworkDevices {
    # Devices Windows found but could not start. Error 28 = "drivers for
    # this device are not installed" - that is how a Wi-Fi/Ethernet card
    # with no driver looks (it shows under "Other devices" in Device
    # Manager, so it has no 'Net' class yet).
    try {
        return Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.ConfigManagerErrorCode -ne 0 -and (
                $_.PNPClass -eq 'Net' -or
                ($_.ConfigManagerErrorCode -eq 28 -and $_.PNPDeviceID -match '^(PCI|USB|SDIO)\\') -or
                $_.Name -match 'Network|Wi-?Fi|Wireless|WLAN|Ethernet|802\.11'
            )
        }
    } catch {
        return @()
    }
}

function Install-InfFolder {
    param([string]$Folder)

    $infs = Get-ChildItem -Path $Folder -Filter *.inf -Recurse -ErrorAction SilentlyContinue
    if (-not $infs) { return $false }
    Write-Host "    Installing $($infs.Count) driver(s) from $Folder (can take a few minutes) ..." -ForegroundColor DarkGray
    $out = & pnputil.exe /add-driver (Join-Path $Folder '*.inf') /subdirs /install 2>&1
    # pnputil's last lines are a summary: "Total driver packages: N",
    # "Added driver packages: N"
    $out | Where-Object { "$_" -match 'Total driver packages|Added driver packages|Failed' } |
        ForEach-Object { Write-Host "    $("$_".Trim())" -ForegroundColor DarkGray }
    return $true
}

function Get-DriverPackageFile {
    param($Package, [string]$CacheDir, [bool]$Online)

    $fileName = if ($Package.FileName) { $Package.FileName } else { [IO.Path]::GetFileName(([Uri]$Package.Url).AbsolutePath) }
    if (-not $fileName) { $fileName = ($Package.Name -replace '[^\w\.-]', '_') + '.bin' }
    $target = Join-Path $CacheDir $fileName

    if (Test-Path $target) { return $target }
    if (-not $Online) { return $null }

    Write-Host "    Downloading $($Package.Name) ..." -ForegroundColor DarkGray
    try {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $tmp = "$target.part"
        $ProgressPreference = 'SilentlyContinue'   # progress bar makes IWR ~10x slower
        Invoke-WebRequest -Uri $Package.Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        Move-Item -Force $tmp $target
        return $target
    } catch {
        Write-Host "    Download failed for $($Package.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item "$target.part" -ErrorAction SilentlyContinue
        return $null
    }
}

function Install-DriverPackage {
    param($Package, [string]$File)

    $type = if ($Package.Type) { $Package.Type.ToLower() } else { [IO.Path]::GetExtension($File).TrimStart('.').ToLower() }
    Write-Host "    Installing $($Package.Name) ($type) ..." -ForegroundColor DarkGray
    try {
        switch ($type) {
            'zip' {
                $dest = Join-Path $env:TEMP ("drv_" + [guid]::NewGuid().ToString('N'))
                Expand-Archive -Path $File -DestinationPath $dest -Force
                if (-not (Install-InfFolder $dest)) {
                    # Some vendor zips only contain an installer .exe
                    $exe = Get-ChildItem $dest -Filter *.exe -Recurse | Select-Object -First 1
                    if ($exe) {
                        $silentArgs = if ($Package.SilentArgs) { $Package.SilentArgs } else { '/quiet /norestart' }
                        Start-Process -FilePath $exe.FullName -ArgumentList $silentArgs -Wait
                    }
                }
            }
            'exe' {
                $silentArgs = if ($Package.SilentArgs) { $Package.SilentArgs } else { '/quiet /norestart' }
                Start-Process -FilePath $File -ArgumentList $silentArgs -Wait
            }
            'msi' {
                Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$File`" /qn /norestart" -Wait
            }
            'inf' {
                & pnputil.exe /add-driver $File /install | Out-Null
            }
            'cab' {
                $dest = Join-Path $env:TEMP ("drv_" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                & expand.exe $File -F:* $dest | Out-Null
                Install-InfFolder $dest | Out-Null
            }
            default { Write-Host "    Unknown driver type '$type' - skipped" -ForegroundColor Yellow }
        }
        return $true
    } catch {
        Write-Host "    Install failed for $($Package.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Test-PackageMatches {
    param($Package, $Devices)

    # No MatchHardwareIds = try it on every PC that is missing a driver.
    if (-not $Package.MatchHardwareIds) { return $true }
    foreach ($id in $Package.MatchHardwareIds) {
        foreach ($d in $Devices) {
            if ($d.PNPDeviceID -like "*$id*") { return $true }
        }
    }
    return $false
}

function Install-NetworkDrivers {
    param($Config, [string]$DriversDir, [switch]$SkipFolder)

    $problems = @(Get-ProblemNetworkDevices)
    $cacheDir = Join-Path $DriversDir 'downloads'

    # 1) Driver folders copied onto the flash disk (works with no internet)
    if (-not $SkipFolder -and (Test-Path $DriversDir)) {
        Install-InfFolder $DriversDir | Out-Null
    }

    # 2) Configured download links (cached on the flash disk after the first download)
    $online = Test-InternetConnection
    foreach ($pkg in @($Config.DriverPackages)) {
        if (-not $pkg -or -not $pkg.Url) { continue }
        if (-not (Test-PackageMatches $pkg $problems)) { continue }
        $file = Get-DriverPackageFile -Package $pkg -CacheDir $cacheDir -Online $online
        if ($file) { Install-DriverPackage -Package $pkg -File $file | Out-Null }
        else { Write-Host "    $($pkg.Name): not on flash disk and no internet to download it" -ForegroundColor Yellow }
    }

    # Ask Windows to re-detect hardware so the new drivers bind now
    & pnputil.exe /scan-devices 2>$null | Out-Null
    Start-Sleep -Seconds 5
}

function Save-DriverPackagesToFlash {
    # When this PC is online, download any configured driver package that is
    # not on the flash disk yet, so the next PC without Wi-Fi drivers can be
    # fixed offline.
    param($Config, [string]$DriversDir)

    $cacheDir = Join-Path $DriversDir 'downloads'
    foreach ($pkg in @($Config.DriverPackages)) {
        if (-not $pkg -or -not $pkg.Url) { continue }
        Get-DriverPackageFile -Package $pkg -CacheDir $cacheDir -Online $true | Out-Null
    }
}

function ConvertTo-XmlText {
    param([string]$Text)
    return [Security.SecurityElement]::Escape($Text)
}

function Add-WifiProfile {
    param($Network)

    $ssid = [string]$Network.Ssid
    $security = if ($Network.Security) { $Network.Security.ToUpper() } else { 'WPA2PSK' }
    $hex = -join ([Text.Encoding]::UTF8.GetBytes($ssid) | ForEach-Object { $_.ToString('X2') })

    switch ($security) {
        'OPEN'     { $auth = 'open';     $enc = 'none' }
        'WPA3SAE'  { $auth = 'WPA3SAE';  $enc = 'AES' }
        'WPAPSK'   { $auth = 'WPAPSK';   $enc = 'AES' }
        default    { $auth = 'WPA2PSK';  $enc = 'AES' }
    }
    $keyXml = ''
    if ($auth -ne 'open') {
        $keyXml = @"
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$(ConvertTo-XmlText $Network.Password)</keyMaterial>
      </sharedKey>
"@
    }
    $hidden = if ($Network.Hidden) { 'true' } else { 'false' }

    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$(ConvertTo-XmlText $ssid)</name>
  <SSIDConfig>
    <SSID>
      <hex>$hex</hex>
      <name>$(ConvertTo-XmlText $ssid)</name>
    </SSID>
    <nonBroadcast>$hidden</nonBroadcast>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>$auth</authentication>
        <encryption>$enc</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
$keyXml
    </security>
  </MSM>
</WLANProfile>
"@

    # Profile file holds the password in clear text - write it to TEMP and
    # delete it right after netsh has imported it.
    $file = Join-Path $env:TEMP ("wifi_" + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $xml | Out-File -FilePath $file -Encoding UTF8
        $out = & netsh.exe wlan add profile filename="$file" user=all 2>&1
        return ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

function Connect-Wifi {
    param($Networks, [int]$WaitSec = 20)

    foreach ($net in @($Networks)) {
        if (-not $net -or -not $net.Ssid -or $net.Ssid -like 'YOUR-*') { continue }
        Write-Host "    Adding Wi-Fi '$($net.Ssid)' ..." -ForegroundColor DarkGray
        if (-not (Add-WifiProfile $net)) {
            Write-Host "    Could not add profile for '$($net.Ssid)'" -ForegroundColor Yellow
            continue
        }
        & netsh.exe wlan connect name="$($net.Ssid)" 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-InternetConnection -TimeoutSec 4) { return [string]$net.Ssid }
        }
        Write-Host "    No internet through '$($net.Ssid)', trying next ..." -ForegroundColor Yellow
    }
    return $null
}

function Invoke-NetworkSetup {
    <#
      Returns an object with what happened, so the inspection record can
      store it: adapter name, driver version, driver status, SSID, internet.
    #>
    param($Config, [string]$DriversDir)

    $result = [ordered]@{
        wifiAdapter        = ''
        wifiDriverVersion  = ''
        networkDriverStatus = ''
        wifiConnected      = ''
        internetOk         = $false
    }

    Write-Host "`n[1/3] Network drivers & Wi-Fi" -ForegroundColor Cyan

    # Wireless AutoConfig must be running for netsh wlan to work at all
    try { Set-Service WlanSvc -StartupType Automatic -ErrorAction Stop; Start-Service WlanSvc -ErrorAction Stop } catch {}

    # Install every driver in the flash disk's drivers\ folder on every PC
    # (config.json "InstallAllDrivers": false = only when Wi-Fi is broken).
    # Drivers that don't match this PC's hardware are just stored, not used.
    $folderDone = $false
    if ($Config.InstallAllDrivers -ne $false -and (Test-Path $DriversDir)) {
        $folderDone = Install-InfFolder $DriversDir
        if ($folderDone) {
            & pnputil.exe /scan-devices 2>$null | Out-Null
            Start-Sleep -Seconds 5
        }
    }

    $adapter  = Get-WifiAdapter
    $problems = @(Get-ProblemNetworkDevices)

    if (-not $adapter -or $problems.Count -gt 0) {
        if (-not $adapter) { Write-Host "    No working Wi-Fi adapter - installing drivers ..." -ForegroundColor Yellow }
        foreach ($p in $problems) { Write-Host "    Missing/broken driver: $($p.Name) [$($p.PNPDeviceID)]" -ForegroundColor Yellow }
        Install-NetworkDrivers -Config $Config -DriversDir $DriversDir -SkipFolder:$folderDone
        try { Start-Service WlanSvc -ErrorAction Stop } catch {}
        $adapter  = Get-WifiAdapter
        $problems = @(Get-ProblemNetworkDevices)
    }

    if ($adapter) {
        $result.wifiAdapter       = $adapter.InterfaceDescription
        $result.wifiDriverVersion = $adapter.DriverVersion
        Write-Host ("  {0,-12}: {1} (driver {2})" -f 'Wi-Fi card', $adapter.InterfaceDescription, $adapter.DriverVersion) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-12}: {1}" -f 'Wi-Fi card', 'NOT FOUND / no driver') -ForegroundColor Red
    }

    if ($problems.Count -gt 0) {
        $result.networkDriverStatus = 'Missing driver: ' + (($problems | ForEach-Object { $_.Name }) -join ', ')
        Write-Host ("  {0,-12}: {1}" -f 'Net drivers', $result.networkDriverStatus) -ForegroundColor Red
    } elseif ($adapter) {
        $result.networkDriverStatus = 'OK'
        Write-Host ("  {0,-12}: {1}" -f 'Net drivers', 'OK') -ForegroundColor Green
    } else {
        $result.networkDriverStatus = 'No Wi-Fi adapter found'
    }

    if ($adapter -and @($Config.WifiNetworks).Count -gt 0) {
        $ssid = Connect-Wifi -Networks $Config.WifiNetworks
        if ($ssid) { $result.wifiConnected = $ssid }
    }
    $result.internetOk = Test-InternetConnection
    if (-not $result.wifiConnected -and $adapter) {
        # Maybe it was already on Wi-Fi (or the profile auto-connected late)
        $line = (& netsh.exe wlan show interfaces 2>$null) -match '^\s*SSID\s*:' | Select-Object -First 1
        if ($line) { $result.wifiConnected = ($line -split ':', 2)[1].Trim() }
    }

    $wifiText = if ($result.wifiConnected) { "Connected to '$($result.wifiConnected)'" } elseif (-not $adapter) { 'No Wi-Fi card' } elseif (@($Config.WifiNetworks).Count -eq 0) { 'No Wi-Fi networks in config.json' } else { 'Not connected' }
    $wifiColor = if ($result.wifiConnected) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f 'Wi-Fi', $wifiText) -ForegroundColor $wifiColor
    $netColor = if ($result.internetOk) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f 'Internet', $(if ($result.internetOk) { 'OK' } else { 'NO INTERNET' })) -ForegroundColor $netColor

    if ($result.internetOk -and $Config.CacheDriversWhenOnline -ne $false) {
        Save-DriverPackagesToFlash -Config $Config -DriversDir $DriversDir
    }

    return $result
}
