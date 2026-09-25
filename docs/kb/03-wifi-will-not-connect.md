# Wi-Fi will not connect

Applies to: Windows 10 and 11 laptops, and Linux with NetworkManager.

## Symptoms

- "Can't connect to this network", or the network is not listed at all.
- Connected, but "No internet" or pages do not load.
- The adapter has a 169.254.x.x address.
- The connection drops every few minutes.

## Quick checks

1. Is it only this device? If phones and other laptops in the same place also fail, the
   problem is the access point or the network, not the laptop: see "When to escalate".
2. Is Wi-Fi switched on? Check flight mode, the Wi-Fi quick setting, and any hardware switch or
   function key.
3. Run the layered check, which names the failing layer:

   ```powershell
   Test-ItoNetwork
   ```

   On Linux: `linux/net-check.sh`.
4. See what the adapter reports:

   ```powershell
   netsh wlan show interfaces     # SSID, signal strength, radio type and state
   ipconfig /all                  # 169.254.x.x means DHCP did not answer
   ```

5. For a history of connections and failures, `netsh wlan show wlanreport` writes an HTML
   report to `C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html`.
6. On Linux: `nmcli device status`, `nmcli device wifi list`, and
   `journalctl -u NetworkManager -b` for the errors.

## Fix

Work from least to most disruptive, and test after each step:

1. Turn Wi-Fi off and on, or restart the laptop.
2. Forget the network and join it again (this clears a stored old password):
   `netsh wlan delete profile name="CorpWiFi"`, then reconnect from the Wi-Fi list.
3. Renew the address: `ipconfig /release`, then `ipconfig /renew`.
4. On a hotel or guest network, open a browser and go to any plain http:// site to bring up the
   sign-in page.
5. On a corporate 802.1X network (certificate-based sign-in), check the device or user
   certificate has not expired: `certlm.msc` (computer) or `certmgr.msc` (user) > Personal >
   Certificates. Also check the clock: a wrong date makes valid certificates fail.
6. Update or roll back the Wi-Fi driver in Device Manager, and turn off "Allow the computer to
   turn off this device to save power" on the adapter's Power Management tab.
7. Reset the network stack, then restart: `netsh winsock reset` and `netsh int ip reset` (from an
   elevated prompt), or Settings > Network and internet > Advanced network settings >
   Network reset. Network reset removes VPN adapters and saved networks, so warn the user.

On Linux: `nmcli connection down "CorpWiFi"` then `nmcli connection up "CorpWiFi"`; if the saved
password is wrong, `nmcli connection delete "CorpWiFi"` and connect again with
`nmcli device wifi connect "CorpWiFi" --ask`.

## When to escalate

- Several users in one area cannot connect: an access point or switch is likely down. Escalate
  to the network team with the location and the time it started.
- 802.1X sign-in fails for users whose certificates are valid: the RADIUS server (for example
  Network Policy Server, which logs event 6273 when it denies access) needs checking.
- Many devices get 169.254.x.x addresses: the DHCP scope may be full.

## Prevention

- Monitor access points and DHCP scope use, with alerts before a scope runs out.
- Renew Wi-Fi certificates automatically (for example through Intune or Group Policy
  auto-enrolment).
- Keep Wi-Fi drivers up to date through your device management tool.

## Scripts that help

- [`Test-ItoNetwork`](../../src/ItOpsToolkit/Public/Test-ItoNetwork.ps1): layered check from IP
  configuration to HTTPS, with a plain-language diagnosis.
- [`net-check.sh`](../../linux/net-check.sh): the same checks on Linux.
