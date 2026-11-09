param([string]$Scripts = (Join-Path $PSScriptRoot '..\scripts'))
$ErrorActionPreference = 'Stop'
. (Join-Path $Scripts 'Lot2-Spec.ps1')
$fail = 0
function Check($name, $ok) { if ($ok) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
function Status($r, $key) { ($r.Checks | Where-Object Key -eq $key).Status }

function Pc([hashtable]$Over) {
    $f = @{
        Manufacturer = 'HP'; Model = 'HP EliteBook 640 14 inch G11 Notebook PC'
        CpuName = 'Intel(R) Core(TM) Ultra 7 155U'; RamGB = 15.6; DiskGB = 1024; DiskMediaType = 'SSD'
        GpuNames = @('Intel(R) Graphics'); PanelWidth = 1920; PanelHeight = 1200; PanelInches = 14.0
        HasTouch = $true; WifiAdapter = 'Intel(R) Wi-Fi 6E AX211 160MHz'; HasBluetooth = $true; HasCamera = $true
        FingerprintName = 'Synaptics FP Sensors (WBF)'; TpmVersion = '2.0'; BatteryWh = 56
        OsCaption = 'Microsoft Windows 11 Pro'; Activation = 'Licensed'
    }
    foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
    $f
}

$r = Get-Lot2Evaluation (Pc @{})
Check 'EliteBook 640 G11 with touch, 16GB, 1TB -> category 6, PASS' ($r.Category -eq '6' -and $r.Pass -and $r.Source -like 'auto*touch*')

$r = Get-Lot2Evaluation (Pc @{ HasTouch = $false; RamGB = 7.7; DiskGB = 512; BatteryWh = 60 })
Check 'EliteBook 640 G11 without touch, 8GB, 512GB -> category 5, PASS' ($r.Category -eq '5' -and $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ RamGB = 7.7; DiskGB = 512 }) -Category 6
Check 'inspector says category 6 but PC has 8GB/512GB -> FAIL on RAM and storage' (-not $r.Pass -and (Status $r ram) -eq 'Below' -and (Status $r storage) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{}) -Category 7
Check 'inspector says category 7 but PC is an EliteBook -> FAIL on model' (-not $r.Pass -and (Status $r model) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ Model = 'HP ProBook 450 G10'; CpuName = 'Intel(R) Core(TM) i5-1335U' })
Check 'model not in contract -> FAIL' (-not $r.Pass -and (Status $r model) -eq 'Below' -and -not $r.Model)

$r = Get-Lot2Evaluation (Pc @{ Model = 'HP OmniBook 5 Flip Laptop 14-fp0xxx'; CpuName = 'Intel(R) Core(TM) 7 150U'; FingerprintName = $null; BatteryWh = 43 })
Check 'OmniBook 5 Flip (alternative) with Core 7 150U -> PASS, no fingerprint/battery check' ($r.Pass -and $r.Model.Alternative -and -not (Status $r fingerprint) -and -not (Status $r battery))

$r = Get-Lot2Evaluation (Pc @{ Model = 'HP ZBook Fury 16 inch G11 Mobile Workstation PC'; CpuName = 'Intel(R) Core(TM) i7-14650HX'
    GpuNames = @('Intel(R) UHD Graphics', 'NVIDIA RTX 4060 Laptop GPU'); PanelWidth = 1920; PanelHeight = 1200; PanelInches = 16.1; HasTouch = $false; BatteryWh = 83 })
Check 'ZBook Fury 16 G11, i7-14650HX, RTX 4060 -> category 7, PASS' ($r.Category -eq '7' -and $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ Model = 'HP ZBook Fury 16 inch G11 Mobile Workstation PC'; CpuName = 'Intel(R) Core(TM) i7-14650HX'
    GpuNames = @('Microsoft Basic Display Adapter'); PanelInches = 16; BatteryWh = 83 })
Check 'category 7 with no NVIDIA driver -> GPU unknown, FAIL (core check)' (-not $r.Pass -and (Status $r gpu) -eq 'Unknown')

$r = Get-Lot2Evaluation (Pc @{ Model = 'HP ZBook Fury 16 inch G11 Mobile Workstation PC'; CpuName = 'Intel(R) Core(TM) i7-14650HX'
    GpuNames = @('NVIDIA GeForce RTX 4050 Laptop GPU'); PanelInches = 16; BatteryWh = 83 })
Check 'category 7 with RTX 4050 (6GB) -> FAIL' (-not $r.Pass -and (Status $r gpu) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ Model = 'OMEN Gaming Laptop 16-ap0xxx'; CpuName = 'Intel(R) Core(TM) Ultra 7 255H'
    GpuNames = @('NVIDIA GeForce RTX 5060 Laptop GPU'); PanelInches = 16.1; HasTouch = $false; FingerprintName = $null; BatteryWh = $null })
Check 'OMEN 16 (alternative for category 7) -> PASS' ($r.Category -eq '7' -and $r.Model.Alternative -and $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ Manufacturer = 'Getac'; Model = 'X600 Pro'; CpuName = '11th Gen Intel(R) Core(TM) i7-11850HE @ 2.60GHz'
    RamGB = 31.7; DiskGB = 2048; GpuNames = @('NVIDIA Quadro RTX 3000'); PanelWidth = 1920; PanelHeight = 1080; PanelInches = 15.6
    HasTouch = $false; FingerprintName = $null; WifiAdapter = 'Intel(R) Wi-Fi 6E AX210 160MHz'; BatteryWh = $null })
Check 'Getac X600 Pro -> category 8, PASS' ($r.Category -eq '8' -and $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ OsCaption = 'Microsoft Windows 11 Home' })
Check 'Windows 11 Home -> FAIL' (-not $r.Pass -and (Status $r os) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ Activation = 'Notification' })
Check 'not activated -> FAIL' (-not $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ WifiAdapter = 'Intel(R) Wi-Fi 6 AX201 160MHz' })
Check 'Wi-Fi 6 (not 6E) AX201 -> FAIL' (-not $r.Pass -and (Status $r wifi6e) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ WifiAdapter = $null })
Check 'no Wi-Fi card -> FAIL' (-not $r.Pass)

$r = Get-Lot2Evaluation (Pc @{ WifiAdapter = 'Some New Wireless Card'; FingerprintName = $null; HasCamera = $false })
Check 'unrecognised Wi-Fi name, no fingerprint, no camera -> PASS with checks by hand' ($r.Pass -and $r.ByHand.Count -eq 3)

$r = Get-Lot2Evaluation (Pc @{ DiskMediaType = 'HDD' })
Check 'hard disk instead of SSD -> FAIL' (-not $r.Pass -and (Status $r storage) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ PanelWidth = 1366; PanelHeight = 768 })
Check 'low-resolution screen -> FAIL' (-not $r.Pass -and (Status $r display) -eq 'Below')

$r = Get-Lot2Evaluation (Pc @{ TpmVersion = '1.2' })
Check 'TPM 1.2 -> FAIL' (-not $r.Pass -and (Status $r tpm) -eq 'Below')

if ($fail) { "$fail test(s) failed"; exit 1 }
'All Lot 2 spec tests passed'
exit 0
