# DNS resolution failures

Applies to: Windows clients and servers, Linux with systemd-resolved or a plain
`/etc/resolv.conf`, and Active Directory-integrated DNS.

## Symptoms

- Browsers show "DNS_PROBE_FINISHED_NXDOMAIN" or "This site can't be reached ... server IP
  address could not be found".
- A service works by IP address but not by name.
- Internal names fail at home or on the VPN, but work in the office.
- Domain sign-in or Group Policy fails with "The specified domain either does not exist or could
  not be contacted".

## Quick checks

1. Is it one name, or every name? The layered check tells them apart by trying a control name:

   ```powershell
   Test-ItoNetwork -ComputerName intranet.corp.example.com -ControlName corp.example.com
   ```

   "DNS works, but the name ... does not resolve" means that record is missing or not visible
   from here. "Name resolution is failing" means the DNS servers are not answering.
   On Linux: `linux/net-check.sh --control-name corp.example.com intranet.corp.example.com`.
2. Which DNS servers is the PC using, and what do they answer?

   ```powershell
   Get-DnsClientServerAddress -AddressFamily IPv4
   Resolve-DnsName intranet.corp.example.com -DnsOnly -NoHostsFile
   Resolve-DnsName intranet.corp.example.com -Server 10.1.0.10 -DnsOnly -NoHostsFile   # ask a specific server
   ```

   `-DnsOnly` uses the DNS protocol only (no LLMNR or NetBIOS), and `-NoHostsFile` ignores the
   hosts file, so the answer comes from the DNS servers.
3. Look for local overrides: the hosts file (`C:\Windows\System32\drivers\etc\hosts`), cached
   answers (`Get-DnsClientCache`), and name resolution rules pushed by a VPN
   (`Get-DnsClientNrptPolicy`).
4. For domain problems, check that the PC can find a domain controller:
   `nltest /dsgetdc:corp.example.com`.
5. On Linux: `resolvectl status` (servers per interface), `resolvectl query NAME`,
   `getent hosts NAME` (what applications see), and `dig NAME @10.1.0.10` for a specific server.

## Fix

1. Clear the cache after a record changes: `ipconfig /flushdns` (or `Clear-DnsClientCache`).
   Windows also caches failed lookups for a while, so flush after a missing record is added.
   On Linux: `resolvectl flush-caches`.
2. Renew DHCP so the correct DNS servers are applied: `ipconfig /release` then `ipconfig /renew`.
3. Remove wrong entries from the hosts file (edit it as administrator).
4. Correct a static DNS server setting to the servers the organisation uses.
5. For a domain-joined PC whose own record is wrong: `ipconfig /registerdns`.
6. Internal names from home: connect the VPN first. If they still fail, see
   [VPN fails](04-vpn-fails.md).

## When to escalate

- The DNS servers do not answer for anyone: escalate to the infrastructure team.
- A record is missing or wrong in an internal zone: the zone owner has to change it.
- Domain controllers cannot find each other, or `dcdiag /test:dns` on a domain controller shows
  errors.
- Answers differ from what they should be for no clear reason (possible hijacking or a rogue
  DHCP server): escalate to security.

## Prevention

- Give every site at least two DNS servers, and hand out both through DHCP.
- Lower a record's TTL a day before a planned change, and raise it again afterwards.
- Monitor DNS servers and domain controller health.

## Scripts that help

- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): separates a missing
  record from a DNS outage with a control name.
- [`net-check.sh`](../../linux/net-check.sh): the same on Linux, resolving through NSS as
  applications do.
