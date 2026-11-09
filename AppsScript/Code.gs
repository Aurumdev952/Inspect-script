/**
 * Paste this into Extensions > Apps Script on the Google Sheet that should
 * collect inspection records, then deploy it as a Web App (Execute as: Me,
 * Who has access: Anyone). The deployment URL is the WebhookUrl that
 * Inspect-PC.ps1 posts records to (config.json on the flash disk).
 */

var SHEET_NAME = 'Inspections';

// Optional: write to a specific tab instead of SHEET_NAME. Use the number
// after "gid=" in the Sheet's URL (e.g. ...edit#gid=1001 -> 1001).
var SHEET_GID = 1001;

var COLUMNS = [
  'timestamp', 'inspector', 'serialNumber', 'hostname', 'manufacturer', 'model',
  'category', 'categorySource', 'contractModel', 'overallResult', 'notes',
  'modelCheck', 'cpuModel', 'cpuCheck', 'ramGB', 'ramCheck', 'diskGB', 'storageCheck',
  'gpuCheck', 'displayCheck', 'touchCheck', 'fingerprintCheck', 'batteryCheck',
  'wifi6eCheck', 'bluetoothCheck', 'cameraCheck', 'tpmCheck',
  'os', 'osBuild', 'osCheck', 'activationCheck', 'condition', 'diskPowerOnHours',
  'wifiAdapter', 'wifiDriverVersion', 'networkDriverStatus', 'wifiConnected', 'internetOk',
  'toolVersion'
];

// Filled in by this script, not sent by the PC: 1 for the first inspection of
// a serial number in this tab, 2 for the next one, and so on.
var NUMBER_HEADER = 'Inspection #';

var HEADER_ROW = [
  'Timestamp', 'Inspector', 'Serial Number', 'Hostname', 'Manufacturer', 'Model',
  'Category', 'Category From', 'Contract Model', 'Overall Result', 'Notes',
  'Model Check', 'CPU', 'CPU Check', 'RAM (GB)', 'RAM Check', 'Disk (GB)', 'Storage Check',
  'Graphics Check', 'Screen Check', 'Touch Check', 'Fingerprint Check', 'Battery Check',
  'Wi-Fi 6E Check', 'Bluetooth Check', 'Camera Check', 'TPM Check',
  'OS', 'OS Build', 'OS Check', 'Activation Check', 'Condition (New?)', 'Disk Power-On Hours',
  'Wi-Fi Adapter', 'Wi-Fi Driver Version', 'Network Driver Status', 'Wi-Fi Connected', 'Internet OK',
  'Tool Version',
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
