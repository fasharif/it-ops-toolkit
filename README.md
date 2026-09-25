# it-ops-toolkit

Tested help-desk automation for Windows and Linux: Active Directory onboarding, offboarding and
lockout tracing, computer health reports, and layered network troubleshooting, with a knowledge
base to match.

[![CI](https://github.com/fasharif/it-ops-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/fasharif/it-ops-toolkit/actions/workflows/ci.yml)

## Sample output

Onboarding the example HR feed ([examples/new-starters.csv](examples/new-starters.csv)) into a
real Samba Active Directory domain controller, from the integration test environment. Two people
called Sara Ali get different account names, accents and apostrophes are handled, and each
initial password goes only into an encrypted file:

```text
$ linux/onboard-user.sh --csv examples/new-starters.csv --config config/onboarding.example.json --deliver-dir /srv/it-ops/deliver --deliver-cert /srv/it-ops/delivery.pem
Row  Account               Status   Message
1    sara.ali              Created  Created sara.ali@corp.itops.test in OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test.
2    sara.ali2             Created  Created sara.ali2@corp.itops.test in OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test.
3    jose.garcialopez      Created  Created jose.garcialopez@corp.itops.test in OU=IT,OU=Staff,DC=corp,DC=itops,DC=test.
4    liam.obrien           Created  Created liam.obrien@corp.itops.test in OU=Human Resources,OU=Staff,DC=corp,DC=itops,DC=test.
5    aisha.almansoori      Created  Created aisha.almansoori@corp.itops.test in OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test.

Onboarding summary: 5 created.
```

A network check on Windows 11 with Windows PowerShell 5.1, ending in a plain-language diagnosis:

```text
PS> Test-ItoNetwork | Select-Object -ExpandProperty Layers

Layer            Status Detail
-----            ------ ------
IP configuration Pass   Wi-Fi: 192.168.50.112
Default gateway  Pass   192.168.50.1 answers ping (2 ms).
DNS servers      Pass   DNS servers: 1.1.1.1, 1.0.0.1, fec0:0:0:ffff::1%1, fec0:0:0:ffff::2%1, fec0:0:0:ffff::3%1.
DNS resolution   Pass   www.microsoft.com resolves to 23.35.101.225.
TCP port         Pass   Connected to 23.35.101.225 on port 443.
HTTPS            Pass   TLS handshake completed; the server answered with HTTP status 200.
Route trace      Info   Reached 23.35.101.225 in 12 hop(s).

PS> (Test-ItoNetwork -ComputerName fileserver.corp.itops.test -Port 445 -SkipTrace).Diagnosis
DNS works, but the name 'fileserver.corp.itops.test' does not resolve. Check the spelling. For an internal name, check that the record exists and that you are on the office network or VPN (split DNS).
```

More real output is in [docs/samples](docs/samples): offboarding against Samba, the Linux health
report and Born2beRoot summary, and a Windows health report as
[HTML](docs/samples/windows-health-report.html) and [JSON](docs/samples/windows-health-report.json)
(computer name and three third-party service names removed before publishing).

## The problem it solves

First- and second-line support spends much of its time on the same few jobs: creating accounts
for new starters, closing them for leavers, finding out why a PC is slow or an account keeps
locking, and working out whether "the internet is down" is the laptop, the Wi-Fi, DNS or the
server. Done by hand, these jobs are slow and inconsistent: accounts land in the wrong OU,
leavers keep group memberships, passwords get pasted into tickets, and network faults are
guessed at instead of isolated.

This toolkit makes those jobs repeatable. The scripts validate their input, preview changes
(`-WhatIf`, `--dry-run`), can be run twice safely, never print or log passwords, and return
structured results that fit into a ticket. The knowledge base and method explain the manual side
of the same tickets.

## Features

**PowerShell module `ItOpsToolkit`** (Windows PowerShell 5.1 and PowerShell 7; comment-based help,
parameter validation and `-WhatIf`/`-Confirm` on everything that changes state):

- `New-ItoUser` creates Active Directory accounts from an HR feed CSV: department-to-OU and group
  mapping from JSON, unique `sAMAccountName` generation (first.last or flast, at most 20
  characters, numbered on collision), a strong random initial password delivered only as a
  CMS-encrypted file or a `SecureString`, "must change password at next logon", and a CSV summary.
  Rows already onboarded (same employee ID) are skipped.
- `Remove-ItoUser` offboards a leaver: exports group memberships for audit first, disables the
  account, records the ticket number in the description, removes groups and moves the account to
  the disabled users OU. Each step checks the current state, so a second run changes nothing.
- `Get-ItoLockoutSource` shows whether an account is locked out and which computers caused it,
  from event 4740 on the PDC emulator.
- `Get-ItoHealthReport` grades disk space, memory, uptime, pending reboot, stopped automatic
  services, recent critical events, the last update installed and BitLocker status against clear
  thresholds, and writes HTML and JSON.
- `Test-ItoNetwork` checks IP configuration, gateway, DNS servers, DNS resolution, TCP port,
  HTTPS and a route trace, and names the lowest failing layer in plain language.
- `New-ItoRandomPassword` generates passwords from the operating system's cryptographic random
  number generator, without look-alike characters.

**Bash scripts for Linux** (`linux/`):

- `onboard-user.sh` and `offboard-user.sh`: the same onboarding and offboarding against Samba
  Active Directory with `samba-tool` and LDAP, using the same JSON configuration. Accounts are
  created with one atomic `ldbadd`; passwords never appear on a command line.
- `health-report.sh`: disk, memory, uptime, pending reboot, failed systemd units, critical journal
  entries, last package update and root filesystem encryption, as text, JSON or HTML, with
  Nagios-style exit codes.
- `net-check.sh`: the layered network check and diagnosis on Linux.
- `monitoring.sh`: the Born2beRoot system summary (architecture and kernel, physical and virtual
  CPUs, memory and disk use, CPU load, last boot, LVM, TCP connections, users, IP and MAC, sudo
  command count), rebuilt from scratch to read `/proc` directly and broadcast with `wall`.

**Documentation:** ten [knowledge base articles](docs/kb/README.md) (lockouts, password and MFA
resets, Wi-Fi, VPN, printers, disk space, slow PCs, Outlook, DNS, new starters) and a
[troubleshooting method](docs/method.md) with an ITIL-style priority matrix and a ticket template.

## Architecture

```mermaid
flowchart LR
    feed[HR feed CSV] --> newuser
    config[onboarding.json<br/>departments, OUs, groups] --> newuser & onboard & removeuser & offboard

    subgraph Windows [Windows: PowerShell module ItOpsToolkit]
        newuser[New-ItoUser]
        removeuser[Remove-ItoUser]
        lockout[Get-ItoLockoutSource]
        health[Get-ItoHealthReport]
        net[Test-ItoNetwork]
    end

    subgraph Linux [Linux: Bash scripts]
        onboard[onboard-user.sh]
        offboard[offboard-user.sh]
        lhealth[health-report.sh]
        lnet[net-check.sh]
        mon[monitoring.sh]
    end

    feed --> onboard
    newuser & removeuser & lockout -->|ActiveDirectory module, ADWS| adds[(Active Directory<br/>Domain Services)]
    onboard & offboard -->|samba-tool, ldbadd, ldbmodify over LDAP| samba[(Samba AD DC)]
    newuser & onboard --> cms[Encrypted password files<br/>account.cms]
    newuser & onboard --> summary[Summary CSV, no passwords]
    removeuser & offboard --> audit[Group membership audit CSV]
    health & lhealth --> reports[HTML and JSON reports]
    net & lnet --> diag[Layer results and diagnosis]
```

The PowerShell side and the Bash side are independent implementations of the same rules. They
share the JSON configuration and a fixture file of account-name test cases
([tests/fixtures/account-names.csv](tests/fixtures/account-names.csv)) that both test suites run.

## Tech stack and why

| Part | Choice | Why |
| --- | --- | --- |
| Windows automation | PowerShell module, Windows PowerShell 5.1 and PowerShell 7 | What Windows help desks already run; the `ActiveDirectory` module is the supported way to manage AD |
| Linux automation | Bash, `samba-tool`, ldb tools, `jq` | Available on any Samba administration host; no extra runtime |
| CSV parsing on Linux | Python 3 standard library (`linux/lib/hrfeed.py`) | Bash has no reliable CSV parser; Python is already required by `samba-tool` |
| Password delivery | CMS encryption (`Protect-CmsMessage`, `openssl cms`) | Standard format both platforms read; only the certificate holder can decrypt |
| Network checks | .NET `System.Net` classes | Same code on Windows and Linux, and testable without Windows-only cmdlets |
| Tests | Pester 5, bats-core, a Samba AD DC in Docker | Unit tests with mocks and fakes, plus a real directory for the Bash scripts |
| Linting | PSScriptAnalyzer, shellcheck, ruff, mypy `--strict`, actionlint | One linter per language, all clean |

## Quick start

On Windows (PowerShell 5.1 or 7):

```powershell
git clone https://github.com/fasharif/it-ops-toolkit.git
cd it-ops-toolkit
Import-Module .\src\ItOpsToolkit\ItOpsToolkit.psd1
Test-ItoNetwork
Get-ItoHealthReport -OutputDirectory $env:TEMP
```

On Linux: `linux/net-check.sh` and `linux/health-report.sh` need no set-up. For onboarding, copy
`config/onboarding.example.json` to `config/onboarding.json`, edit it for your directory, and
preview first:

```powershell
New-ItoUser -Path .\examples\new-starters.csv -ConfigPath .\config\onboarding.json -WhatIf
```

```bash
linux/onboard-user.sh --csv examples/new-starters.csv --config config/onboarding.json \
    --url ldap://dc1.corp.example.com --auth-file ~/.config/it-ops/admin.auth --dry-run
```

Every command has built-in help: `Get-Help New-ItoUser -Full`, `linux/onboard-user.sh --help`.

## Configuration

**Onboarding and offboarding** use one JSON file ([example](config/onboarding.example.json),
[schema](config/onboarding.schema.json)):

| Setting | Meaning |
| --- | --- |
| `upnSuffix` | Suffix for sign-in names and mail addresses, for example `corp.example.com` |
| `samAccountNameFormat` | `first.last` (default) or `flast` |
| `disabledOu` | Distinguished name of the OU that leavers are moved to |
| `defaultGroups` | Groups every new starter joins |
| `departments` | One entry per HR department name (matched without regard to case), each with an `ou` and `groups` |

**HR feed columns:** `EmployeeId`, `GivenName`, `Surname`, `Department` (required), `Title`,
`Manager` (the manager's sAMAccountName) and `StartDate` (yyyy-MM-dd) (optional).

**Password delivery certificate.** `New-ItoUser` needs a certificate with the Document Encryption
enhanced key usage. On Windows:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=Service Desk Delivery' -Type DocumentEncryptionCert -CertStoreLocation Cert:\CurrentUser\My
Export-Certificate -Cert $cert -FilePath .\servicedesk.cer
```

The holder of the private key reads a delivery file with
`Unprotect-CmsMessage -Path .\sara.ali.cms`. `onboard-user.sh` takes a PEM certificate
(`--deliver-cert`); the service desk decrypts with
`openssl cms -decrypt -binary -inform PEM -in sara.ali.cms -inkey key.pem -recip cert.pem`.

**Samba credentials** for the Bash scripts are read from a Samba authentication file (lines
`username=`, `password=`, `domain=`), mode 600, given with `--auth-file` or `ITO_AUTH_FILE`. The
domain controller is `--url` or `ITO_LDAP_URL`.

**Health thresholds.** `Get-ItoHealthReport -ThresholdPath` takes a JSON file
([example](config/health-thresholds.example.json)); `health-report.sh` reads environment variables
(`ITO_DISK_FREE_WARN=20`, `ITO_MEMORY_USED_WARN=85` and so on; see `--help`). The defaults match:

| Check | Warning | Critical |
| --- | --- | --- |
| Free disk space | below 20% | below 10% |
| Memory in use | 85% | 95% |
| Uptime | 14 days | 30 days |
| Stopped automatic services / failed units | 1 | 5 |
| Critical events / journal entries (24 h) | 1 | 5 |
| Days since the last update | 35 | 60 |

## Running the tests

Everything runs in containers, so Docker is the only requirement.

| Command | What it runs |
| --- | --- |
| `scripts/test-powershell.sh` | PSScriptAnalyzer and the Pester suite in `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` |
| `scripts/test-bash.sh` | shellcheck, then the bats unit tests in the Debian 13 test image |
| `scripts/lint-python.sh` | ruff and `mypy --strict` for `linux/lib/hrfeed.py` |
| `tests/integration/run.sh` | Starts a Samba AD DC and runs onboarding and offboarding against it, then removes it |
| `powershell -File scripts\Invoke-Tests.ps1 -Stage Test` | The Pester suite in Windows PowerShell 5.1 |

Results of the last full run, on 2026-09-26, from a fresh clone of the branch on a Windows 11
development machine with Docker Desktop (Linux containers). These are pass/fail results only; no
timings are published.

| Check | Environment | Command | Result |
| --- | --- | --- | --- |
| PSScriptAnalyzer 1.25.0 | PowerShell 7.5.0, `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` | `scripts/test-powershell.sh` | No findings |
| Pester 5.9.1 | Same container | `scripts/test-powershell.sh` | 177 passed, 0 failed; 86.5% line coverage of `src/ItOpsToolkit` |
| Pester 5.9.1 | Windows PowerShell 5.1.26100, Windows 11, .NET Framework 4.8 | `powershell -File scripts\Invoke-Tests.ps1 -Stage Test` | 175 passed, 0 failed, 2 skipped (PowerShell 7-only tests); 86.5% line coverage |
| shellcheck 0.11.0 | `koalaman/shellcheck:v0.11.0` | `scripts/test-bash.sh` | No findings |
| bats-core 1.14.0 | Debian 13 test image (`tests/docker/Dockerfile`, target `test`) | `scripts/test-bash.sh` | 109 passed, 0 failed |
| ruff 0.16.9, mypy 2.3.1 `--strict` | `python:3.13-slim` | `scripts/lint-python.sh` | No findings |
| Samba AD integration | Samba 4.22.11 AD DC and a client, Debian 13 containers | `tests/integration/run.sh` | 13 passed, 0 failed |
| actionlint 1.7.12 | `rhysd/actionlint:1.7.12` | `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12` | No findings |

CI (`.github/workflows/ci.yml`) runs the same commands on every push to `main` and every pull
request, plus the Pester suite on a Windows runner under Windows PowerShell 5.1 and PowerShell 7,
and actionlint.

## Folder structure

```text
.
├── config/                     onboarding.example.json, its JSON schema, health threshold example
├── docs/
│   ├── kb/                     ten help-desk articles
│   ├── samples/                real output from the tools
│   ├── decisions.md            design decisions
│   └── method.md               troubleshooting method, priority matrix, ticket template
├── examples/new-starters.csv   example HR feed
├── linux/                      onboard-user.sh, offboard-user.sh, health-report.sh, net-check.sh, monitoring.sh
│   └── lib/                    shared Bash libraries, config-check.jq, hrfeed.py
├── scripts/                    test runners (PowerShell, Bash, Python)
├── src/ItOpsToolkit/           the PowerShell module (Public/ and Private/ functions)
└── tests/
    ├── bats/                   bats unit tests and fake Samba tools
    ├── docker/Dockerfile       test images: tools, test (bats), dc (Samba AD)
    ├── fixtures/               account-name cases shared by Pester and bats
    ├── integration/            Samba AD integration tests (compose.yaml, run.sh)
    └── powershell/             Pester tests and ActiveDirectory stubs
```

## Design decisions

The main choices, with their reasons and trade-offs, are in [docs/decisions.md](docs/decisions.md).
In short: one configuration for both platforms; Pester mocks for the AD module (Samba has no
ADWS) and a real Samba DC for the Bash scripts; passwords only ever leave the tools encrypted;
Samba accounts created in one atomic `ldbadd`; `.NET` networking so `Test-ItoNetwork` runs
everywhere; idempotent onboarding and offboarding; Windows PowerShell 5.1 compatibility tested
rather than assumed.

## Limitations and roadmap

**Not run yet, and how to run it:**

- **`New-ItoUser`, `Remove-ItoUser` and `Get-ItoLockoutSource` against a real Windows Server
  domain.** They are tested only with Pester mocks: the `ActiveDirectory` module needs Active
  Directory Web Services, which the Samba test DC does not provide. To run them, use a test
  domain with RSAT installed on a domain-joined machine: create the OUs and groups from
  `config/onboarding.example.json`, create a delivery certificate as shown above, then run
  `New-ItoUser -WhatIf`, `New-ItoUser`, `Remove-ItoUser -WhatIf` and `Remove-ItoUser`, and check
  the results in Active Directory Users and Computers. `Get-ItoLockoutSource` also needs Event
  Log Readers rights on the domain controllers.
- **The GitHub Actions workflow.** It passes actionlint, and every job runs the same scripts that
  were run locally, but it has not run on GitHub yet because the repository has not been pushed.
- **Linux checks that need systemd, LVM or LUKS.** In a container there is no systemd, so
  `health-report.sh` reports failed units, the journal and disk encryption as Unknown, and
  `monitoring.sh` shows no LVM. Those paths are covered by bats tests with fake commands. To run
  them for real, run the scripts on a systemd-based VM (for example a Born2beRoot Debian VM with
  LVM on LUKS) as root.
- **The BitLocker check as an administrator.** The Windows sample above ran unelevated, so
  BitLocker shows Unknown ("Access denied"). Run `Get-ItoHealthReport` from an elevated prompt
  on a Pro or Enterprise edition to see the protection status.

**Limitations:**

- `Get-ItoHealthReport` checks the computer it runs on; for a remote PC, run it there (for
  example with `Invoke-Command`).
- The route trace is IPv4 only. Inside Docker Desktop, the trace is not meaningful, because
  Docker's network layer answers ICMP itself.
- The Bash directory scripts authenticate with an authentication file; Kerberos ticket use is
  not implemented.
- The Samba test DC stores ACLs in a TDB file so it can run unprivileged; it is a test fixture,
  not a production build.

**Roadmap:** run the AD functions in a Windows Server 2025 lab domain and record the results;
add Kerberos authentication to the Bash scripts; move to Pester 6; publish the module to the
PowerShell Gallery.

## A note for IT support roles

For IT support and service desk roles, a certification such as CompTIA A+ or Microsoft MD-102
(Endpoint Administrator) matters as much as this repository. The repository shows practical,
tested work; it does not replace the structured coverage of hardware, operating systems and
endpoint management that those certifications examine.

## Licence

[MIT](LICENSE). Copyright (c) 2026 Farah Sharif.
