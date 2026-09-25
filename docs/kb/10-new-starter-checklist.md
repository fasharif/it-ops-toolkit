# New starter checklist

Applies to: a Windows and Microsoft 365 organisation with Active Directory (Windows Server or
Samba). Adjust the owners to match your organisation.

This is a checklist rather than a fault article. Use it for every new starter request, and
attach the completed list to the ticket.

## Symptoms (why this exists)

- A new starter arrives and cannot sign in, has no laptop, or is missing access.
- The same questions are asked for every starter because the steps live in people's heads.

## Quick checks: before you start

- [ ] The request comes from HR or the hiring manager through the service desk, not by email or
      chat alone.
- [ ] The HR feed row is complete: employee ID, given name, surname, department, and ideally
      title, manager and start date.
- [ ] The department exists in the onboarding configuration (`config/onboarding.json`).

## Fix: the checklist

### At least five working days before the start date

| Step | Owner | How |
| --- | --- | --- |
| Preview the account | Service desk | `New-ItoUser -Path feed.csv -ConfigPath onboarding.json -WhatIf`, or `linux/onboard-user.sh --dry-run` |
| Create the account | Service desk | `New-ItoUser` or `onboard-user.sh` with the delivery certificate. The account is enabled, in the department OU and groups, and must change its password at first sign-in |
| Assign licences (for example Microsoft 365) | Service desk | Group-based licensing, or the admin center |
| Extra access: shared mailboxes, shared folders, line-of-business apps | Manager requests, service desk grants | Only what the role needs |
| Prepare the laptop | Service desk | Windows Autopilot or the standard image, enrolled in device management, BitLocker on, updates installed |
| Phone, peripherals, building access | Facilities or service desk | As per role |

### On the first day

| Step | Owner | How |
| --- | --- | --- |
| Check identity | Service desk | Photo ID, or confirmation by the line manager in person |
| Hand over the initial password | Service desk | Decrypt the delivery file (`Unprotect-CmsMessage`, or `openssl cms -decrypt`) and give the password in person. Never by email |
| First sign-in and password change | New starter | The account forces a new password |
| MFA registration | New starter, with a Temporary Access Pass if used | <https://aka.ms/mysecurityinfo> |
| Windows Hello, OneDrive, Outlook, Teams | New starter, with help | Check each opens and syncs |
| Printer and VPN | Service desk | Test print; `Test-ItoNetwork -ComputerName vpn.corp.example.com -Port 443` from outside the office |
| Security basics | Service desk or security team | How to report phishing, where to get help |

### At the end of the first week

- [ ] Ask the new starter and the manager whether anything is missing.
- [ ] Remove any Temporary Access Pass that is still valid.
- [ ] Delete the delivery file once the password has been handed over.
- [ ] Close the ticket with the completed checklist attached.

## When to escalate

- The department is not in the onboarding configuration: the configuration owner must add the OU
  and groups; do not create the account by hand in the wrong OU.
- `New-ItoUser` reports a missing OU or group: fix the directory or the configuration first.
- Access requests that need approval from a data owner (finance systems, HR data).

## Prevention

- Ask HR for the feed at least five working days before the start date.
- Keep the department-to-OU and group mapping in the version-controlled configuration file, and
  review it when teams change.
- Run the feed with `-WhatIf` (or `--dry-run`) first, every time.

## Scripts that help

- [`New-ItoUser`](../../src/ItOpsToolkit/Public/New-ItoUser.ps1) and
  [`onboard-user.sh`](../../linux/onboard-user.sh): create the accounts from the HR feed.
- [`Remove-ItoUser`](../../src/ItOpsToolkit/Public/Remove-ItoUser.ps1) and
  [`offboard-user.sh`](../../linux/offboard-user.sh): the matching leaver process.
- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): checks VPN reachability
  before the starter works remotely.
