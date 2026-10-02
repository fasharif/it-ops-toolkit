# Design decisions

Short records of the choices that shaped this repository: the context, the decision and its
consequences.

## 1. One configuration file for Windows and Linux onboarding

**Context.** The same organisation may onboard people with the PowerShell module on Windows and
with the Bash scripts against Samba. Two department mappings would drift apart.

**Decision.** `New-ItoUser`, `Remove-ItoUser`, `onboard-user.sh` and `offboard-user.sh` read the
same JSON file (`config/onboarding.example.json`, described by `config/onboarding.schema.json`).
Both sides validate it with the same rules and reject unknown settings, so a typo such as
`departmens` fails loudly instead of being ignored. Like the JSON schema, the rules are
case-sensitive: setting names, `samAccountNameFormat` and the `OU=`, `CN=` and `DC=` parts of
distinguished names must be written as documented. HR department names in the feed are matched
without regard to case.

**Consequences.** The Bash scripts need `jq`. Validation logic exists twice (PowerShell and a jq
program), so both test suites run the same bad configurations from
`tests/fixtures/invalid-configs.tsv`. PowerShell ignores case by default, so the PowerShell side
has to use case-sensitive operators and hashtables on purpose.

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
(PKCS #7, AES-256) encrypted files for a service desk certificate: .NET's `EnvelopedCms` class
in the PowerShell module, `openssl cms` on Linux. The module does not call
`Protect-CmsMessage`: PowerShell module logging (event 4103) records the value of every command
parameter, so `-Content` would put the password in the event log wherever that logging is
enabled. The password goes from a `SecureString` to a byte array that is cleared afterwards,
through method calls only. Where the password is passed to a command (`New-ADUser` and the
module's own delivery functions), it is a `SecureString`, which module logging records only as
its type name, `System.Security.SecureString`. The PowerShell result object also carries the
password as a `SecureString`. Tests check that the password never appears in output streams,
transcripts, summaries, command lines, tool errors or a `ParameterBinding` trace, which sees the
same parameter values as module logging. Module logging itself was not switched on for the
tests, because that is a system policy change.

**Consequences.** The service desk needs a certificate with an RSA key and the Document
Encryption enhanced key usage, and its private key to read the files (`Unprotect-CmsMessage` or
`openssl cms -decrypt`). The certificate can be given as a file, an object or a thumbprint in a
personal store. Both tools produce standard CMS, so a file written by PowerShell can be
decrypted with openssl and the other way round; a Pester test checks this.

The two toolkits differ in one place. `onboard-user.sh` refuses a real run without
`--deliver-dir` and `--deliver-cert`, because a script has no result object to hand the password
back on. `New-ItoUser` allows a run without `-DeliveryPath`, for scripts that pass the
`SecureString` on themselves, and ends such a run with a warning that the passwords exist only on
the results. An operator who did not keep the output (`$results = New-ItoUser ...`) must reset
those passwords, which the warning says.

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

**Consequences.** One code path serves both editions and both operating systems. It has run for
real in Windows PowerShell 5.1 on Windows 11 and in PowerShell 7.5 and 7.6 on Linux
(`docs/samples`); PowerShell 7 on Windows and macOS have not been tried yet. The wrappers are
mocked for the diagnosis tests and exercised for real against local sockets. `HttpWebRequest` is
marked obsolete in .NET, but it is the one HTTP API present in both editions.

## 7. A small Python helper for CSV parsing

**Context.** HR feeds are CSV files with quoted fields, commas inside titles and Excel's byte
order mark. Bash has no reliable CSV parser.

**Decision.** `linux/lib/hrfeed.py` parses the CSV with Python's `csv` module, validates each row
with the same rules as the PowerShell module, and normalises names the same way: Latin letters
that have no Unicode decomposition are spelled in ASCII first (ß as ss, ø as o, ł as l, þ as th
and so on), then `unicodedata` decomposes the rest (NFKD) and only ASCII letters and digits are
kept. Python 3 is already a hard dependency of `samba-tool`. The helper is type-checked with
`mypy --strict` and linted with ruff, and `onboard-user.sh` runs it in isolated mode
(`python3 -I`), so nothing next to it can shadow a standard library module.

**Consequences.** One Python file in a Bash toolkit. Its output uses the ASCII unit separator
because `read` collapses runs of tabs and would lose empty fields. The row rules exist twice, so
both test suites check `tests/fixtures/feed-rows.csv`, which lists rows and the exact problems
each must produce. That fixture found one difference: Python's `strptime` accepted `2026-1-5`
and Arabic-Indic digits as a start date, which the PowerShell side rejects; `hrfeed.py` now
requires exactly `yyyy-MM-dd` in ASCII digits too.

## 8. Idempotent onboarding and offboarding

**Context.** Feeds get run twice and offboarding scripts get interrupted.

**Decision.** Onboarding skips any row whose employee ID already has an account. Offboarding
checks each step's current state (enabled, description, groups, OU) before changing it, and
exports group memberships before removing any, stopping if the export fails. If the operator
answers No to the export prompt, `Remove-ItoUser` does not remove any groups either, still runs
the steps that were accepted, and reports `Partial` with what was not done. Accounts are
disabled and moved, never deleted.

**Consequences.** Running either command again is safe and reports "Exists" or
"AlreadyOffboarded", and a second run finishes a `Partial` offboarding. Deleting accounts after
a retention period is left to a separate, reviewed process.

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
conversion helper). Three tests are skipped on Windows PowerShell 5.1: JSON schema validation
with `Test-Json` and the openssl interoperability check need PowerShell 7, and the certificate
store lookup test only runs on Linux, where the CurrentUser store is a folder in a throwaway
home directory rather than the real Windows store.

## 10. Exit codes that monitoring systems understand

**Context.** A health check is most useful when a scheduler or monitoring system can act on it.

**Decision.** `health-report.sh` exits with the Nagios plugin convention: 0 OK, 1 warning,
2 critical, 3 unknown. `net-check.sh` exits 1 when it finds a fault. Usage errors exit 64
(`EX_USAGE`).

**Consequences.** A container without systemd reports some checks as Unknown and exits 3; the
report says why for each one.

## 11. Pinned tools, updated deliberately

**Context.** Reproducible tests need fixed tool versions.

**Decision.** Pester 5.9.1 and PSScriptAnalyzer 1.25.0 are pinned in `scripts/Invoke-Tests.ps1`
with the SHA-256 of their packages; with `-Install` the runner downloads them from the PowerShell
Gallery, checks the hash and unpacks them into `out/modules`, so nothing is installed into the
user's profile. bats-core 1.14.0 and its libraries are pinned by tag and SHA-256 in
`tests/docker/Dockerfile`, the Debian and Ubuntu base images are pinned by digest, ruff and mypy
are pinned with hashes in `requirements-dev.txt`, and other container images use explicit tags.
The Samba packages come from Debian 13 when the image is built, so `tests/integration/run.sh`
prints the Samba version each run tested. PowerShell for the container tests is 7.6.6, the
current LTS release, installed from Microsoft's `.deb` package pinned by version and SHA-256.
Microsoft's own container image was not used: its registry has no 7.6 tag, and its
`7.5-ubuntu-24.04` tag still held 7.5.0 from January 2025. Dependabot updates GitHub Actions, the
Dockerfile base images and the Python tools. The Pester, PSScriptAnalyzer, bats and PowerShell
versions, and the image tags in scripts, are updated by hand. Pester 6 exists; staying on
Pester 5 was a stated requirement.

**Consequences.** Some updates need a person to check release notes, which is intended. An
earlier version of the runner installed missing modules into the user's profile, and did so on
the development machine once; that is why it now stops unless `-Install` is given.

## 12. Real sample output, with host details removed

**Context.** The README should show real output, but a real health report lists software
installed on the machine it ran on.

**Decision.** `docs/samples` holds output from real runs, and each file says where it ran.
`scripts/make-samples.sh` regenerates every Linux sample in the test containers, including
onboarding and offboarding against the throwaway Samba domain with exactly the commands shown.
The Windows samples are recorded by hand with the commands listed in `docs/samples/README.md`.
For the Windows health report, the computer name and the names of three third-party services
were replaced with marked placeholders before publishing; nothing else was edited. GitHub shows
an `.html` file as source code, so the README shows a screenshot of the edited report.

**Consequences.** The samples show what the tools print, where, and exactly what was removed. A
sample from a container shows container facts (a WSL 2 kernel, no systemd, no LVM), and says so
rather than posing as a server.

## 13. New accounts are enabled when they are created, before the start date

**Context.** The new starter checklist (KB 10) asks for accounts about five working days before
the start date, so group memberships, mailboxes and licences are ready on day one. An enabled
account that exists days before its owner arrives is a small risk.

**Decision.** Both toolkits create the account enabled, with a random initial password that only
the holder of the delivery certificate can read, and "must change password at next logon" set.
The start date goes into the description. There is no option to create the account disabled
until the start date.

**Consequences.** Before day one, nobody but the service desk can sign in, because nobody else
has the password, and the first sign-in forces a new one. Organisations that want the account
switched off until the start date can disable it after onboarding (`Disable-ADAccount`,
`samba-tool user disable`) and enable it on the day; a `-Disabled` option that does this in one
step is on the roadmap.

## 14. One domain controller for a whole run

**Context.** Without `-Server`, each ActiveDirectory cmdlet finds its own domain controller. In a
domain with several, a group change right after `New-ADUser` can reach a domain controller that
has not received the new account yet.

**Decision.** `New-ItoUser` and `Remove-ItoUser` find one writable domain controller that runs
Active Directory Web Services at the start (`Get-ADDomainController -Discover -Writable
-Service ADWS`) and use it for every call; `-Server` overrides it. The Bash scripts already use
the one domain controller named by `--url`.

**Consequences.** A run fails at the start, before any change, when no domain controller can be
found. A rerun of a feed reports configured groups that an existing account lacks, rather than
adding them, because the person may have changed department since.

## 15. Names in Arabic and other scripts need a Latin spelling from HR

**Context.** Account names and sign-in names must be ASCII, but HR systems in the UAE and the
wider region often hold names in Arabic. Transliterating Arabic automatically gives spellings
that people do not recognise as their own: the same name is written Mohammed, Muhammad or
Mohamed, and the choice belongs to the person (it is usually the spelling in their passport).

**Decision.** Both toolkits accept two optional feed columns, `GivenNameLatin` and
`SurnameLatin`. When present, the account name is built from them; `givenName`, `sn`,
`displayName` and the CN keep the original script. There is no automatic transliteration of
non-Latin scripts. A row whose name has no Latin letters and no Latin spelling is `Invalid`, and
the message names the column to fill in. Latin names with accents (José, Łukasz) are still
reduced to ASCII automatically, because that mapping is not in doubt.

**Consequences.** HR has to supply the Latin spelling, which the new starter checklist (KB 10)
asks for. The shared fixture `tests/fixtures/feed-rows.csv` checks both toolkits with Arabic
names, and the Samba integration test creates an account with an Arabic display name and a
Latin account name.

## 16. Which stopped services the health report counts

**Context.** Windows has many services set to start automatically that stop by design once their
work is done, with exit code 0. Counting every stopped automatic service gave warnings on healthy
PCs, so the report was changed to count only services that stopped with an error. That fixed the
false positives but created a false negative: a Print Spooler stopped with `Stop-Service` or from
services.msc also exits with 0, and a stopped spooler is exactly what the printer ticket needs
to find (KB 05).

**Decision.** A stopped automatic service counts when it stopped with an error or never started,
or when it is on a short essential list, whatever its exit code: `Dhcp`, `Dnscache`, `EventLog`,
`LanmanWorkstation`, `mpssvc`, `Spooler` and `Winmgmt`, the services behind common tickets
(addresses, name resolution, logging, file shares, firewall, printing, management). Essential
services count even when they are trigger-start. The ignored list wins over the essential list,
and both can be changed in the threshold file (`essentialServices`, `ignoredServices`).
Delayed-start services are not counted in the first 10 minutes after boot.

**Consequences.** Only services set to start automatically are read, so a service disabled on
purpose (for example the spooler on computers that never print) is never reported. A
third-party service that someone stopped cleanly is still only listed for information; add it
to `essentialServices` if it matters. `W32Time` and `WinDefend` were left off the default list,
because whether they run depends on domain membership and on the antivirus product in use, which
would bring back false positives on some PCs.

