# Account locked out

Applies to: Active Directory (Windows Server or Samba) accounts, including accounts synced to
Microsoft Entra ID.

## Symptoms

- At sign-in, Windows shows "The referenced account is currently locked out and may not be
  logged on to."
- The user can sign in after an unlock, then is locked out again within minutes or hours.
- Mapped drives, Outlook or Teams keep asking for a password shortly before the lockout.

## Quick checks

1. Confirm the account is locked, and when:

   ```powershell
   Get-ADUser sara.ali -Properties LockedOut, AccountLockoutTime, BadLogonCount, LastBadPasswordAttempt, PasswordLastSet
   ```

   A `PasswordLastSet` of today or yesterday is the most common clue: something is still using
   the old password.

2. Find where the bad passwords come from. Every lockout is recorded on the PDC emulator as
   Security event 4740, which names the caller computer:

   ```powershell
   Import-Module .\src\ItOpsToolkit\ItOpsToolkit.psd1
   Get-ItoLockoutSource -Identity sara.ali -Hours 24
   ```

   The result lists the caller computers with the most lockouts first, and says where to look.
   Reading the PDC emulator's Security log needs membership of Event Log Readers on the domain
   controllers.

3. If the caller computer is a server (for example a mail, VPN or ADFS server), the real source is
   one of its clients. Check that server's logs, or the Microsoft Entra sign-in logs for cloud
   sign-ins.

4. On a Samba domain, check the counters with:

   ```bash
   samba-tool user show sara.ali --attributes=lockoutTime,badPwdCount,badPasswordTime -H ldap://dc1 -A admin.auth
   ```

## Fix

Remove the source first, then unlock. Unlocking without fixing the cause only restarts the clock.

On the caller computer, check in this order:

1. Phones and tablets with work mail: update the password in the mail app, or remove and re-add
   the account.
2. Saved credentials: `cmdkey /list` shows them; remove stale ones with
   `cmdkey /delete:TARGET`, or use Control Panel > Credential Manager.
3. Mapped drives with stored credentials: `net use` lists them; remove with
   `net use X: /delete` and map again.
4. Services and scheduled tasks running as the user:

   ```powershell
   Get-CimInstance Win32_Service | Where-Object StartName -like '*sara.ali*' | Select-Object Name, StartName
   Get-ScheduledTask | Where-Object { $_.Principal.UserId -like '*sara.ali*' } | Select-Object TaskName, TaskPath
   ```

5. Disconnected remote desktop sessions: `quser /server:NAME` lists them, and
   `logoff ID /server:NAME` ends one.

Then unlock the account:

```powershell
Unlock-ADAccount -Identity sara.ali
```

On Samba: `samba-tool user unlock sara.ali -H ldap://dc1 -A admin.auth`.

If the user has forgotten the password, follow
[Password reset and MFA re-enrolment](02-password-reset-and-mfa.md) instead.

## When to escalate

- Many accounts locked out at the same time, or lockouts from computers you do not recognise:
  this can be a password-spraying attack. Escalate to the security team straight away and do not
  bulk-unlock.
- Service accounts or administrator accounts: unlocking them may restart a failing process.
  Escalate to the owner of the service.
- The caller computer is a server you do not manage, or no caller computer is recorded.

## Prevention

- Use a lockout policy that slows attackers without locking users out for typing errors.
  Microsoft's security baselines use a threshold of 10 attempts and a 15-minute lockout.
- Offer self-service password reset, so users can reset and unlock without a ticket.
- Tell users, when they change their password, to update it on their phone and any other device
  that signs in as them.
- Avoid running services or scheduled tasks as named user accounts; use service accounts or
  group managed service accounts.

## Scripts that help

- [`Get-ItoLockoutSource`](../../src/ItOpsToolkit/Public/Get-ItoLockoutSource.ps1): lockout state
  and caller computers from the PDC emulator.
- [`New-ItoRandomPassword`](../../src/ItOpsToolkit/Public/New-ItoRandomPassword.ps1): a strong
  password if the account needs a reset.
