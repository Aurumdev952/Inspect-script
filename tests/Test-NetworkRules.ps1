param([string]$Scripts)
$ErrorActionPreference = 'Stop'
. (Join-Path $Scripts 'Setup-Network.ps1')
# --- simulate Windows ---
function Start-WlanService {}
function Install-NetworkDrivers { param($Config, $DriversDir) }
function Wait-ForWifiAdapter { param($TimeoutSec) $script:Adapter }
function Connect-Wifi { param($Networks) 'TestNet' }
function Test-InternetConnection { param($TimeoutSec) $true }
function Get-ConnectedSsid { 'TestNet' }
function Get-WifiAdapter { $script:Adapter }
function Get-ProblemNetworkDevices { $script:Problems }
function Get-AllProblemDevices { @($script:Other) }
$cfg = [pscustomobject]@{ WifiNetworks = @(@{ Ssid = 'x'; Password = 'y' }) }
$card = [pscustomobject]@{ InterfaceDescription = 'Realtek RTL8852BE'; DriverVersion = '6001.15.161.0' }
$chipset = @([pscustomobject]@{ Name = 'SM Bus Controller' }, [pscustomobject]@{ Name = 'PCI Device' })
$fail = 0
function Check($name, $ok) { if ($ok) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }

# 1) Wi-Fi works, chipset devices without drivers -> network OK
$script:Adapter = $card; $script:Problems = @(); $script:Other = $chipset
$r = Invoke-NetworkSetup -Config $cfg -DriversDir 'x' 6>$null
Check 'wifi works + chipset devices without driver -> OK'  ($r.networkDriverStatus -eq 'OK' -and $r.wifiAdapter -and $r.wifiConnected -eq 'TestNet' -and $r.internetOk)

# 2) Wi-Fi works even if another *network* device lacks a driver -> still OK, nothing installed
$script:Problems = @([pscustomobject]@{ Name = 'Ethernet Controller' })
$r = Invoke-NetworkSetup -Config $cfg -DriversDir 'x' 6>$null
Check 'wifi works + ethernet without driver -> OK'          ($r.networkDriverStatus -eq 'OK')

# 3) driver install printed errors but the card works -> OK, failures are not shown
$script:Problems = @(); $script:DriverInstallFailures = @('Failed to add driver package: something')
$out = Invoke-NetworkSetup -Config $cfg -DriversDir 'x' 6>&1 | Out-String
Check 'pnputil failures hidden when the card works'         ($out -notmatch 'Failed to add')

# 4) no Wi-Fi card, a network device without driver -> reported
$script:Adapter = $null; $script:Problems = @([pscustomobject]@{ Name = 'Network Controller' })
$r = Invoke-NetworkSetup -Config $cfg -DriversDir 'x' 6>$null
Check 'no card -> Missing driver: Network Controller'       ($r.networkDriverStatus -eq 'Missing driver: Network Controller' -and -not $r.wifiAdapter)

# 5) no Wi-Fi card, nothing found
$script:Problems = @()
$r = Invoke-NetworkSetup -Config $cfg -DriversDir 'x' 6>$null
Check 'no card, no device -> No Wi-Fi adapter found'        ($r.networkDriverStatus -eq 'No Wi-Fi adapter found')
if ($fail) { throw "$fail check(s) failed" }
