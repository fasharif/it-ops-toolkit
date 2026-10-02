# Slow PC triage

Applies to: Windows 10 and 11 clients, with notes for Linux.

## Symptoms

- Slow start-up or sign-in.
- Applications freeze or take a long time to open.
- The fan runs constantly, or the laptop is hot.
- "It has been slow since last week."

## Quick checks

Start by narrowing the problem down; "slow" is not yet a diagnosis.

1. Ask: since when? After what change (update, new software, new location)? Everything, or one
   application? Always, or at certain times?
2. Take a health snapshot:

   ```powershell
   Get-ItoHealthReport -OutputDirectory $env:TEMP
   ```

   Memory use, free disk space, uptime, a pending reboot and recent critical events account for
   most slow PCs. Keep the HTML file for the ticket.
3. Open Task Manager (Ctrl+Shift+Esc), sort the Processes tab by CPU, then Memory, then Disk.
   Note the top consumers. The Startup apps page shows programs that slow down sign-in.
4. Check for crashes and hardware errors: Reliability Monitor (`perfmon /rel`) shows application
   failures by day. In Event Viewer, WHEA-Logger events point at hardware faults.
5. Check the disk's health (elevated):

   ```powershell
   Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus
   Get-PhysicalDisk | Get-StorageReliabilityCounter | Select-Object DeviceId, Wear, ReadErrorsTotal, Temperature
   ```

6. On a laptop, check the power mode and that it is not on battery saver.

On Linux: `top` (or `htop`), `free -h`, `vmstat 1 5` (high `wa` means waiting for disk),
`iostat -xz 1 5` from the sysstat package, and `systemd-analyze blame` for slow boots.

## Fix

1. Restart. An uptime of weeks is common and the health report flags it (warning at 14 days).
   Note that "Shut down" with Fast Startup does not reset uptime; use Restart.
2. Install pending updates, and restart if a reboot is pending.
3. Close or uninstall what is using the resources; disable unnecessary startup apps.
4. Free disk space if the system drive is nearly full ([Disk full](06-disk-full.md)).
5. Run a malware scan: `Start-MpScan -ScanType QuickScan` (Microsoft Defender).
6. Repair system files (elevated), in this order:

   ```powershell
   DISM /Online /Cleanup-Image /RestoreHealth
   sfc /scannow
   ```

7. Update drivers and firmware (BIOS/UEFI) from the manufacturer's support tool.

## When to escalate

- Signs of failing hardware: disk HealthStatus not Healthy, rising read errors, WHEA-Logger
  events, or repeated blue screens.
- Many PCs became slow at the same time, for example after an update or a new security agent:
  escalate as a possible problem with a change.
- Unknown processes using a lot of CPU or network: treat as a possible security incident.
- The device simply does not meet the user's needs: raise a hardware request.

## Prevention

- Enforce restarts for updates, and keep an eye on uptime with the health report.
- Standardise on SSDs and enough memory for the role.
- Review startup apps and installed software in the device build.

## Scripts that help

- [`Get-ItoHealthReport`](../../src/ItOpsToolkit/Public/Get-ItoHealthReport.ps1): memory, disk,
  uptime, pending reboot, stopped services and critical events in one report.
- [`health-report.sh`](../../linux/health-report.sh) and
  [`monitoring.sh`](../../linux/monitoring.sh): the Linux equivalents; monitoring.sh gives a
  one-screen snapshot of CPU load, memory and disk.
