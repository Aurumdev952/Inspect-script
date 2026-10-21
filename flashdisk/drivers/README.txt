OFFLINE NETWORK DRIVERS
=======================
Put extracted driver folders here (folders that contain .inf files).
Example:
  drivers\Intel-WiFi\Netwtw14.inf
  drivers\Realtek-LAN\rt640x64.inf

PC-Inspection.exe installs every .inf in this folder (and sub-folders)
when a PC has no working Wi-Fi card. This works with NO internet.

drivers\downloads\ is filled automatically: when a PC is online, every
"DriverPackages" link in config.json is downloaded here once, so the next
PC without Wi-Fi drivers can be fixed offline.
