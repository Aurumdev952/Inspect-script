<#
  Lot 2 laptops: contract 000008/G/ICB/2024/2025/RISA (SALTEL), Amendment No. 2.
  One row per contract model: categories 5-8 and the alternative model the
  amendment allows for each. Specs not listed for an alternative are not
  checked for it (the amendment lists only CPU, graphics, RAM, storage and
  display for alternatives).

  Get-Lot2Evaluation takes the facts read from a PC and returns the chosen
  contract model and one result per check. It reads nothing from Windows, so
  tests can feed it any PC.
#>

$script:Lot2Models = @(
    [pscustomobject]@{
        Id = '5'; Category = 5; Alternative = $false; PriceRwf = 2009540
        Name = 'HP EliteBook 640 14 inch G11'; ModelMatch = 'EliteBook 640.*G11'
        Cpu = @{ Label = 'Intel Core Ultra 7'; Meets = 'Ultra 7'; Above = 'Ultra 9' }
        RamGB = 8; DiskGB = 512; Gpu = $null
        Screen = @{ Width = 1920; Height = 1200; Inches = 14 }; Touch = $false
        Fingerprint = $true; BatteryWh = 60
    }
    [pscustomobject]@{
        Id = '5-alt'; Category = 5; Alternative = $true; PriceRwf = 2009540
        Name = 'HP OmniBook 5 Flip'; ModelMatch = 'OmniBook 5 Flip'
        Cpu = @{ Label = 'Intel Core 7 (10 cores, 12 threads)'; Meets = 'Core\(TM\) 7 \d|Core 7 \d'; Above = 'Ultra [79]|Core\(TM\) 9 \d|Core 9 \d' }
        RamGB = 16; DiskGB = 1000; Gpu = $null
        Screen = @{ Width = 1920; Height = 1200; Inches = 14 }; Touch = $false
        Fingerprint = $null; BatteryWh = $null
    }
    [pscustomobject]@{
        Id = '6'; Category = 6; Alternative = $false; PriceRwf = 1964700
        Name = 'HP EliteBook 640 14 inch G11'; ModelMatch = 'EliteBook 640.*G11'
        Cpu = @{ Label = 'Intel Core Ultra 7'; Meets = 'Ultra 7'; Above = 'Ultra 9' }
        RamGB = 16; DiskGB = 1000; Gpu = $null
        Screen = @{ Width = 1920; Height = 1200; Inches = 14 }; Touch = $true
        Fingerprint = $true; BatteryWh = 55
    }
    [pscustomobject]@{
        Id = '6-alt'; Category = 6; Alternative = $true; PriceRwf = 1964700
        Name = 'HP OmniBook 5 Flip'; ModelMatch = 'OmniBook 5 Flip'
        Cpu = @{ Label = 'Intel Core 7 (10 cores, 12 threads)'; Meets = 'Core\(TM\) 7 \d|Core 7 \d'; Above = 'Ultra [79]|Core\(TM\) 9 \d|Core 9 \d' }
        RamGB = 16; DiskGB = 1000; Gpu = $null
        Screen = @{ Width = 1920; Height = 1200; Inches = 14 }; Touch = $true
        Fingerprint = $null; BatteryWh = $null
    }
    [pscustomobject]@{
        Id = '7'; Category = 7; Alternative = $false; PriceRwf = 5900000
        Name = 'HP ZBook Fury 16 G11'; ModelMatch = 'ZBook Fury 16.*G11'
        Cpu = @{ Label = 'Intel Core i7-14650HX'; Meets = 'i7-14\d{3}HX'; Above = 'i9-1[4-9]\d{3}HX' }
        RamGB = 16; DiskGB = 1000
        Gpu = @{ Label = 'NVIDIA GeForce RTX 40 series, 8GB'; Meets = 'RTX 40[6-9]0'; Above = 'RTX 50[6-9]0' }
        Screen = @{ Width = 1920; Height = 1080; Inches = 16 }; Touch = $null
        Fingerprint = $true; BatteryWh = 80
    }
    [pscustomobject]@{
        Id = '7-alt'; Category = 7; Alternative = $true; PriceRwf = 5900000
        Name = 'HP OMEN 16'; ModelMatch = 'OMEN.*16'
        Cpu = @{ Label = 'Intel Core Ultra 7 255H'; Meets = 'Ultra 7 2\d\dH'; Above = 'Ultra 9 2\d\dH' }
        RamGB = 16; DiskGB = 1000
        Gpu = @{ Label = 'NVIDIA GeForce RTX 5060, 8GB'; Meets = 'RTX 5060'; Above = 'RTX 50[7-9]0' }
        Screen = @{ Width = 1920; Height = 1200; Inches = 16 }; Touch = $null
        Fingerprint = $null; BatteryWh = $null
    }
    [pscustomobject]@{
        Id = '8'; Category = 8; Alternative = $false; PriceRwf = 2006000
        Name = 'GETAC X600 Pro'; ModelMatch = 'X600'
        Cpu = @{ Label = 'Intel Core i7-11850HE'; Meets = 'i7-11850HE'; Above = 'i9-11\d{3}H' }
        RamGB = 32; DiskGB = 2000
        Gpu = @{ Label = 'NVIDIA Quadro RTX 3000, 6GB'; Meets = 'RTX 3000'; Above = 'RTX A?[45]000' }
        Screen = @{ Width = 1920; Height = 1080; Inches = 15.6 }; Touch = $null
        Fingerprint = $null; BatteryWh = $null
    }
)

# Wi-Fi 6E (6 GHz) cards and the Wi-Fi 6 cards that are often mistaken for them.
$script:Wifi6ENames = '6E|AX21[01]|AX411|BE20[0-2]|Wi-?Fi 7|MT7922|RZ61[68]|RZ7\d\d|QCNCM|FastConnect 7'
$script:Wifi6Only   = 'AX20[0-3]|AX101|MT7921|RTL8852|RTL8822|RTL8821|Wireless-AC|802\.11ac'

$script:StandardRamGB  = 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128
$script:StandardDiskGB = 128, 240, 250, 256, 480, 500, 512, 960, 1000, 1024, 2000, 2048, 4000, 4096

function Get-NearestSize {
    param([double]$Value, [double[]]$Sizes)
    $Sizes | Sort-Object { [math]::Abs($_ - $Value) } | Select-Object -First 1
}

function Format-Size([double]$GB) {
    if ($GB -ge 1000) { '{0:0.#}TB' -f ($GB / 1000) } else { "${GB}GB" }
}

# Status: Meets | Above | Below | Unknown. Core checks that come back Unknown
# fail the PC; other Unknowns only ask the inspector to look by hand.
function New-Check {
    param([string]$Key, [string]$Status, [string]$Detail, [switch]$Core)
    $prefix = @{ Meets = 'Meets spec'; Above = 'Above spec'; Below = 'Below spec'; Unknown = 'Check by hand' }[$Status]
    [pscustomobject]@{ Key = $Key; Status = $Status; Core = [bool]$Core; Text = "$prefix ($Detail)" }
}

function Test-PatternCheck {
    param([string]$Key, [string]$Actual, [hashtable]$Spec, [switch]$Core)
    if (-not $Actual) { return New-Check $Key Unknown "not readable; contract: $($Spec.Label)" -Core:$Core }
    if ($Actual -match $Spec.Meets) { return New-Check $Key Meets $Actual -Core:$Core }
    if ($Spec.Above -and $Actual -match $Spec.Above) { return New-Check $Key Above $Actual -Core:$Core }
    New-Check $Key Below "$Actual; contract: $($Spec.Label)" -Core:$Core
}

function Find-Lot2Model {
    # Returns @{ Model; Source; ModelMatches }. Category is what the inspector
    # picked (from the delivery note), or 0 to detect it from the PC.
    param([hashtable]$Facts, [int]$Category = 0)
    $pcName = "$($Facts.Manufacturer) $($Facts.Model)"
    $byModel = @($script:Lot2Models | Where-Object { $pcName -match $_.ModelMatch })

    if ($Category) {
        $inCategory = @($script:Lot2Models | Where-Object { $_.Category -eq $Category })
        $match = $byModel | Where-Object { $_.Category -eq $Category } | Select-Object -First 1
        if ($match) { return @{ Model = $match; Source = 'inspector'; ModelMatches = $true } }
        return @{ Model = $inCategory[0]; Source = 'inspector'; ModelMatches = $false }
    }

    if ($byModel.Count -eq 0) { return @{ Model = $null; Source = 'auto'; ModelMatches = $false } }
    if ($byModel.Count -eq 1) { return @{ Model = $byModel[0]; Source = 'auto'; ModelMatches = $true } }
    # Same laptop model in two categories (5 and 6): category 6 is the touch screen one.
    $wantTouch = [bool]$Facts.HasTouch
    $pick = $byModel | Where-Object { $_.Touch -eq $wantTouch } | Select-Object -First 1
    if (-not $pick) { $pick = $byModel[0] }
    $why = if ($wantTouch) { 'touch screen' } else { 'no touch screen' }
    @{ Model = $pick; Source = "auto ($why)"; ModelMatches = $true }
}

function Get-Lot2Evaluation {
    <#
      Facts (hashtable; any value may be $null when Windows could not read it):
        Manufacturer, Model, CpuName, RamGB, DiskGB, DiskMediaType, GpuNames[],
        PanelWidth, PanelHeight, PanelInches, HasTouch, WifiAdapter,
        HasBluetooth, HasCamera, FingerprintName, TpmVersion, BatteryWh,
        OsCaption, Activation
    #>
    param([hashtable]$Facts, [int]$Category = 0)

    $found = Find-Lot2Model -Facts $Facts -Category $Category
    $m = $found.Model
    $checks = [System.Collections.Generic.List[object]]::new()
    $pcName = "$($Facts.Manufacturer) $($Facts.Model)".Trim()

    if (-not $m) {
        $checks.Add((New-Check model Below "$pcName is not a Lot 2 contract model" -Core))
    } elseif (-not $found.ModelMatches) {
        $checks.Add((New-Check model Below "$pcName; category $Category is $(@($script:Lot2Models | Where-Object Category -eq $Category | ForEach-Object Name) -join ' or ')" -Core))
    } else {
        $alt = if ($m.Alternative) { ', approved alternative' } else { '' }
        $checks.Add((New-Check model Meets "$pcName = category $($m.Category)$alt" -Core))
    }

    if ($m) {
        $checks.Add((Test-PatternCheck cpu $Facts.CpuName $m.Cpu -Core))

        if ($null -eq $Facts.RamGB) { $checks.Add((New-Check ram Unknown 'not readable' -Core)) }
        else {
            $ram = Get-NearestSize $Facts.RamGB $script:StandardRamGB
            $st = if ($ram -lt $m.RamGB) { 'Below' } elseif ($ram -gt $m.RamGB) { 'Above' } else { 'Meets' }
            $checks.Add((New-Check ram $st "${ram}GB; contract: $($m.RamGB)GB" -Core))
        }

        if ($null -eq $Facts.DiskGB) { $checks.Add((New-Check storage Unknown 'not readable' -Core)) }
        else {
            $disk = Get-NearestSize $Facts.DiskGB $script:StandardDiskGB
            $type = if ($Facts.DiskMediaType) { $Facts.DiskMediaType } else { 'type unknown' }
            $detail = "$(Format-Size $disk) $type; contract: $(Format-Size $m.DiskGB) SSD"
            $st = if ($disk -lt $m.DiskGB * 0.98) { 'Below' } elseif ($Facts.DiskMediaType -and $Facts.DiskMediaType -ne 'SSD') { 'Below' }
                  elseif (-not $Facts.DiskMediaType) { 'Unknown' } elseif ($disk -gt $m.DiskGB * 1.05) { 'Above' } else { 'Meets' }
            $checks.Add((New-Check storage $st $detail -Core))
        }

        if ($m.Gpu) {
            $gpus = @($Facts.GpuNames | Where-Object { $_ })
            $hit = $gpus | Where-Object { $_ -match $m.Gpu.Meets -or ($m.Gpu.Above -and $_ -match $m.Gpu.Above) } | Select-Object -First 1
            if ($hit) { $checks.Add((Test-PatternCheck gpu $hit $m.Gpu -Core)) }
            elseif ($gpus -match 'NVIDIA') { $checks.Add((Test-PatternCheck gpu (@($gpus -match 'NVIDIA')[0]) $m.Gpu -Core)) }
            else { $checks.Add((New-Check gpu Unknown "found: $(if ($gpus) { $gpus -join ', ' } else { 'none' }) - NVIDIA driver missing?; contract: $($m.Gpu.Label)" -Core)) }
        }

        $s = $m.Screen
        if (-not $Facts.PanelWidth) { $checks.Add((New-Check display Unknown "not readable; contract: $($s.Inches) inch $($s.Width)x$($s.Height)")) }
        else {
            $size = if ($Facts.PanelInches) { ' {0:0.#} inch' -f $Facts.PanelInches } else { '' }
            $detail = "$($Facts.PanelWidth)x$($Facts.PanelHeight)$size; contract: $($s.Inches) inch $($s.Width)x$($s.Height)"
            $pixels = $Facts.PanelWidth * $Facts.PanelHeight
            $st = if ($pixels -lt $s.Width * $s.Height) { 'Below' }
                  elseif ($Facts.PanelInches -and [math]::Abs($Facts.PanelInches - $s.Inches) -gt 0.8) { 'Below' }
                  elseif ($pixels -gt $s.Width * $s.Height) { 'Above' } else { 'Meets' }
            $checks.Add((New-Check display $st $detail))
        }

        if ($null -ne $m.Touch) {
            $has = [bool]$Facts.HasTouch
            $st = if ($has -eq $m.Touch) { 'Meets' } elseif ($has) { 'Above' } else { 'Below' }
            $checks.Add((New-Check touch $st "$(if ($has) { 'touch screen' } else { 'no touch screen' }); contract: $(if ($m.Touch) { 'touch' } else { 'non-touch' })"))
        }

        if ($m.Fingerprint) {
            if ($Facts.FingerprintName) { $checks.Add((New-Check fingerprint Meets $Facts.FingerprintName)) }
            else { $checks.Add((New-Check fingerprint Unknown 'no fingerprint reader found by Windows; contract: fingerprint reader')) }
        }

        if ($m.BatteryWh) {
            if (-not $Facts.BatteryWh) { $checks.Add((New-Check battery Unknown "not readable; contract: $($m.BatteryWh)Wh")) }
            else {
                $st = if ($Facts.BatteryWh -lt $m.BatteryWh * 0.97) { 'Below' } elseif ($Facts.BatteryWh -gt $m.BatteryWh * 1.05) { 'Above' } else { 'Meets' }
                $checks.Add((New-Check battery $st ('{0:0}Wh design capacity; contract: {1}Wh' -f $Facts.BatteryWh, $m.BatteryWh)))
            }
        }
    }

    # Every Lot 2 laptop: Wi-Fi 6E, Bluetooth, camera, TPM 2.0, Windows 11 Pro activated.
    $wifi = $Facts.WifiAdapter
    if (-not $wifi) { $checks.Add((New-Check wifi6e Below 'no working Wi-Fi card' -Core)) }
    elseif ($wifi -match $script:Wifi6ENames) { $checks.Add((New-Check wifi6e Meets $wifi -Core)) }
    elseif ($wifi -match $script:Wifi6Only) { $checks.Add((New-Check wifi6e Below "$wifi is not Wi-Fi 6E" -Core)) }
    else { $checks.Add((New-Check wifi6e Unknown "$wifi - confirm it is Wi-Fi 6E")) }

    $checks.Add($(if ($Facts.HasBluetooth) { New-Check bluetooth Meets 'present' } else { New-Check bluetooth Unknown 'not found by Windows' }))
    $checks.Add($(if ($Facts.HasCamera) { New-Check camera Meets 'present' } else { New-Check camera Unknown 'not found by Windows' }))

    $tpm = "$($Facts.TpmVersion)"
    $checks.Add($(if (-not $tpm) { New-Check tpm Unknown 'not readable; contract: TPM 2.0' }
                  elseif ($tpm -match '^2\.') { New-Check tpm Meets "TPM $tpm" }
                  else { New-Check tpm Below "TPM $tpm; contract: TPM 2.0" }))

    $os = "$($Facts.OsCaption)"
    $checks.Add($(if (-not $os) { New-Check os Unknown 'not readable' -Core }
                  elseif ($os -match 'Windows 11 Pro') { New-Check os Meets $os -Core }
                  elseif ($os -match 'Windows 11 (Enterprise|Education)') { New-Check os Above $os -Core }
                  else { New-Check os Below "$os; contract: Windows 11 Pro" -Core }))

    $act = "$($Facts.Activation)"
    $checks.Add($(if ($act -eq 'Licensed') { New-Check activation Meets 'Licensed' -Core }
                  elseif (-not $act) { New-Check activation Unknown 'not readable (run slmgr /xpr)' -Core }
                  else { New-Check activation Below $act -Core }))

    $failed = @($checks | Where-Object { $_.Status -eq 'Below' -or ($_.Status -eq 'Unknown' -and $_.Core) })
    $byHand = @($checks | Where-Object { $_.Status -eq 'Unknown' -and -not $_.Core })

    [pscustomobject]@{
        Model    = $m
        Category = if ($m) { "$($m.Category)" } else { '' }
        Source   = $found.Source
        Checks   = $checks
        Pass     = $failed.Count -eq 0
        Failed   = $failed
        ByHand   = $byHand
    }
}
