# Disk full

Applies to: Windows 10 and 11 clients, and Linux servers and workstations.

## Symptoms

- "Low disk space" notifications, or a red bar under the drive in File Explorer.
- Windows updates fail with 0x80070070 ("There is not enough space on the disk").
- Applications crash or cannot save; Outlook stops downloading mail.
- On Linux: "No space left on device", services failing to start, logs no longer written.

## Quick checks

1. How full is it, and which drive?

   ```powershell
   Get-ItoHealthReport | Select-Object -ExpandProperty Checks | Where-Object Category -eq Storage
   ```

   The report grades each fixed drive: warning below 20% free, critical below 10%.
   On Linux: `linux/health-report.sh`, or `df -h`.
2. Where is the space going? Settings > System > Storage shows the main categories. To list the
   largest folders under the user profiles:

   ```powershell
   Get-ChildItem C:\Users -Directory | ForEach-Object {
       $bytes = (Get-ChildItem $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
       [pscustomobject]@{ Folder = $_.FullName; GB = [math]::Round($bytes / 1GB, 1) }
   } | Sort-Object GB -Descending
   ```

   On Linux: `sudo du -xh --max-depth=1 / | sort -h | tail`.
3. Usual suspects: Downloads, the Recycle Bin, large Outlook data files
   (`%LOCALAPPDATA%\Microsoft\Outlook`), OneDrive files kept on the device, old Windows update
   files, and on Linux the journal, package caches and old kernels.

## Fix

On Windows, from least to most disruptive:

1. Empty the Recycle Bin and clear Downloads with the user's agreement.
2. Settings > System > Storage > Cleanup recommendations, or turn on Storage Sense.
3. Disk Clean-up with system files: run `cleanmgr`, choose **Clean up system files**, and tick
   Windows Update Cleanup.
4. Clean up the component store (elevated): `Dism.exe /Online /Cleanup-Image /StartComponentCleanup`.
5. OneDrive: right-click large folders > **Free up space** to keep them online only.
6. Outlook: reduce File > Account Settings > the account > **Download email for the past** so
   the OST file shrinks (see [Outlook profile and OST problems](08-outlook-profile-and-ost.md)).
7. Only if the device never hibernates: `powercfg /hibernate off` removes `hiberfil.sys`. This
   also turns off Fast Startup.

On Linux:

```bash
sudo journalctl --vacuum-size=200M         # shrink the systemd journal
sudo apt-get clean                         # Debian/Ubuntu package cache (dnf clean all on RHEL)
sudo apt-get autoremove --purge            # old kernels and unused packages
sudo lsof +L1                              # deleted files still held open by a process
```

Space held by a deleted but open file comes back only when the process restarts. Restart that
service rather than deleting more files.

## When to escalate

- Server volumes, databases or log volumes: growth needs a planned change, not deletions.
- A disk that fills again within days: find the process that writes the data before cleaning.
- The disk is simply too small for the user's work: request a larger disk or a replacement device.

## Prevention

- Turn on Storage Sense through Intune or Group Policy.
- Monitor free space with the health report thresholds (20% warning, 10% critical by default).
- On Linux, configure log rotation and a journal size limit (`SystemMaxUse=` in
  `/etc/systemd/journald.conf`).

## Scripts that help

- [`Get-ItoHealthReport`](../../src/ItOpsToolkit/Public/Get-ItoHealthReport.ps1): free space per
  drive against thresholds, as HTML and JSON.
- [`health-report.sh`](../../linux/health-report.sh): the same for each Linux filesystem.
- [`monitoring.sh`](../../linux/monitoring.sh): one-line disk use summary.
