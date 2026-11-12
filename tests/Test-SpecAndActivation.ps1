param([string]$Scripts)
$ErrorActionPreference = 'Stop'
. (Join-Path $Scripts 'Spec-Rules.ps1')
. (Join-Path $Scripts 'Windows-Activation.ps1')
$fail = 0
function Check($name, $ok) { if ($ok) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }

# --- CPU: only the i5-14500 passes ---
$cpus = @{
    'Intel(R) Core(TM) i5-14500'               = $true
    '14th Gen Intel(R) Core(TM) i5-14500'      = $true
    'Intel(R) Core(TM) i5-14500T'              = $false
    'Intel(R) Core(TM) i5-14400'               = $false
    'Intel(R) Core(TM) i5-14600K'              = $false
    '13th Gen Intel(R) Core(TM) i5-13500'      = $false
    'Intel(R) Core(TM) i7-14700'               = $false
    'Intel(R) Core(TM) i5-145000'              = $false
}
foreach ($cpu in $cpus.Keys) {
    Check "CPU '$cpu' -> $(if ($cpus[$cpu]) { 'pass' } else { 'fail' })" ((Test-SpecOk (Get-CpuSpecStatus $cpu)) -eq $cpus[$cpu])
}

# --- Activation (slmgr and the license query simulated) ---
$key = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
function Write-DetailLog { param($Line) $script:Logged += "$Line`n" }
function Invoke-Slmgr { param([string[]]$Arguments)
    $script:SlmgrCalls += , $Arguments
    if ($Arguments[0] -eq '/ipk') { return $script:IpkOutput }
    $script:Status = $script:StatusAfterAto
    return $script:AtoOutput
}
function Get-WindowsActivationStatus { $script:Status }
function Reset($ipk, $ato, $after) {
    $script:SlmgrCalls = @(); $script:Logged = ''
    $script:IpkOutput = $ipk; $script:AtoOutput = $ato; $script:StatusAfterAto = $after; $script:Status = 'Notification'
}

Reset '' '' 'Licensed'
$r = Invoke-WindowsActivation -CurrentStatus 'Licensed' -ProductKey $key 6>$null
Check 'already activated -> slmgr not run'          ($r.action -eq 'Already activated' -and $SlmgrCalls.Count -eq 0)

Reset '' '' 'Licensed'
$r = Invoke-WindowsActivation -CurrentStatus 'Notification' -ProductKey '' 6>$null
Check 'no key -> not activated, slmgr not run'      ($r.status -eq 'Notification' -and $r.action -like 'Not activated*' -and $SlmgrCalls.Count -eq 0)

Reset "Installed product key $key successfully." 'Activating Windows(R)... Product activated successfully.' 'Licensed'
$r = Invoke-WindowsActivation -CurrentStatus 'Notification' -ProductKey $key 6>$null
Check 'not activated + key -> /ipk then /ato'       ($SlmgrCalls.Count -eq 2 -and $SlmgrCalls[0][0] -eq '/ipk' -and $SlmgrCalls[0][1] -eq $key -and $SlmgrCalls[1][0] -eq '/ato')
Check '  -> Licensed, Activated now'                ($r.status -eq 'Licensed' -and $r.action -eq 'Activated now')
Check '  -> key not in the log'                     ($Logged -notmatch [regex]::Escape($key) -and $Logged -match 'slmgr /ipk')

Reset "Installed product key $key successfully." 'Error: 0xc004c770 The specified product key is valid but no license is available.' 'Notification'
$r = Invoke-WindowsActivation -CurrentStatus 'Unknown - verify manually (run slmgr /xpr)' -ProductKey $key 6>$null
Check 'online activation refused -> failed + code'  ($r.status -eq 'Notification' -and $r.action -eq 'Activation failed (0xC004C770)')

Reset "Error: 0xC004F069 On a computer running Microsoft Windows non-core edition, run 'slui.exe 0x2a 0xC004F069'" '' 'Licensed'
$r = Invoke-WindowsActivation -CurrentStatus 'Notification' -ProductKey $key 6>$null
Check 'key rejected (wrong edition) -> no /ato'     ($SlmgrCalls.Count -eq 1 -and $r.action -eq 'Activation failed - key not accepted (0xC004F069)')

Check 'actions never contain the key'               ($r.action -notmatch [regex]::Escape($key))

if ($fail) { "$fail check(s) failed"; exit 1 } else { 'All checks passed' }
