# Printer offline and print spooler problems

Applies to: Windows 10 and 11 clients printing directly or through a Windows print server, and
Linux with CUPS.

## Symptoms

- The printer shows as "Offline" in Settings, although it is switched on.
- Jobs sit in the queue and nothing prints, or the queue cannot be cleared.
- "The print spooler service is not running", or print dialogs hang.
- Error 0x0000011b when connecting to a shared printer.
- Error 0x00000709 when setting the default printer.

## Quick checks

1. Look at the printer itself: power, paper, toner, and any error on its display.
2. Is it one user or everyone? If everyone, check the printer and the print server first.
3. Can the laptop reach the printer? Use the port the printer listens on: 9100 for raw printing,
   631 for IPP, or 445 for a queue shared from a print server.

   ```powershell
   Test-ItoNetwork -ComputerName 10.1.2.50 -Port 9100
   ```

4. Check the queue and the port the printer uses:

   ```powershell
   Get-Printer | Select-Object Name, PrinterStatus, PortName, DriverName
   Get-PrintJob -PrinterName 'Finance-MFP'
   Get-Service -Name Spooler
   ```

   A port name starting with `WSD` means the printer was added through Web Services for Devices,
   which often shows printers as offline after they change address.
5. Run `Get-ItoHealthReport`: a stopped Print Spooler appears under "Automatic services" as a
   Warning, with its exit code, whether it crashed or someone stopped it. The spooler is on the
   report's essential services list, which counts it even after a clean stop (exit code 0). This
   applies when the spooler is set to start automatically; a spooler disabled on purpose, as some
   organisations do on computers that never print, is not reported.

## Fix

1. In the print queue window, open the Printer menu and clear **Use Printer Offline**.
2. Clear a stuck queue (from an elevated PowerShell; this deletes every waiting job, so tell the
   users first):

   ```powershell
   Stop-Service -Name Spooler -Force
   Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force
   Start-Service -Name Spooler
   ```

3. Replace a WSD port with a Standard TCP/IP port pointing at the printer's fixed address:

   ```powershell
   Add-PrinterPort -Name 'IP_10.1.2.50' -PrinterHostAddress '10.1.2.50'
   Set-Printer -Name 'Finance-MFP' -PortName 'IP_10.1.2.50'
   ```

4. Error 0x00000709: turn off Settings > Bluetooth and devices > Printers and scanners >
   **Let Windows manage my default printer**, then set the default again.
5. Error 0x0000011b: this follows the 2021 security hardening of printing over RPC
   (CVE-2021-1678). Make sure the print server and the client both have current Windows updates.
   Do not turn the protection off.
6. If adding a shared printer asks for administrator credentials: since the August 2021 security
   updates, only administrators can install printer drivers from a print server by default.
   Deploy the driver through Intune or Group Policy rather than weakening the policy.
7. Remove and re-add the printer, or reinstall the driver from the manufacturer.

On Linux with CUPS:

```bash
lpstat -p -d                 # printers, their state and the default
cupsenable Finance-MFP       # re-enable a printer that CUPS stopped after an error
cancel -a Finance-MFP        # clear its queue
sudo systemctl restart cups
```

The CUPS web interface at <http://localhost:631> shows the error that stopped the printer.

## When to escalate

- Everyone on a print server is affected: escalate to the server team.
- Hardware errors on the printer (fuser, scanner or repeated jam codes): log a call with the
  supplier.
- Drivers need packaging or approval for deployment.

## Prevention

- Give printers DHCP reservations or fixed addresses, and use Standard TCP/IP ports, not WSD.
- Deploy printers and drivers centrally (Group Policy, Intune or Universal Print).
- Watch for a stopped spooler with the health report, for example from a scheduled task that
  runs it daily and collects the JSON files.

## Scripts that help

- [`Get-ItoHealthReport`](../../src/ItOpsToolkit/Public/Get-ItoHealthReport.ps1): flags a stopped
  Print Spooler that is set to start automatically, however it stopped.
- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): checks the path to the
  printer on its port.
- [`health-report.sh`](../../linux/health-report.sh): lists failed systemd units, including
  `cups.service`.
- [`net-check.sh`](../../linux/net-check.sh): `linux/net-check.sh --port 631 --no-trace printer.corp.example.com`.
