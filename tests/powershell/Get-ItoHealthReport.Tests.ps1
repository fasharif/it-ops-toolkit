BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule

    function Get-Check {
        param([Parameter(Mandatory)] $Report, [Parameter(Mandatory)] [string] $Name)
        $Report.Checks | Where-Object { $_.Name -eq $Name }
    }
}

Describe 'Get-ItoHealthReport' {
    BeforeEach {
        # A healthy computer. Individual tests override one data source at a time.
        Mock -ModuleName ItOpsToolkit Test-ItoWindowsPlatform { $true }
        Mock -ModuleName ItOpsToolkit Get-ItoDiskData {
            [pscustomobject]@{ Drive = 'C:'; SizeBytes = 500GB; FreeBytes = 200GB }
            [pscustomobject]@{ Drive = 'D:'; SizeBytes = 1000GB; FreeBytes = 600GB }
        }
        Mock -ModuleName ItOpsToolkit Get-ItoOperatingSystemData {
            [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; TotalMemoryKB = 16GB / 1KB; FreeMemoryKB = 8GB / 1KB; LastBootUpTime = (Get-Date).AddDays(-2) }
        }
        Mock -ModuleName ItOpsToolkit Get-ItoPendingRebootData { }
        Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData { }
        Mock -ModuleName ItOpsToolkit Get-ItoCriticalEventData { }
        Mock -ModuleName ItOpsToolkit Get-ItoLastUpdateData { [pscustomobject]@{ HotFixId = 'KB5065426'; Description = 'Security Update'; InstalledOn = (Get-Date).AddDays(-10) } }
        Mock -ModuleName ItOpsToolkit Get-ItoBitLockerData { [pscustomobject]@{ Available = $true; MountPoint = 'C:'; ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted'; EncryptionPercentage = 100 } }
    }

    Context 'a healthy computer' {
        It 'reports OK for every check' {
            $report = Get-ItoHealthReport
            $report.PSObject.TypeNames | Should -Contain 'ItOpsToolkit.HealthReport'
            $report.OverallStatus | Should -Be 'OK'
            $report.Checks.Name | Should -Be @('Disk space C:', 'Disk space D:', 'Memory', 'Uptime', 'Pending reboot', 'Automatic services', 'Critical events', 'Last update installed', 'BitLocker')
            $report.Checks.Status | Should -Be @('OK', 'OK', 'OK', 'OK', 'OK', 'OK', 'OK', 'OK', 'OK')
            $report.GeneratedAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }

        It 'describes values in plain units' {
            $report = Get-ItoHealthReport
            (Get-Check $report 'Disk space C:').Value | Should -Be '40.0% free (200.0 GB of 500.0 GB)'
            (Get-Check $report 'Memory').Value | Should -Be '50.0% used (8.0 GB free of 16.0 GB)'
            (Get-Check $report 'Last update installed').Value | Should -Be ('KB5065426 installed {0:yyyy-MM-dd} (10 days ago)' -f (Get-Date).AddDays(-10))
            (Get-Check $report 'BitLocker').Value | Should -Be 'Protection on for C: (FullyEncrypted, 100% encrypted)'
        }
    }

    Context 'thresholds' {
        It 'grades disk space <FreeGB> GB free of 100 GB as <Expected>' -ForEach @(
            @{ FreeGB = 25; Expected = 'OK' }
            @{ FreeGB = 20; Expected = 'OK' }
            @{ FreeGB = 19.9; Expected = 'Warning' }
            @{ FreeGB = 10; Expected = 'Warning' }
            @{ FreeGB = 9.9; Expected = 'Critical' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoDiskData { [pscustomobject]@{ Drive = 'C:'; SizeBytes = 100GB; FreeBytes = $FreeGB * 1GB } }
            (Get-Check (Get-ItoHealthReport) 'Disk space C:').Status | Should -Be $Expected
        }

        It 'grades memory at <UsedPercent>% used as <Expected>' -ForEach @(
            @{ UsedPercent = 84.9; Expected = 'OK' }
            @{ UsedPercent = 85; Expected = 'Warning' }
            @{ UsedPercent = 95; Expected = 'Critical' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoOperatingSystemData {
                [pscustomobject]@{ Caption = 'Windows'; Version = '10'; TotalMemoryKB = 1000000; FreeMemoryKB = 1000000 * (100 - $UsedPercent) / 100; LastBootUpTime = (Get-Date).AddHours(-1) }
            }
            (Get-Check (Get-ItoHealthReport) 'Memory').Status | Should -Be $Expected
        }

        It 'grades an uptime of <Days> days as <Expected>' -ForEach @(
            @{ Days = 13.9; Expected = 'OK' }
            @{ Days = 14; Expected = 'Warning' }
            @{ Days = 31; Expected = 'Critical' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoOperatingSystemData {
                [pscustomobject]@{ Caption = 'Windows'; Version = '10'; TotalMemoryKB = 1000; FreeMemoryKB = 900; LastBootUpTime = (Get-Date).AddDays(-$Days) }
            }
            $check = Get-Check (Get-ItoHealthReport) 'Uptime'
            $check.Status | Should -Be $Expected
        }

        It 'warns about a pending reboot and lists the reasons' {
            Mock -ModuleName ItOpsToolkit Get-ItoPendingRebootData { 'Windows Update'; 'Computer rename' }
            $check = Get-Check (Get-ItoHealthReport) 'Pending reboot'
            $check.Status | Should -Be 'Warning'
            $check.Value | Should -Be 'Reboot pending: Windows Update; Computer rename'
        }

        It 'ignores trigger-start and known self-stopping services' {
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 1067 }
                [pscustomobject]@{ Name = 'WSearch'; DisplayName = 'Windows Search'; State = 'Stopped'; DelayedAutoStart = $true; TriggerStart = $true; ExitCode = 0 }
                [pscustomobject]@{ Name = 'sppsvc'; DisplayName = 'Software Protection'; State = 'Stopped'; DelayedAutoStart = $true; TriggerStart = $false; ExitCode = 0 }
                [pscustomobject]@{ Name = 'clr_optimization_v4.0.30319_64'; DisplayName = '.NET Optimization'; State = 'Stopped'; DelayedAutoStart = $true; TriggerStart = $false; ExitCode = 0 }
            }
            $check = Get-Check (Get-ItoHealthReport) 'Automatic services'
            $check.Status | Should -Be 'Warning'
            $check.Value | Should -Be '1 automatic service(s) stopped that should be running: Spooler'
            @($check.Data).Count | Should -Be 1
        }

        It 'counts an essential service such as the Print Spooler even after a clean stop' {
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
                [pscustomobject]@{ Name = 'Dnscache'; DisplayName = 'DNS Client'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $true; ExitCode = 0 }
            }
            $check = Get-Check (Get-ItoHealthReport) 'Automatic services'
            $check.Status | Should -Be 'Warning'
            $check.Value | Should -Be '2 automatic service(s) stopped that should be running: Dnscache, Spooler'
            $check.Detail | Should -BeLike 'Essential, so counted even after a clean stop: Dnscache, Spooler.*'
            @($check.Data).Reason | Should -Be @('EssentialStopped', 'EssentialStopped')
            $check.Threshold | Should -BeLike '*essential (Dhcp, Dnscache, EventLog, LanmanWorkstation, mpssvc, Spooler, Winmgmt)*'
        }

        It 'lets the ignored list win over the essential list, and reads both from a threshold file' {
            $path = Join-Path -Path $TestDrive -ChildPath 'service-thresholds.json'
            Set-Content -LiteralPath $path -Value '{ "ignoredServices": ["Spooler"], "essentialServices": ["W32Time"] }' -Encoding UTF8
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 1067 }
                [pscustomobject]@{ Name = 'Dnscache'; DisplayName = 'DNS Client'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
                [pscustomobject]@{ Name = 'W32Time'; DisplayName = 'Windows Time'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
            }
            $check = Get-Check (Get-ItoHealthReport -ThresholdPath $path) 'Automatic services'
            $check.Value | Should -Be '1 automatic service(s) stopped that should be running: W32Time'
            @($check.Data | ForEach-Object { '{0}={1}' -f $_.Name, $_.Reason }) | Should -Be @('Dnscache=StoppedCleanly', 'W32Time=EssentialStopped')
        }

        It 'lists services that stopped cleanly for information without counting them' {
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'WslInstaller'; DisplayName = 'WSL'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
                [pscustomobject]@{ Name = 'VendorUpdater'; DisplayName = 'Vendor updater'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
            }
            $report = Get-ItoHealthReport
            $check = Get-Check $report 'Automatic services'
            $check.Status | Should -Be 'OK'
            $check.Value | Should -Be 'No essential service is stopped and no automatic service stopped with an error'
            $check.Detail | Should -Be 'For information, not counted: 1 automatic service(s) stopped cleanly (exit code 0), which is usual for services that stop once their work is done: VendorUpdater.'
            @($check.Data).Reason | Should -Be @('StoppedCleanly')
            $report.OverallStatus | Should -Be 'OK'
        }

        It 'does not count delayed-start services in the first minutes after boot, but does afterwards' -ForEach @(
            @{ MinutesSinceBoot = 4; Expected = 'OK'; Reason = 'DelayedStartPending' }
            @{ MinutesSinceBoot = 30; Expected = 'Warning'; Reason = 'Failed' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoOperatingSystemData {
                [pscustomobject]@{ Caption = 'Windows'; Version = '10'; TotalMemoryKB = 1000; FreeMemoryKB = 900; LastBootUpTime = (Get-Date).AddMinutes(-$MinutesSinceBoot) }
            }
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'BITS'; DisplayName = 'Background Intelligent Transfer Service'; State = 'Stopped'; DelayedAutoStart = $true; TriggerStart = $false; ExitCode = 1077 }
            }
            $check = Get-Check (Get-ItoHealthReport) 'Automatic services'
            $check.Status | Should -Be $Expected
            @($check.Data).Reason | Should -Be @($Reason)
        }

        It 'counts delayed-start services when the boot time cannot be read' {
            Mock -ModuleName ItOpsToolkit Get-ItoOperatingSystemData { throw 'Access denied' }
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'BITS'; DisplayName = 'BITS'; State = 'Stopped'; DelayedAutoStart = $true; TriggerStart = $false; ExitCode = 1077 }
            }
            (Get-Check (Get-ItoHealthReport) 'Automatic services').Status | Should -Be 'Warning'
        }

        It 'is critical when five or more automatic services are stopped' {
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                foreach ($name in 'Svc1', 'Svc2', 'Svc3', 'Svc4', 'Svc5') {
                    [pscustomobject]@{ Name = $name; DisplayName = $name; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 1 }
                }
            }
            (Get-Check (Get-ItoHealthReport) 'Automatic services').Status | Should -Be 'Critical'
        }

        It 'grades <Count> critical event(s) as <Expected>' -ForEach @(
            @{ Count = 1; Expected = 'Warning' }
            @{ Count = 4; Expected = 'Warning' }
            @{ Count = 5; Expected = 'Critical' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoCriticalEventData {
                for ($i = 1; $i -le $Count; $i++) {
                    [pscustomobject]@{ TimeCreated = (Get-Date).AddHours(-$i); LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Message = 'The system has rebooted without cleanly shutting down first.' }
                }
            }
            $check = Get-Check (Get-ItoHealthReport) 'Critical events'
            $check.Status | Should -Be $Expected
            $check.Detail | Should -BeLike ('Most frequent: Microsoft-Windows-Kernel-Power, 41 x{0}*' -f $Count)
        }

        It 'passes the event window to the collector' {
            $null = Get-ItoHealthReport -EventWindowHours 72
            Should -Invoke -ModuleName ItOpsToolkit Get-ItoCriticalEventData -Times 1 -Exactly -ParameterFilter { $Hours -eq 72 }
        }

        It 'grades the last update <Days> days ago as <Expected>' -ForEach @(
            @{ Days = 34; Expected = 'OK' }
            @{ Days = 35; Expected = 'Warning' }
            @{ Days = 60; Expected = 'Critical' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoLastUpdateData { [pscustomobject]@{ HotFixId = 'KB1'; Description = 'Update'; InstalledOn = (Get-Date).Date.AddDays(-$Days) } }
            (Get-Check (Get-ItoHealthReport) 'Last update installed').Status | Should -Be $Expected
        }

        It 'says <Expected> for an update installed <Days> day(s) ago' -ForEach @(
            @{ Days = 0; Expected = 'today' }
            @{ Days = 1; Expected = '1 day ago' }
            @{ Days = 2; Expected = '2 days ago' }
        ) {
            Mock -ModuleName ItOpsToolkit Get-ItoLastUpdateData { [pscustomobject]@{ HotFixId = 'KB1'; Description = 'Update'; InstalledOn = (Get-Date).Date.AddDays(-$Days) } }
            (Get-Check (Get-ItoHealthReport) 'Last update installed').Value | Should -BeLike "KB1 installed * ($Expected)"
        }

        It 'is Unknown when no update has an installation date' {
            Mock -ModuleName ItOpsToolkit Get-ItoLastUpdateData { }
            (Get-Check (Get-ItoHealthReport) 'Last update installed').Status | Should -Be 'Unknown'
        }

        It 'warns when BitLocker protection is off' {
            Mock -ModuleName ItOpsToolkit Get-ItoBitLockerData { [pscustomobject]@{ Available = $true; MountPoint = 'C:'; ProtectionStatus = 'Off'; VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0 } }
            $report = Get-ItoHealthReport
            (Get-Check $report 'BitLocker').Status | Should -Be 'Warning'
            $report.OverallStatus | Should -Be 'Warning'
        }

        It 'reports BitLocker as Unknown, with the reason, when it cannot be read' {
            Mock -ModuleName ItOpsToolkit Get-ItoBitLockerData { [pscustomobject]@{ Available = $false; Reason = 'The BitLocker PowerShell module is not available on this system.' } }
            $check = Get-Check (Get-ItoHealthReport) 'BitLocker'
            $check.Status | Should -Be 'Unknown'
            $check.Detail | Should -Be 'The BitLocker PowerShell module is not available on this system.'
        }

        It 'uses the worst check as the overall status' {
            Mock -ModuleName ItOpsToolkit Get-ItoDiskData { [pscustomobject]@{ Drive = 'C:'; SizeBytes = 100GB; FreeBytes = 5GB } }
            Mock -ModuleName ItOpsToolkit Get-ItoPendingRebootData { 'Windows Update' }
            (Get-ItoHealthReport).OverallStatus | Should -Be 'Critical'
        }
    }

    Context 'failures and custom thresholds' {
        It 'marks an area Unknown when its data source fails, and still reports the rest' {
            Mock -ModuleName ItOpsToolkit Get-ItoCriticalEventData { throw 'The RPC server is unavailable.' }
            $report = Get-ItoHealthReport
            $check = Get-Check $report 'Critical events'
            $check.Status | Should -Be 'Unknown'
            $check.Detail | Should -Be 'The data could not be read: The RPC server is unavailable.'
            $report.Checks.Count | Should -Be 9
            $report.OverallStatus | Should -Be 'Unknown'
        }

        It 'applies overrides from a threshold file' {
            $path = Join-Path -Path $TestDrive -ChildPath 'thresholds.json'
            Set-Content -LiteralPath $path -Value '{ "diskFreePercentWarning": 50, "diskFreePercentCritical": 30, "bitLockerOffStatus": "Critical" }' -Encoding UTF8
            Mock -ModuleName ItOpsToolkit Get-ItoBitLockerData { [pscustomobject]@{ Available = $true; MountPoint = 'C:'; ProtectionStatus = 'Off'; VolumeStatus = 'FullyDecrypted'; EncryptionPercentage = 0 } }
            $report = Get-ItoHealthReport -ThresholdPath $path
            (Get-Check $report 'Disk space C:').Status | Should -Be 'Warning'
            (Get-Check $report 'Disk space C:').Threshold | Should -Be 'Warning below 50% free, critical below 30% free'
            (Get-Check $report 'BitLocker').Status | Should -Be 'Critical'
        }

        It 'accepts the example threshold file' {
            $path = Join-Path -Path $script:RepoRoot -ChildPath 'config/health-thresholds.example.json'
            (Get-ItoHealthReport -ThresholdPath $path).OverallStatus | Should -Be 'OK'
        }

        It 'rejects a threshold file with <Case>' -ForEach @(
            @{ Case = 'an unknown key'; Json = '{ "diskWarning": 5 }'; Message = "*Unknown threshold 'diskWarning'*" }
            @{ Case = 'a negative number'; Json = '{ "uptimeDaysWarning": -1 }'; Message = "*'uptimeDaysWarning' cannot be negative*" }
            @{ Case = 'a string where a number belongs'; Json = '{ "uptimeDaysWarning": "ten" }'; Message = "*'uptimeDaysWarning' must be a number*" }
            @{ Case = 'the disk levels the wrong way round'; Json = '{ "diskFreePercentWarning": 5, "diskFreePercentCritical": 10 }'; Message = '*DiskFreePercentCritical must not be greater*' }
            @{ Case = 'the memory levels the wrong way round'; Json = '{ "memoryUsedPercentWarning": 99 }'; Message = '*MemoryUsedPercentCritical must not be lower*' }
            @{ Case = 'an invalid BitLocker status'; Json = '{ "bitLockerOffStatus": "Bad" }'; Message = "*'bitLockerOffStatus' must be OK, Warning or Critical*" }
        ) {
            $path = Join-Path -Path $TestDrive -ChildPath 'bad-thresholds.json'
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            { Get-ItoHealthReport -ThresholdPath $path } | Should -Throw -ExpectedMessage $Message
        }

        It 'explains that it needs Windows' {
            Mock -ModuleName ItOpsToolkit Test-ItoWindowsPlatform { $false }
            { Get-ItoHealthReport } | Should -Throw -ExpectedMessage '*Windows only*linux/health-report.sh*'
        }
    }

    Context 'report files' {
        BeforeEach {
            $script:outDir = Join-Path -Path $TestDrive -ChildPath ('reports-{0}' -f [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:outDir
        }

        It 'writes JSON that parses back to the same results, with ISO 8601 dates' {
            Mock -ModuleName ItOpsToolkit Get-ItoCriticalEventData {
                [pscustomobject]@{ TimeCreated = [datetime]'2026-09-25T08:15:00'; LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Message = 'Unexpected shutdown' }
            }
            $report = Get-ItoHealthReport -OutputDirectory $script:outDir
            $report.JsonPath | Should -Match 'health-.+-\d{8}T\d{6}Z\.json$'
            $raw = Get-Content -LiteralPath $report.JsonPath -Raw
            $raw | Should -Not -Match '\\/Date\('
            $parsed = $raw | ConvertFrom-Json
            $parsed.OverallStatus | Should -Be 'Warning'
            @($parsed.Checks).Count | Should -Be 9
            # PowerShell 7's ConvertFrom-Json turns ISO strings back into dates, so check the raw text.
            $raw | Should -Match '"TimeCreated":\s*"2026-09-25T08:15:00'
            $parsed.Thresholds.DiskFreePercentWarning | Should -Be 20
        }

        It 'writes a self-contained HTML page that encodes untrusted text' {
            Mock -ModuleName ItOpsToolkit Get-ItoCriticalEventData {
                [pscustomobject]@{ TimeCreated = Get-Date; LogName = 'Application'; ProviderName = 'EvilApp'; Id = 1000; Message = '<script>alert("x")</script> & more' }
            }
            $report = Get-ItoHealthReport -OutputDirectory $script:outDir
            $html = Get-Content -LiteralPath $report.HtmlPath -Raw
            $html | Should -Match '<title>Health report: '
            $html | Should -Match '<h2>Critical events</h2>'
            $html | Should -Match '&lt;script&gt;alert\(&quot;x&quot;\)&lt;/script&gt; &amp; more'
            $html | Should -Not -Match '<script>'
            $html | Should -Not -Match 'src=|href='
        }

        It 'shows in the HTML which stopped services count and which are for information' {
            Mock -ModuleName ItOpsToolkit Get-ItoStoppedServiceData {
                [pscustomobject]@{ Name = 'VendorAgent'; DisplayName = 'Vendor agent'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 1067 }
                [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
                [pscustomobject]@{ Name = 'VendorUpdater'; DisplayName = 'Vendor updater'; State = 'Stopped'; DelayedAutoStart = $false; TriggerStart = $false; ExitCode = 0 }
            }
            $report = Get-ItoHealthReport -OutputDirectory $script:outDir
            $html = Get-Content -LiteralPath $report.HtmlPath -Raw
            $html | Should -Match '<td>VendorAgent</td><td>Vendor agent</td><td>Stopped</td><td>1067</td><td>Yes: stopped with an error or never started</td>'
            $html | Should -Match '<td>Spooler</td><td>Print Spooler</td><td>Stopped</td><td>0</td><td>Yes: an essential service, stopped</td>'
            $html | Should -Match '<td>VendorUpdater</td><td>Vendor updater</td><td>Stopped</td><td>0</td><td>No: stopped cleanly, for information</td>'
        }

        It 'still returns the report, with a warning, when the files cannot be written' {
            $gone = Join-Path -Path (Join-Path -Path $TestDrive -ChildPath 'removed-after-validation') -ChildPath 'reports'
            Mock -ModuleName ItOpsToolkit Resolve-Path { [pscustomobject]@{ ProviderPath = $gone } }
            $warnings = $null
            $report = Get-ItoHealthReport -OutputDirectory $script:outDir -WarningVariable warnings -WarningAction SilentlyContinue
            $report.Checks.Count | Should -Be 9
            $report.OverallStatus | Should -Be 'OK'
            $report.JsonPath | Should -BeNullOrEmpty
            $report.HtmlPath | Should -BeNullOrEmpty
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "The report could not be written to '*': *The checks are still in the returned report object."
        }

        It 'writes to a folder whose path is 260 characters or longer' {
            # Windows PowerShell 5.1 resolves such a folder to a '\\?\C:\...' path, which Join-Path
            # rejects. On Windows the test folder is created and removed through that form too.
            $prefix = ''
            if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
                $prefix = '\\?\'
            }
            $root = Join-Path -Path $TestDrive -ChildPath 'long'
            $long = $root
            while ($long.Length -lt 270) {
                $long = Join-Path -Path $long -ChildPath 'a-deliberately-long-folder-name'
            }
            $null = [System.IO.Directory]::CreateDirectory($prefix + $long)
            try {
                $warnings = $null
                $report = Get-ItoHealthReport -OutputDirectory $long -WarningVariable warnings -WarningAction SilentlyContinue
                @($warnings).Count | Should -Be 0
                $report.JsonPath | Should -Not -BeNullOrEmpty
                $report.HtmlPath | Should -Not -BeNullOrEmpty
                [System.IO.File]::ReadAllText($report.JsonPath) | ConvertFrom-Json | Select-Object -ExpandProperty OverallStatus | Should -Be 'OK'
            }
            finally {
                [System.IO.Directory]::Delete($prefix + $root, $true)
            }
        }

        It 'writes no files with -WhatIf' {
            $report = Get-ItoHealthReport -OutputDirectory $script:outDir -WhatIf
            $report.JsonPath | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:outDir).Count | Should -Be 0
        }

        It 'validates the output directory' {
            { Get-ItoHealthReport -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'missing') } | Should -Throw
        }
    }
}
