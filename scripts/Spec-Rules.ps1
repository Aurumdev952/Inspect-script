# Pass/fail rules for the target spec: Intel Core i5-14500 (exactly that
# model), 8GB RAM, 256GB SSD. Pure functions - Inspect-PC.ps1 reads the
# hardware and passes the readings in.

function Get-CpuSpecStatus {
    param([string]$CpuName)

    # Only the i5-14500 itself. Other 14th-gen i5s (i5-14400, i5-14500T,
    # i5-14600...) and every other CPU fail.
    if ($CpuName -match '\bi5-14500(?![0-9A-Za-z])') { return 'Meets spec (i5-14500)' }
    return "Not i5-14500 ($CpuName)"
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

function Get-DiskTypeStatus {
    param([string]$MediaType)

    if (-not $MediaType) { return "Unknown - verify manually" }
    if ($MediaType -eq 'SSD') { return 'Meets spec (SSD)' }
    return "Below spec ($MediaType, not SSD)"
}

# "Above spec" (e.g. a 512GB disk when 256GB is the minimum) is a pass, not
# a failure - only "Below spec", "Not ..." and unreadable/"Unknown" statuses
# count against a PC.
function Test-SpecOk {
    param([string]$Status)
    return ($Status -like 'Meets spec*') -or ($Status -like 'Above spec*')
}
