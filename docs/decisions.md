# Design decisions

Short records of the choices that shaped this repository: the context, the decision and its
consequences.

## 1. One configuration file for Windows and Linux onboarding

**Context.** The same organisation may onboard people with the PowerShell module on Windows and
with the Bash scripts against Samba. Two department mappings would drift apart.

**Decision.** `New-ItoUser`, `Remove-ItoUser`, `onboard-user.sh` and `offboard-user.sh` read the
same JSON file (`config/onboarding.example.json`, described by `config/onboarding.schema.json`).
Both sides validate it with the same rules and reject unknown settings, so a typo such as
`departmens` fails loudly instead of being ignored.

**Consequences.** The Bash scripts need `jq`. Validation logic exists twice (PowerShell and a jq
program), so tests on both sides check the same error cases.

## 2. Mocked Active Directory for the PowerShell module, a real Samba DC for the Bash scripts

**Context.** The spec asks for an integration test against a Samba AD domain controller in
Docker. The PowerShell `ActiveDirectory` module talks to Active Directory Web Services (ADWS) on
TCP 9389, which Samba does not implement, so `New-ADUser` cannot run against Samba at all.

**Decision.** The PowerShell functions are tested with Pester mocks. Because Pester can only mock
commands that exist, `tests/powershell/stubs/ActiveDirectoryStub.psm1` defines stand-ins with the
same parameter names as the real cmdlets. The Bash scripts are tested twice: with fake Samba
tools on `PATH` (bats unit tests) and against a real Samba DC (`tests/integration`).

**Consequences.** The PowerShell AD functions have not yet run against a real Windows domain
controller; the README says so and gives the steps. The account name rules are shared and tested
against one fixture file (`tests/fixtures/account-names.csv`) from both Pester and bats, so the
two implementations cannot drift unnoticed.

## 3. Initial passwords only leave the tool encrypted

**Context.** A new account needs an initial password that reaches the right person. Writing it to
a CSV, a log or the console is how passwords end up in tickets and chat.

**Decision.** Passwords are generated from the operating system's cryptographic random number
generator, set together with "must change at next logon", and delivered only as CMS
(PKCS #7) encrypted files for a service desk certificate: `Protect-CmsMessage` on Windows,
`openssl cms` on Linux. The PowerShell result object also carries the password as a
`SecureString`. Tests check that the password never appears in output streams, transcripts,
summaries, command lines or tool errors.

**Consequences.** The service desk needs a certificate with the Document Encryption enhanced key
usage and its private key to read the files. Both tools produce standard CMS, so a file written
by PowerShell can be decrypted with openssl and the other way round; a Pester test checks this.

## 4. Create Samba accounts with one ldbadd, with the password on standard input

**Context.** `samba-tool user create NAME PASSWORD` puts the password in the process list, and a
create-then-set-password sequence can leave a half-created account if the second step fails.

**Decision.** `onboard-user.sh` sends one LDIF record to `ldbadd` through a pipe. It holds all the
attributes, `unicodePwd` (the quoted password as UTF-16LE, base64-encoded), `pwdLastSet: 0` and
`userAccountControl: 512`. The directory creates the account completely or not at all. Group
membership is added with `samba-tool group addmembers`.

**Consequences.** Setting `unicodePwd` needs an encrypted connection; Samba's LDAP client signs and
seals the session, and the integration test proves it by signing in with the delivered password
(the domain answers "password must change", which also proves the flag is set).

## 5. An unprivileged Samba DC for tests, with xattr_tdb

**Context.** `samba-tool domain provision` stores NT ACLs in `security.*` extended attributes,
which need `CAP_SYS_ADMIN`. Running the test container privileged on a shared CI runner is
unnecessary risk.

**Decision.** The test DC is provisioned with `vfs objects = dfs_samba4 acl_xattr xattr_tdb`, which
keeps those attributes in a TDB file. The container runs with default privileges and a random
administrator password per run.

**Consequences.** Fine for a throwaway test domain; not how a production domain controller should
be built.

## 6. .NET networking classes for Test-ItoNetwork

**Context.** `Test-NetConnection` and `Get-NetIPConfiguration` only exist on Windows, and they are
hard to test.

**Decision.** `Test-ItoNetwork` uses `System.Net` classes (network interfaces, `Dns`, `TcpClient`,
`Ping`, `HttpWebRequest`) behind small private wrappers. The diagnosis is a separate pure
function that turns layer results into advice.

**Consequences.** The same code runs in Windows PowerShell 5.1 and PowerShell 7 on Windows and
Linux. The wrappers are mocked for the diagnosis tests and exercised for real against local
sockets. `HttpWebRequest` is marked obsolete in .NET, but it is the one HTTP API present in both
editions.

## 7. A small Python helper for CSV parsing

**Context.** HR feeds are CSV files with quoted fields, commas inside titles and Excel's byte
order mark. Bash has no reliable CSV parser.

**Decision.** `linux/lib/hrfeed.py` parses the CSV with Python's `csv` module, validates each row
with the same rules as the PowerShell module, and normalises names with `unicodedata` (NFKD, then
ASCII letters and digits only). Python 3 is already a hard dependency of `samba-tool`. The helper
is type-checked with `mypy --strict` and linted with ruff.

**Consequences.** One Python file in a Bash toolkit. Its output uses the ASCII unit separator
because `read` collapses runs of tabs and would lose empty fields.

## 8. Idempotent onboarding and offboarding

**Context.** Feeds get run twice and offboarding scripts get interrupted.

**Decision.** Onboarding skips any row whose employee ID already has an account. Offboarding
checks each step's current state (enabled, description, groups, OU) before changing it, and
exports group memberships before removing any, stopping if the export fails. Accounts are
disabled and moved, never deleted.

**Consequences.** Running either command again is safe and reports "Exists" or
"AlreadyOffboarded". Deleting accounts after a retention period is left to a separate, reviewed
process.

## 9. Windows PowerShell 5.1 compatibility is tested, not assumed

**Context.** Help desks still run Windows PowerShell 5.1. It lacks `??`, ternaries,
`ConvertFrom-Json -AsHashtable` and `RandomNumberGenerator.GetInt32`, and it reads script files
without a byte order mark as ANSI.

**Decision.** The module avoids PowerShell 7-only syntax and APIs, all PowerShell source is ASCII
(a Pester test enforces it), PSScriptAnalyzer checks syntax compatibility for 5.1 and 7.4, and the
Pester suite runs under Windows PowerShell 5.1 as well as PowerShell 7. The newer
`PSUseCompatibleCommands` rule was tried but needs more than 1.5 GB of memory in the test
container, so the lighter cmdlet check against the 5.1 profile is used instead.

**Consequences.** Some code is longer than PowerShell 7 would allow (for example the JSON
conversion helper). Two tests only run on PowerShell 7 (JSON schema validation with `Test-Json`,
and the openssl interoperability check) and are skipped on 5.1.

## 10. Exit codes that monitoring systems understand

**Context.** A health check is most useful when a scheduler or monitoring system can act on it.

**Decision.** `health-report.sh` exits with the Nagios plugin convention: 0 OK, 1 warning,
2 critical, 3 unknown. `net-check.sh` exits 1 when it finds a fault. Usage errors exit 64
(`EX_USAGE`).

**Consequences.** A container without systemd reports some checks as Unknown and exits 3; the
report says why for each one.

## 11. Pinned tools, updated deliberately

**Context.** Reproducible tests need fixed tool versions.

**Decision.** Pester 5.9.1 and PSScriptAnalyzer 1.25.0 are pinned in `scripts/Invoke-Tests.ps1`,
bats-core 1.14.0 and its libraries are pinned by tag and SHA-256 in `tests/docker/Dockerfile`,
ruff and mypy are pinned with hashes in `requirements-dev.txt`, and container images use explicit
tags. Dependabot updates GitHub Actions, the Dockerfile base image and the Python tools. The
Pester, PSScriptAnalyzer and bats versions, and the image tags in scripts, are updated by hand.
Pester 6 exists; staying on Pester 5 was a stated requirement.

**Consequences.** Some updates need a person to check release notes, which is intended.

## 12. Real sample output, with host details removed

**Context.** The README should show real output, but a real health report lists software
installed on the machine it ran on.

**Decision.** `docs/samples` holds output from real runs. For the Windows health report, the
computer name and the names of three third-party services were replaced with marked
placeholders before publishing; nothing else was edited. Samples from containers contain nothing
personal and are unchanged apart from temporary paths.

**Consequences.** The samples show what the tools print, and say exactly what was removed.
