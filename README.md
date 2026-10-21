# PC Inspection (one-click, from a flash disk)

Double-click `PC-Inspection.exe` on a flash disk and it:

1. Asks for admin rights (needed to install drivers and add Wi-Fi).
2. Asks the inspector's name (remembered on the flash disk; Enter reuses it).
3. **Network:** if the Wi-Fi card has no working driver, installs drivers from
   `drivers\` on the flash disk, or downloads them from the links in
   `config.json`. Then adds your Wi-Fi networks and connects.
4. **Specs:** checks CPU (i5 14th gen), RAM (8GB), disk (256GB SSD), Windows
   activation, condition (disk power-on hours).
5. Shows **PASS / FAIL**, saves a row to `inspection-log.csv` on the flash
   disk, and uploads it to the Google Sheet.

## Set up a flash disk

1. Download `PC-Inspection-<version>.zip` from
   [Releases](../../releases/latest), unzip it, and copy the single
   `PC-Inspection` folder onto the flash disk. Everything needed is inside it:
   ```
   PC-Inspection\
   ├─ PC-Inspection.exe   <- double-click
   ├─ PC-Inspection.bat   <- backup if the exe is blocked
   ├─ config.json
   ├─ drivers\            (Wi-Fi drivers, included)
   └─ RUNME.txt
   ```
2. Edit `config.json`:

| Field | What to put |
|---|---|
| `WebhookUrl` | Google Apps Script web-app URL (from `AppsScript/Code.gs`) |
| `Inspectors` | List of inspector names shown as a numbered menu, e.g. `["Hugues", "Vanessa"]`. Empty = type the name. |
| `WifiNetworks` | List of `{ "Ssid", "Password", "Security" }`. Security: `WPA2PSK` (default), `WPA3SAE`, `WPAPSK`, `OPEN`. Add `"Hidden": true` for hidden networks. Tried in order. |
| `DriverPackages` | Network driver links: `Name`, `Url`, `Type` (`zip`, `exe`, `msi`, `inf`, `cab`), optional `SilentArgs` (for `exe`), optional `MatchHardwareIds` (e.g. `VEN_8086` Intel, `VEN_10EC` Realtek, `VEN_14C3` MediaTek, `VEN_17CB` Qualcomm) |
| `InstallAllDrivers` | `true` (default) = install every driver in `drivers\` on every PC. `false` = only when Wi-Fi is broken |
| `RequireWifi` | `true` = PC fails if it has no working Wi-Fi card/driver |
| `CacheDriversWhenOnline` | `true` = when a PC is online, download all driver links into `drivers\downloads\` so later PCs work offline |

3. The Wi-Fi drivers (Intel + Realtek, from the team's WifiDrivers pack)
   are already in `drivers\` in the zip - nothing to copy. Add more driver folders (with `.inf`
   files) there if a PC model needs them. This works with **no internet**.

> Keep `config.json` only on the flash disk. Never commit Wi-Fi passwords or
> the webhook URL to this repo — it is public.

## Auto-run when the flash disk is plugged in?

Not possible on stock Windows 7/10/11: Windows blocks AutoRun from USB flash
disks (it was the main way USB viruses spread).
The inspector double-clicks `PC-Inspection.exe`.

## Google Sheet (automatic upload)

One-time setup, done by the Sheet owner:

1. Open the Google Sheet → **Extensions → Apps Script**.
2. Paste all of `AppsScript/Code.gs` (replace what is there).
3. To write to a specific tab, set `SHEET_GID` to the number after `gid=`
   in the Sheet URL. Leave it `null` to use a tab named `Inspections`.
4. **Deploy → New deployment → Web app**, Execute as **Me**, Who has access
   **Anyone**. Copy the URL.
5. Put that URL in `WebhookUrl` in `config.json` on the flash disk.

After that every PC uploads its row by itself. If a PC has no internet, the
row waits in `pending-uploads.txt` on the flash disk and is sent
automatically by the next PC that is online. The same serial number is
never saved twice.

After changing `Code.gs`, use **Deploy → Manage deployments → Edit → New
version** so the URL stays the same.

## Build / release

- Every push builds the exe on GitHub Actions and runs it on a Windows VM.
- To publish a release: push a tag `v1.2.3`, run the workflow manually with a
  version, or put `[release]` in the commit message.
- Local build: `GOOS=windows GOARCH=amd64 go build -o PC-Inspection.exe .`

## Files

- `main.go` — the exe: elevates, unpacks the embedded scripts, runs them.
- `scripts/Inspect-PC.ps1` — the inspection (specs, log, upload).
- `scripts/Setup-Network.ps1` — drivers + Wi-Fi + internet check.
- `flashdisk/` — files that go on the flash disk next to the exe.
- `build/make-bat.py` — builds `PC-Inspection.bat`, a one-file backup of the exe (scripts embedded) for PCs where antivirus blocks the exe.
