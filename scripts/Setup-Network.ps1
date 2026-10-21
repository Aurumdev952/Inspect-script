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
    param([int]$TimeoutSec = 4)
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
    # Network devices Windows found but could not start. Error 28 = "drivers
    # for this device are not installed" - a Wi-Fi card with no driver shows
    # under "Other devices" as "Network Controller" with no 'Net' class yet.
    # PCI class code 02xx (CompatibleID "PCI\CC_02...") = network controller.
    # Other driverless devices (chipset, SM Bus, ...) are NOT counted.
    try {
        return Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.ConfigManagerErrorCode -ne 0 -and (
                $_.PNPClass -eq 'Net' -or
                (@($_.CompatibleID) -match '^PCI\\CC_02').Count -gt 0 -or
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
    Write-Host "    Installing Wi-Fi driver ($($infs.Count) package(s)) ..." -ForegroundColor DarkGray
    $out = & pnputil.exe /add-driver (Join-Path $Folder '*.inf') /subdirs /install 2>&1
    $added = ($out | Select-String 'Added driver packages:\s*(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    $failed = @($out | Where-Object { "$_" -match 'Failed to add' })
    if ($failed.Count) {
        Write-Host "    $($failed.Count) driver package(s) could not be added:" -ForegroundColor Yellow
        $failed | Select-Object -First 3 | ForEach-Object { Write-Host "      $("$_".Trim())" -ForegroundColor DarkGray }
    }
    if ($added) { Write-Host "    Driver packages installed: $added" -ForegroundColor DarkGray }
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
    param($Config, [string]$DriversDir)

    $problems = @(Get-ProblemNetworkDevices)
    $cacheDir = Join-Path $DriversDir 'downloads'

    # 1) Driver files on this PC (prepared from the flash disk - works with no internet)
    if (Test-Path $DriversDir) {
        Install-InfFolder $DriversDir | Out-Null
    }

    # 2) Configured download links (only when they match the missing hardware)
    $links = @($Config.DriverPackages | Where-Object { $_ -and $_.Url })
    if ($links.Count) {
        $online = Test-InternetConnection
        foreach ($pkg in $links) {
            if (-not (Test-PackageMatches $pkg $problems)) { continue }
            $file = Get-DriverPackageFile -Package $pkg -CacheDir $cacheDir -Online $online
            if ($file) { Install-DriverPackage -Package $pkg -File $file | Out-Null }
            else { Write-Host "    $($pkg.Name): not on this PC and no internet to download it" -ForegroundColor Yellow }
        }
    }

    # Ask Windows to re-detect hardware so the new driver binds now
    & pnputil.exe /scan-devices 2>$null | Out-Null
}

function Wait-ForWifiAdapter {
    param([int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $a = Get-WifiAdapter
        if ($a) { return $a }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Start-WlanService {
    # Wireless AutoConfig must be running for netsh wlan to work at all.
    try {
        $svc = Get-Service WlanSvc -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Set-Service WlanSvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service WlanSvc -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
    } catch {}
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

function Get-ConnectedSsid {
    $line = (& netsh.exe wlan show interfaces 2>$null) -match '^\s*SSID\s*:' | Select-Object -First 1
    if ($line) { return ($line -split ':', 2)[1].Trim() }
    return $null
}

function Connect-Wifi {
    # Adds every configured network to this PC, then makes sure we are online.
    # Returns the SSID we are connected to, or $null.
    param($Networks, [int]$WaitSec = 20)

    $usable = @($Networks | Where-Object { $_ -and $_.Ssid -and $_.Ssid -notlike 'YOUR-*' })
    foreach ($net in $usable) {
        Write-Host "    Adding Wi-Fi '$($net.Ssid)' ..." -ForegroundColor DarkGray
        if (-not (Add-WifiProfile $net)) {
            Write-Host "    Could not add Wi-Fi '$($net.Ssid)' (check the name/password in config.json)" -ForegroundColor Yellow
        }
    }
    if (-not $usable.Count) { return $null }

    # Already online (e.g. Windows auto-joined a saved network)? Nothing to do.
    if (Test-InternetConnection -TimeoutSec 3) { return (Get-ConnectedSsid) }

    foreach ($net in $usable) {
        & netsh.exe wlan connect name="$($net.Ssid)" 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            if ((Get-ConnectedSsid) -eq [string]$net.Ssid -and (Test-InternetConnection -TimeoutSec 3)) { return [string]$net.Ssid }
        }
        Write-Host "    No internet through '$($net.Ssid)', trying the next network ..." -ForegroundColor DarkGray
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
    Start-WlanService

    $adapter  = Get-WifiAdapter
    $problems = @(Get-ProblemNetworkDevices)

    if ($adapter -and $problems.Count -eq 0) {
        Write-Host "    Wi-Fi driver already installed." -ForegroundColor DarkGray
    } else {
        Install-NetworkDrivers -Config $Config -DriversDir $DriversDir
        Start-WlanService
        $adapter  = Wait-ForWifiAdapter
        $problems = @(Get-ProblemNetworkDevices)
    }

    if ($adapter) {
        $result.wifiAdapter       = $adapter.InterfaceDescription
        $result.wifiDriverVersion = $adapter.DriverVersion
        Write-Host ("  {0,-12}: {1} (driver {2})" -f 'Wi-Fi card', $adapter.InterfaceDescription, $adapter.DriverVersion) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-12}: {1}" -f 'Wi-Fi card', 'NOT FOUND (no driver for it on the flash disk?)') -ForegroundColor Red
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

    $ssid = $null
    if ($adapter) { $ssid = Connect-Wifi -Networks $Config.WifiNetworks }
    if ($ssid) {
        $result.wifiConnected = $ssid
        $result.internetOk = $true
    } else {
        # Not on a configured Wi-Fi: maybe on a cable / other network.
        $result.internetOk = Test-InternetConnection
        if ($adapter) {
            $now = Get-ConnectedSsid
            if ($now) { $result.wifiConnected = $now }
        }
    }

    $wifiText = if ($result.wifiConnected) { "Connected to '$($result.wifiConnected)'" } elseif (-not $adapter) { 'No Wi-Fi card' } elseif (@($Config.WifiNetworks).Count -eq 0) { 'No Wi-Fi networks in config.json' } else { 'Not connected' }
    $wifiColor = if ($result.wifiConnected) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f 'Wi-Fi', $wifiText) -ForegroundColor $wifiColor
    $netColor = if ($result.internetOk) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f 'Internet', $(if ($result.internetOk) { 'OK' } else { 'NO INTERNET' })) -ForegroundColor $netColor

    return $result
}
