# VPN fails

Applies to: the Windows built-in VPN client (IKEv2, SSTP, L2TP) and SSL VPN clients such as
Cisco Secure Client, GlobalProtect or FortiClient.

## Symptoms

- The VPN does not connect, or shows an error code.
- The VPN connects, but internal sites, file shares or Outlook do not work.
- The VPN disconnects every few minutes, or some sites load and others hang.

## Quick checks

1. Does the internet work without the VPN? If not, fix that first:
   `Test-ItoNetwork` (Windows) or `linux/net-check.sh` (Linux).
2. Can the laptop reach the VPN gateway? For an SSL VPN or SSTP on TCP 443:

   ```powershell
   Test-ItoNetwork -ComputerName vpn.corp.example.com -Port 443
   ```

   IKEv2 and L2TP use UDP 500 and 4500, which a TCP check cannot test. Hotel and guest networks
   often block them.
3. Read the error code (built-in client):
   - **809**: the server did not respond, usually because UDP 500/4500 is blocked or NAT
     traversal failed. Try another network or an SSTP/SSL profile.
   - **691**: the user name or password was not accepted. Check for an expired password or a
     lockout ([Account locked out](01-account-locked-out.md)).
   - **812**: the connection was refused by a policy on the VPN or RADIUS server (for example
     the user is not in the VPN group).
   - **868**: the VPN server's name could not be resolved: a DNS problem.
4. Check the clock and the user's password: an expired password or an MFA prompt the user missed
   often looks like a VPN fault.

### Connected, but internal resources fail

1. Does the internal name resolve?

   ```powershell
   Test-ItoNetwork -ComputerName intranet.corp.example.com -ControlName corp.example.com
   Get-DnsClientServerAddress          # which DNS servers each adapter uses
   Get-DnsClientNrptPolicy             # name resolution rules pushed by Always On VPN or DirectAccess
   ```

2. Is there a route to the internal network? `route print` (or `Get-NetRoute`) should show the
   office subnets on the VPN interface.
3. Does the home network use the same address range as the office (for example both
   192.168.1.0/24)? Then traffic to the office stays on the home network. Ask the user to test
   from another network, and escalate so the VPN can push more specific routes.

## Fix

1. Disconnect, close the VPN client, and connect again.
2. Re-enter the credentials, or remove saved VPN credentials in Credential Manager.
3. On a network that blocks the VPN (hotel, guest Wi-Fi), use a mobile hotspot to confirm, then
   use the SSL or SSTP profile if the organisation provides one.
4. If only some sites hang, suspect the MTU: `ping -f -l 1400 fileserver.corp.example.com` sends
   an unfragmentable 1400-byte packet. If it fails and smaller sizes work, report it to the
   network team.
5. Reinstall the VPN client or re-import the VPN profile.

## When to escalate

- Several users cannot connect: the VPN gateway, its certificate or its licences may have a
  problem.
- Error 812 or missing office routes: the VPN or RADIUS policy needs changing.
- Address overlap between home and office networks.

## Prevention

- Monitor the VPN gateway, its certificate expiry dates and its licence use.
- Keep VPN clients up to date through device management.
- Provide an SSL-based profile for networks that block IPsec.

## Scripts that help

- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): checks the path to the
  gateway and to internal names, and tells a missing DNS record apart from a DNS outage.
- [`net-check.sh`](../../linux/net-check.sh): the same checks on Linux.
