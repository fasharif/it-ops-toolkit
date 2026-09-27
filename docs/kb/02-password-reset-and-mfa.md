# Password reset and MFA re-enrolment

Applies to: Active Directory accounts (Windows Server or Samba), and Microsoft Entra ID
multifactor authentication (MFA) for Microsoft 365.

## Symptoms

- The user has forgotten their password, or it has expired while they were away.
- The user has a new phone, or lost their phone, and cannot approve MFA prompts.
- The user is asked to register security information they do not recognise.

## Quick checks

1. **Verify the caller's identity before changing anything.** Password and MFA resets are a
   common way into an organisation. Call the user back on the number held by HR or in the
   directory (never a number they give you in the call), or confirm with their line manager.
   Do not reset on the strength of an email or a chat message alone.
2. Check whether the account is simply locked out rather than forgotten:
   `Get-ADUser sara.ali -Properties LockedOut, PasswordExpired, PasswordLastSet`. If it is locked
   out, see [Account locked out](01-account-locked-out.md).
3. For MFA, check which methods are registered: Microsoft Entra admin center > Users >
   the user > Authentication methods.
4. If anything suggests the account is compromised (sign-ins from unexpected places in the Entra
   sign-in logs, MFA prompts the user did not start), stop and escalate.

## Fix

### Reset an Active Directory password

```powershell
Import-Module .\src\ItOpsToolkit\ItOpsToolkit.psd1
$password = New-ItoRandomPassword
Set-ADAccountPassword -Identity sara.ali -Reset -NewPassword $password
Set-ADUser -Identity sara.ali -ChangePasswordAtLogon $true
Unlock-ADAccount -Identity sara.ali
# Show the password once, in a dialog box, to give it to the verified user by phone or another
# separate channel:
Add-Type -AssemblyName PresentationFramework
$null = [System.Windows.MessageBox]::Show([System.Net.NetworkCredential]::new('', $password).Password, 'New password for sara.ali')
Remove-Variable -Name password
```

The dialog box keeps the password off the console on purpose. Many organisations turn on
PowerShell transcription by Group Policy, and a transcript saves everything the console shows to
a file. The password goes to a .NET method, not to a command parameter, so module logging does
not record it either. The dialog box needs a desktop session: on Server Core, run the commands
from an administrative workstation with RSAT.

Do not send the password by email or chat, and do not write it in the ticket.

On Samba, `samba-tool user setpassword sara.ali --must-change-at-next-login -H ldap://dc1 -A admin.auth`
prompts for the new password, so it never appears on the command line.

If Microsoft Entra Connect syncs the account, the new password reaches Microsoft 365 after the
next password hash sync, usually within a few minutes.

### Re-enrol MFA (Microsoft Entra ID)

1. In the Microsoft Entra admin center, open Users > the user > Authentication methods.
2. Delete the lost or old method (for example the old phone's Microsoft Authenticator entry).
3. Choose **Require re-register multifactor authentication**, or, better, add a
   **Temporary Access Pass** (the Temporary Access Pass policy must be enabled under
   Authentication methods > Policies). Give the pass to the verified user.
4. The user signs in at <https://aka.ms/mysecurityinfo> with the pass and registers the new
   method.
5. If there is any doubt about the account's safety, choose **Revoke sessions** on the user's
   page to sign them out everywhere.

The Authentication Administrator role can do this for ordinary users. Administrator accounts
need a Privileged Authentication Administrator.

## When to escalate

- You cannot verify the caller's identity.
- Signs of compromise: unfamiliar sign-in locations, MFA prompts the user did not trigger,
  mailbox rules the user did not create. Escalate to the security team.
- The account is an administrator or service account.

## Prevention

- Offer self-service password reset, with at least two registered methods per user.
- Ask users to register a second MFA method (for example the Authenticator app and a phone
  number, or a passkey) so a lost phone does not lock them out.
- Use phishing-resistant methods (passkeys or FIDO2 security keys) for administrators.

## Scripts that help

- [`New-ItoRandomPassword`](../../src/ItOpsToolkit/Public/New-ItoRandomPassword.ps1): generates
  the new password as a SecureString, without look-alike characters.
- [`Get-ItoLockoutSource`](../../src/ItOpsToolkit/Public/Get-ItoLockoutSource.ps1): checks for a
  lockout and its source before you reset.
