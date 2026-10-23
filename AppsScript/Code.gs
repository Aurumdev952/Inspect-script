/**
 * Paste this into Extensions > Apps Script on the Google Sheet that should
 * collect inspection records, then deploy it as a Web App (Execute as: Me,
 * Who has access: Anyone with the link). The deployment URL is both:
 *   - the -WebhookUrl value Inspect-PC.ps1 posts records to, and
 *   - the download URL for the script itself (see doGet below).
 */

var SHEET_NAME = 'Inspections';

// Optional: write to a specific tab instead of SHEET_NAME. Use the number
// after "gid=" in the Sheet's URL (e.g. ...edit#gid=418189154 -> 418189154).
var SHEET_GID = 418189154;

var COLUMNS = [
  'timestamp', 'inspector', 'serialNumber', 'hostname', 'os', 'osBuild',
  'activationStatus', 'cpuModel', 'cpuSpecStatus', 'ramGB', 'ramSpecStatus',
  'diskGB', 'diskSpecStatus', 'diskMediaType', 'diskTypeStatus',
  'condition', 'diskPowerOnHours', 'overallResult', 'notes',
  'wifiAdapter', 'wifiDriverVersion', 'networkDriverStatus', 'wifiConnected', 'internetOk'
];

// Filled in by this script, not sent by the PC: 1 for the first inspection of
// a serial number in this tab, 2 for the next one, and so on.
var NUMBER_HEADER = 'Inspection #';

var HEADER_ROW = [
  'Timestamp', 'Inspector', 'Serial Number', 'Hostname', 'OS', 'OS Build',
  'Activation Status', 'CPU Model', 'CPU Spec Status', 'RAM (GB)', 'RAM Spec Status',
  'Disk (GB)', 'Disk Spec Status', 'Disk Media Type', 'Disk Type Status',
  'Condition (New?)', 'Disk Power-On Hours', 'Overall Result', 'Notes',
  'Wi-Fi Adapter', 'Wi-Fi Driver Version', 'Network Driver Status', 'Wi-Fi Connected', 'Internet OK',
  NUMBER_HEADER
];

function doPost(e) {
  // One upload at a time: two requests can't both pass the duplicate check
  // and then both append the same serial number.
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    return handlePost_(e);
  } finally {
    lock.releaseLock();
  }
}

function handlePost_(e) {
  var sheet = getTargetSheet_();
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(HEADER_ROW);
  } else if (sheet.getLastColumn() < HEADER_ROW.length) {
    // Sheet was created by an older version - add the new column headers.
    sheet.getRange(1, 1, 1, HEADER_ROW.length).setValues([HEADER_ROW]);
  }

  var data = JSON.parse(e.postData.contents);
  var found = findInspections_(sheet, data.serialNumber, data.timestamp);

  // Every inspection is its own row, so a PC inspected again (for example
  // after a Wi-Fi card was added) keeps its earlier rows. The only thing
  // refused is the very same inspection arriving twice (same serial number
  // AND same timestamp), e.g. when the answer to an upload got lost and the
  // PC sent it again.
  if (found.sameRun) {
    return ContentService
      .createTextOutput(JSON.stringify({
        status: 'duplicate',
        message: 'Serial number ' + data.serialNumber + ' was already saved for this inspection (' +
          found.sameRun.timestamp + ' by ' + found.sameRun.inspector + ').'
      }))
      .setMimeType(ContentService.MimeType.JSON);
  }

  var row = COLUMNS.map(function (key) { return data[key] !== undefined ? data[key] : ''; });
  row.push(found.count + 1);
  sheet.appendRow(row);

  return ContentService
    .createTextOutput(JSON.stringify({ status: 'ok', inspectionNumber: found.count + 1 }))
    .setMimeType(ContentService.MimeType.JSON);
}

function getTargetSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  if (SHEET_GID !== null) {
    var tabs = ss.getSheets();
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].getSheetId() === Number(SHEET_GID)) return tabs[i];
    }
  }
  return ss.getSheetByName(SHEET_NAME) || ss.insertSheet(SHEET_NAME);
}

// Looks only at this tab. Returns how many rows already have this serial
// number, and the row that is the very same inspection (same serial number
// and same timestamp), if any.
function findInspections_(sheet, serialNumber, timestamp) {
  var result = { count: 0, sameRun: null };
  var serial = String(serialNumber || '').trim();
  var lastRow = sheet.getLastRow();
  if (!serial || lastRow < 2) return result;

  var serialIdx = COLUMNS.indexOf('serialNumber');
  var tsIdx = COLUMNS.indexOf('timestamp');
  var inspectorIdx = COLUMNS.indexOf('inspector');
  var tz = SpreadsheetApp.getActiveSpreadsheet().getSpreadsheetTimeZone();
  var values = sheet.getRange(2, 1, lastRow - 1, COLUMNS.length).getValues();

  // Sheets turns "2026-10-23 11:23:47" into a date; turn it back into text
  // before comparing with what the PC sent.
  function asText(v) {
    return v instanceof Date ? Utilities.formatDate(v, tz, 'yyyy-MM-dd HH:mm:ss') : String(v).trim();
  }

  for (var i = 0; i < values.length; i++) {
    if (String(values[i][serialIdx]).trim() !== serial) continue;
    result.count++;
    if (!result.sameRun && asText(values[i][tsIdx]) === String(timestamp || '').trim()) {
      result.sameRun = { row: i + 2, timestamp: asText(values[i][tsIdx]), inspector: values[i][inspectorIdx] };
    }
  }
  return result;
}

/**
 * Serves Inspect-PC.ps1's own content, with this deployment's own URL
 * already baked in as the default -WebhookUrl, so a PC only needs:
 *
 *   Invoke-WebRequest "<this deployment URL>" -OutFile Inspect-PC.ps1
 *   powershell -ExecutionPolicy Bypass -File Inspect-PC.ps1
 *
 * Keep PS1_TEMPLATE in sync with the canonical Inspect-PC.ps1 in the repo
 * whenever the inspection logic changes.
 */
function doGet(e) {
  var webAppUrl = ScriptApp.getService().getUrl();
  var script = PS1_TEMPLATE.replace('__WEBHOOK_URL__', webAppUrl);
  return ContentService.createTextOutput(script).setMimeType(ContentService.MimeType.TEXT);
}

var PS1_TEMPLATE = "<#\n.SYNOPSIS\n  Inspects the local Windows PC's hardware/OS against the target spec\n  (Intel Core i5, 14th generation; 8GB RAM; 256GB SSD; Windows, activated)\n  and uploads one record to a shared Google Sheet via an Apps Script webhook.\n\n.USAGE\n  Easiest: double-click Run-Inspection.bat in this same folder - it calls\n  this script for you with no PowerShell knowledge required.\n\n  Manual: .\\Inspect-PC.ps1\n  (reads the webhook URL from config.json next to this script, and asks\n  for your name once, then remembers it for the next PC on this USB/share)\n\n  Every run also appends to a local CSV (inspection-log.csv next to this\n  script) so nothing is lost even if the upload fails (e.g. no internet -\n  the backup rows can be pasted into the Sheet later).\n#>\n\nparam(\n    [string]$WebhookUrl = '__WEBHOOK_URL__',\n    [string]$Inspector,\n    [string]$ConfigPath   = \"$PSScriptRoot\\config.json\",\n    [string]$InspectorCachePath = \"$PSScriptRoot\\inspector-name.txt\",\n    [string]$LogPath      = \"$PSScriptRoot\\inspection-log.csv\"\n)\n\nif (-not $WebhookUrl) {\n    if (Test-Path $ConfigPath) {\n        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json\n        $WebhookUrl = $config.WebhookUrl\n    }\n    if (-not $WebhookUrl) {\n        Write-Host \"No webhook URL found. Edit config.json (next to this script) and set WebhookUrl to the Google Apps Script URL.\" -ForegroundColor Red\n        if ($Host.Name -eq 'ConsoleHost') { Read-Host \"Press Enter to exit\" | Out-Null }\n        exit 1\n    }\n}\n\nif (-not $Inspector) {\n    if (Test-Path $InspectorCachePath) {\n        $Inspector = (Get-Content $InspectorCachePath -Raw).Trim()\n    }\n    if (-not $Inspector) {\n        $Inspector = Read-Host \"Enter your name (inspector)\"\n        $Inspector | Out-File -FilePath $InspectorCachePath -Encoding UTF8 -NoNewline\n    }\n}\n\nfunction Get-CpuSpecStatus {\n    param([string]$CpuName)\n\n    # Target: Intel Core i5, 14th generation (e.g. i5-14400, i5-1440P, \"14th Gen Intel(R) Core(TM) i5-...\")\n    $is14thGenI5 = ($CpuName -match 'i5-14\\d{2}') -or ($CpuName -match '14th Gen.*i5')\n    if ($is14thGenI5) { return 'Meets spec (i5, 14th gen)' }\n\n    $genMatch = [regex]::Match($CpuName, 'i([3579])-(\\d{1,2})\\d{3}')\n    if ($genMatch.Success) {\n        $tier = [int]$genMatch.Groups[1].Value\n        $gen  = [int]$genMatch.Groups[2].Value\n\n        if ($tier -eq 5) {\n            if ($gen -lt 14) { return \"Below spec (i5, ${gen}th gen)\" }\n            else { return \"Above spec (i5, ${gen}th gen)\" }\n        } elseif ($tier -lt 5) {\n            return \"Below spec (i$tier, ${gen}th gen)\"\n        } else {\n            return \"Above spec (i$tier, ${gen}th gen)\"\n        }\n    }\n\n    return \"Unknown - verify manually ($CpuName)\"\n}\n\nfunction Get-RamSpecStatus {\n    param([double]$RamGB)\n\n    # Windows reports a bit less than a stick's labeled size (some is\n    # reserved for the BIOS/integrated graphics), so an \"8GB\" machine often\n    # reads as ~7.7GB. Snap to the nearest standard RAM size instead of\n    # comparing the raw reading exactly, same approach as the disk check.\n    $standardSizesGB = 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128\n    $closest = $standardSizesGB | Sort-Object { [math]::Abs($_ - $RamGB) } | Select-Object -First 1\n\n    if ($closest -lt 8) { return \"Below spec (~${closest}GB RAM, raw ${RamGB}GB)\" }\n    elseif ($closest -eq 8) { return \"Meets spec (8GB)\" }\n    else { return \"Above spec (~${closest}GB RAM, raw ${RamGB}GB)\" }\n}\n\nfunction Get-PrimaryDiskSizeGB {\n    # Disks report raw bytes a bit under their marketed decimal-GB capacity\n    # (e.g. a \"256GB\" SSD reports ~256,060,514,304 bytes), so divide by\n    # 1000^3, not 1024^3, to land on the label the box was sold with.\n    try {\n        $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop\n        return [math]::Round($disk.Size / 1000000000, 0)\n    } catch {\n        try {\n            $drive = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1\n            return [math]::Round($drive.Size / 1000000000, 0)\n        } catch {\n            return $null\n        }\n    }\n}\n\nfunction Get-DiskSpecStatus {\n    param($DiskGB)\n\n    if ($null -eq $DiskGB) { return \"Unknown - verify manually\" }\n\n    # Snap the raw reading to the nearest standard drive size so e.g. 238GB\n    # raw (a genuine 256GB SSD) doesn't read as \"below spec\".\n    $standardSizesGB = 64, 120, 128, 240, 250, 256, 480, 500, 512, 960, 1000, 1024, 2000, 2048\n    $closest = $standardSizesGB | Sort-Object { [math]::Abs($_ - $DiskGB) } | Select-Object -First 1\n\n    if ($closest -lt 256) { return \"Below spec (~${closest}GB disk, raw ${DiskGB}GB)\" }\n    elseif ($closest -eq 256) { return \"Meets spec (256GB)\" }\n    else { return \"Above spec (~${closest}GB disk, raw ${DiskGB}GB)\" }\n}\n\nfunction Get-PrimaryDiskMediaType {\n    try {\n        $physicalDisk = Get-Partition -DriveLetter C -ErrorAction Stop |\n            Get-Disk -ErrorAction Stop |\n            Get-PhysicalDisk -ErrorAction Stop |\n            Select-Object -First 1\n        if ($physicalDisk -and $physicalDisk.MediaType -and $physicalDisk.MediaType -ne 'Unspecified') {\n            return [string]$physicalDisk.MediaType\n        }\n    } catch {}\n    try {\n        $physicalDisk = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1\n        if ($physicalDisk -and $physicalDisk.MediaType -and $physicalDisk.MediaType -ne 'Unspecified') {\n            return [string]$physicalDisk.MediaType\n        }\n    } catch {}\n    return $null\n}\n\nfunction Get-DiskTypeStatus {\n    param([string]$MediaType)\n\n    if (-not $MediaType) { return \"Unknown - verify manually\" }\n    if ($MediaType -eq 'SSD') { return 'Meets spec (SSD)' }\n    return \"Below spec ($MediaType, not SSD)\"\n}\n\nfunction Get-WindowsActivationStatus {\n    # ApplicationID below is the fixed \"Windows activation technologies\" ID,\n    # used to filter out any non-Windows entries (e.g. Office) in the table.\n    try {\n        $product = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop `\n            -Filter \"ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL\" |\n            Select-Object -First 1\n        if ($product) {\n            $statusMap = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine Grace'; 5 = 'Notification'; 6 = 'Extended Grace' }\n            $label = $statusMap[[int]$product.LicenseStatus]\n            if ($label) { return $label }\n        }\n    } catch {}\n    return 'Unknown - verify manually (run slmgr /xpr)'\n}\n\nfunction Write-SpecLine {\n    param([string]$Label, [string]$Status, [string]$Detail = $Status)\n\n    $color = switch -Wildcard ($Status) {\n        'Meets spec*' { 'Green' }\n        'Below spec*' { 'Red' }\n        'Above spec*' { 'Yellow' }\n        default       { 'DarkYellow' }\n    }\n    Write-Host (\"  {0,-12}: {1}\" -f $Label, $Detail) -ForegroundColor $color\n}\n\nfunction Write-BoolLine {\n    param([string]$Label, [bool]$Pass, [string]$Detail)\n\n    $color = if ($Pass) { 'Green' } else { 'Red' }\n    Write-Host (\"  {0,-12}: {1}\" -f $Label, $Detail) -ForegroundColor $color\n}\n\n# --- Gather hardware/OS info ---\n$bios = Get-CimInstance Win32_BIOS\n$cs   = Get-CimInstance Win32_ComputerSystem\n$os   = Get-CimInstance Win32_OperatingSystem\n$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1\n\n$serialNumber = $bios.SerialNumber.Trim()\n$hostname     = $env:COMPUTERNAME\n$cpuModel     = $cpu.Name.Trim()\n$ramGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)\n$osCaption    = $os.Caption\n$osBuild      = $os.BuildNumber\n$isWindows    = $osCaption -match 'Windows'\n\nWrite-Host \"`nInspecting $hostname (serial: $serialNumber) as $Inspector...\" -ForegroundColor Cyan\nWrite-BoolLine \"OS\" $isWindows $osCaption\n\n# Best-effort \"new / unused\" check: disk power-on hours (when the storage\n# driver exposes reliability counters) plus OS install date as a fallback\n# signal. This cannot prove a machine is factory-new - flag for manual\n# confirmation when the signal is unavailable.\n$installDate = $os.InstallDate\n$daysSinceInstall = if ($installDate) { (New-TimeSpan -Start $installDate -End (Get-Date)).Days } else { $null }\n\n$powerOnHours = $null\ntry {\n    $counters = Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop\n    if ($counters) {\n        $powerOnHours = ($counters | Where-Object { $_.PowerOnHours -ne $null } | Measure-Object -Property PowerOnHours -Minimum).Minimum\n    }\n} catch {\n    $powerOnHours = $null\n}\n\nif ($null -ne $powerOnHours) {\n    $condition = if ($powerOnHours -le 24) { \"Likely new (disk power-on hours: $powerOnHours)\" }\n                 else { \"Likely used (disk power-on hours: $powerOnHours)\" }\n} elseif ($null -ne $daysSinceInstall) {\n    $condition = \"Unverified - manual check needed (Windows installed $daysSinceInstall day(s) ago)\"\n} else {\n    $condition = \"Unverified - manual check needed\"\n}\n$conditionColor = if ($condition -like 'Likely new*') { 'Green' } elseif ($condition -like 'Likely used*') { 'Gray' } else { 'DarkYellow' }\nWrite-Host (\"  {0,-12}: {1}\" -f \"Condition\", $condition) -ForegroundColor $conditionColor\n\n$activationStatus = Get-WindowsActivationStatus\n$isActivated    = $activationStatus -eq 'Licensed'\nWrite-BoolLine \"Activation\" $isActivated $activationStatus\n\n$cpuSpecStatus  = Get-CpuSpecStatus -CpuName $cpuModel\nWrite-SpecLine \"CPU\" $cpuSpecStatus \"$cpuModel -> $cpuSpecStatus\"\n\n$ramSpecStatus  = Get-RamSpecStatus -RamGB $ramGB\nWrite-SpecLine \"RAM\" $ramSpecStatus \"${ramGB}GB -> $ramSpecStatus\"\n\n$diskGB         = Get-PrimaryDiskSizeGB\n$diskSpecStatus = Get-DiskSpecStatus -DiskGB $diskGB\nWrite-SpecLine \"Disk size\" $diskSpecStatus\n\n$diskMediaType  = Get-PrimaryDiskMediaType\n$diskTypeStatus = Get-DiskTypeStatus -MediaType $diskMediaType\nWrite-SpecLine \"Disk type\" $diskTypeStatus \"$diskMediaType -> $diskTypeStatus\"\n\n# \"Above spec\" (e.g. a 512GB disk when 256GB is the minimum) is a pass, not\n# a failure - only \"Below spec\" (and unreadable/\"Unknown\") statuses count\n# against a PC. Everything else exceeds or meets the requirement.\nfunction Test-SpecOk {\n    param([string]$Status)\n    return ($Status -like 'Meets spec*') -or ($Status -like 'Above spec*')\n}\n\n$overallPass = $isWindows -and $isActivated -and\n    (Test-SpecOk $cpuSpecStatus) -and\n    (Test-SpecOk $ramSpecStatus) -and\n    (Test-SpecOk $diskSpecStatus) -and\n    (Test-SpecOk $diskTypeStatus)\n$overallResult = if ($overallPass) { 'PASS' } else { 'FAIL' }\n\n$notes = @()\nif (-not $isWindows) { $notes += \"OS is not Windows ($osCaption)\" }\nif (-not $isActivated) { $notes += \"Windows not activated ($activationStatus)\" }\nif (-not (Test-SpecOk $cpuSpecStatus)) { $notes += $cpuSpecStatus }\nif (-not (Test-SpecOk $ramSpecStatus)) { $notes += $ramSpecStatus }\nif (-not (Test-SpecOk $diskSpecStatus)) { $notes += $diskSpecStatus }\nif (-not (Test-SpecOk $diskTypeStatus)) { $notes += $diskTypeStatus }\nif ($condition -like 'Unverified*') { $notes += 'Condition needs manual confirmation' }\n$notesText = ($notes -join '; ')\n\n$overallColor = if ($overallPass) { 'Green' } else { 'Red' }\nWrite-Host (\"`n  === OVERALL: {0} ===\" -f $overallResult) -ForegroundColor $overallColor\nif ($notesText) { Write-Host \"  Reasons: $notesText\" -ForegroundColor Yellow }\n\n$record = [ordered]@{\n    timestamp         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')\n    inspector         = $Inspector\n    serialNumber      = $serialNumber\n    hostname          = $hostname\n    os                = $osCaption\n    osBuild           = $osBuild\n    activationStatus  = $activationStatus\n    cpuModel          = $cpuModel\n    cpuSpecStatus     = $cpuSpecStatus\n    ramGB             = $ramGB\n    ramSpecStatus     = $ramSpecStatus\n    diskGB            = $diskGB\n    diskSpecStatus    = $diskSpecStatus\n    diskMediaType     = $diskMediaType\n    diskTypeStatus    = $diskTypeStatus\n    condition         = $condition\n    diskPowerOnHours  = $powerOnHours\n    overallResult     = $overallResult\n    notes             = $notesText\n}\n\n# --- Local backup log (always written, even if the upload fails) ---\n[PSCustomObject]$record | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8\nWrite-Host \"  Logged to: $LogPath\" -ForegroundColor DarkGray\n\n# --- Upload to Google Sheet ---\ntry {\n    $json = $record | ConvertTo-Json -Depth 3\n    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $json -ContentType 'application/json'\n    if ($response.status -eq 'duplicate') {\n        Write-Host \"  NOT SAVED: $($response.message)`n\" -ForegroundColor Red\n    } else {\n        Write-Host \"  Uploaded to Google Sheet.`n\" -ForegroundColor Green\n    }\n} catch {\n    Write-Warning \"  Upload FAILED (row is still safe in $LogPath - copy it into the Sheet later). Error: $($_.Exception.Message)\"\n    Write-Host \"\"\n}\n";
