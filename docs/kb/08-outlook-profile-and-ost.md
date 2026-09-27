# Outlook profile and OST problems

Applies to: classic Outlook for Windows (Microsoft 365 Apps, Outlook 2016 to 2024) with Exchange
Online or Exchange Server in cached mode. The new Outlook for Windows stores data differently;
most of the OST steps below do not apply to it.

## Symptoms

- Outlook hangs on "Loading profile" or "Processing".
- New mail does not arrive in Outlook but does arrive in Outlook on the web.
- "The file ... .ost cannot be accessed", or "Outlook data file cannot be accessed".
- Search returns nothing or only old results.
- Outlook keeps asking for the password.
- The OST file has grown very large and the disk is filling up.

## Quick checks

1. Does Outlook on the web (<https://outlook.office.com>) show the mail? If yes, the mailbox is
   fine and the problem is on the PC.
2. Look at the status bar: "Working offline", "Disconnected" or "Trying to connect".
3. Hold Ctrl, right-click the Outlook icon in the notification area, and open
   **Connection Status** (connection state) or **Test Email AutoConfiguration** (Autodiscover).
4. Start Outlook without add-ins: `outlook.exe /safe`. If it works, an add-in is the cause
   (File > Options > Add-ins > COM Add-ins).
5. Check the OST size and the free disk space. OST files live in
   `%LOCALAPPDATA%\Microsoft\Outlook`. By default Outlook stops an OST from growing past 50 GB.
6. Check the network path: `Test-ItoNetwork -ComputerName outlook.office365.com`.

## Fix

From least to most disruptive:

1. Restart Outlook, then the PC.
2. Disable the add-in found in step 4 of the checks.
3. Reset the navigation pane if Outlook crashes at start-up: `outlook.exe /resetnavpane`.
4. Repair Office: Settings > Apps > Installed apps > Microsoft 365 > Modify > **Quick Repair**,
   then **Online Repair** if that does not help.
5. Rebuild the OST. Close Outlook, rename the `.ost` file in `%LOCALAPPDATA%\Microsoft\Outlook`
   (for example to `.ost.old`), and start Outlook; it downloads the mailbox again. First check
   the Outbox and Drafts: items that never reached the server exist only in the old file.
   The Inbox Repair Tool (`SCANPST.EXE`) is for PST files, not OST files.
6. Create a new mail profile: Control Panel > Mail (Microsoft Outlook) > Show Profiles > Add,
   set up the account, and choose **Always use this profile**. Remove the old profile once the
   new one works.
7. Keep the OST smaller: File > Account Settings > Account Settings > the account > Change >
   **Download email for the past** (for example 1 year).
8. Repeated password prompts: in Credential Manager > Windows Credentials, remove entries named
   `MicrosoftOffice16_Data:...`, then restart Outlook and sign in again.
9. Search not working: File > Options > Search > Indexing Options > Advanced > **Rebuild**.
   Rebuilding takes a while on large mailboxes.

## When to escalate

- Outlook on the web also fails, or many users are affected: check the Microsoft 365 service
  health dashboard and escalate to the messaging team.
- The mailbox is full (quota warnings): the Exchange administrator needs to enable an archive or
  raise the quota.
- Data is missing from the mailbox, not just from the OST.
- A PST file needs recovery or is stored on a network share (not supported by Microsoft).

## Prevention

- Keep Office on a supported update channel.
- Set a sensible cached mode period through policy, so OST files stay small.
- Move PST files into the mailbox or the archive.

## Scripts that help

- [`Get-ItoHealthReport`](../../src/ItOpsToolkit/Public/Get-ItoHealthReport.ps1): free disk space
  for the OST, and critical events.
- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): the path to Exchange
  Online, including the HTTPS handshake.
