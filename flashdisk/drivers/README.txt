OFFLINE NETWORK DRIVERS
=======================
Already included (exported from an HP laptop):
  Intel-WiFi-6E      Intel Wi-Fi 6E / 7 cards (AX211, AX411, BE200...)
  Intel-WiFi-AC-AX   Intel Wi-Fi 5/6 cards (AC 9560, AX200, AX201...)
  Realtek-WiFi       Realtek Wi-Fi cards
  Realtek-Ethernet   Realtek PCIe Gigabit Ethernet (cable)
  HP-WLAN-Extension  HP Wi-Fi add-on

Put extracted driver folders here (folders that contain .inf files).
Example:
  drivers\Intel-WiFi\Netwtw14.inf
  drivers\Realtek-LAN\rt640x64.inf

PC-Inspection.exe installs every .inf in this folder (and sub-folders)
when a PC has no working Wi-Fi card. This works with NO internet.

drivers\downloads\ is filled automatically: when a PC is online, every
"DriverPackages" link in config.json is downloaded here once, so the next
PC without Wi-Fi drivers can be fixed offline.
