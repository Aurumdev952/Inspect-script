OFFLINE NETWORK DRIVERS
=======================
Already included (exported from an HP laptop):
  Intel-WiFi-6E      Intel Wi-Fi 6E / 7 cards (AX211, AX411, BE200...)
  Intel-WiFi-AC-AX   Intel Wi-Fi 5/6 cards (AC 9560, AX200, AX201...)
  Realtek-WiFi       Realtek Wi-Fi cards
  HP-WLAN-Extension  HP Wi-Fi add-on

Put extracted driver folders here (folders that contain .inf files).
Example:
  drivers\Intel-WiFi\Netwtw14.inf
  drivers\Realtek-LAN\rt640x64.inf

PC-Inspection.exe looks at the PC's Wi-Fi card and copies + installs only
the driver folder that matches it (found by hardware ID inside the .inf
files). Works with NO internet. Any layout is fine - e.g. unzip
WifiDrivers.zip into this folder. If the Wi-Fi already works, no driver is
copied or installed at all.
