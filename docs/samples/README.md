# Sample output

Real output from the tools. Each text file starts with a line that says where and how it was
recorded. Nothing was edited except where this table says so.

| File | Where it ran | How to reproduce |
| --- | --- | --- |
| [samba-onboarding.txt](samba-onboarding.txt) | Throwaway Samba AD test domain (Samba 4.22.11, Debian 13 containers) | `scripts/make-samples.sh` |
| [samba-offboarding.txt](samba-offboarding.txt) | The same test domain | `scripts/make-samples.sh` |
| [linux-health-and-monitoring.txt](linux-health-and-monitoring.txt) | The Debian 13 test container on Docker Desktop, hostname `it-ops-test`. A container has no systemd, LVM or LUKS, so some checks are Unknown. | `scripts/make-samples.sh` |
| [net-check.txt](net-check.txt) | The same container. Docker answers ICMP itself, so the route trace stops at hop 1. | `scripts/make-samples.sh` |
| [test-itonetwork-linux.txt](test-itonetwork-linux.txt) | PowerShell 7.6.6 in the Ubuntu 24.04 test container (`tests/docker/Dockerfile`, target `powershell`) | `scripts/make-samples.sh` |
| [test-itonetwork-windows.txt](test-itonetwork-windows.txt) | Windows PowerShell 5.1 on a Windows 11 PC on Wi-Fi | The four commands in the file, after `Import-Module .\src\ItOpsToolkit\ItOpsToolkit.psd1` |
| [windows-health-report.html](windows-health-report.html), [windows-health-report.json](windows-health-report.json) | Windows PowerShell 5.1 on the same PC, not elevated, on 2026-09-27, while it was busy with parallel container builds (hence the memory Warning) | `Get-ItoHealthReport -OutputDirectory <folder>` |
| [windows-health-report.png](windows-health-report.png) | A screenshot of the HTML file above (after the names were removed), taken with Microsoft Edge in headless mode at 1280 by 1150 pixels | `msedge --headless=new --hide-scrollbars --window-size=1280,1150 --screenshot=windows-health-report.png <file URL of the HTML file>` |

Edits: in the Windows health report, the computer name and the names of three third-party
services were replaced with marked placeholders, because they identify the machine and the
software on it; the screenshot shows the edited file. In test-itonetwork-windows.txt, the
trailing spaces that Windows PowerShell adds to table rows were removed. Nothing else was
changed in any file.
