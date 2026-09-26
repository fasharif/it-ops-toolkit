function Get-ItoHealthReport {
    <#
    .SYNOPSIS
        Checks the health of the local Windows computer and writes the result as HTML and JSON.

    .DESCRIPTION
        Collects and grades eight areas against clear thresholds:

        - Disk space: free space on each fixed drive (warning below 20%, critical below 10%).
        - Memory: physical memory in use (warning at 85%, critical at 95%).
        - Uptime: days since the last boot (warning at 14 days, critical at 30).
        - Pending reboot: Windows Update, component servicing, file rename operations or a
          computer rename waiting for a restart (warning).
        - Automatic services: services set to start automatically that stopped with an error or
          never started (warning at 1, critical at 5). Not counted: services that stopped
          cleanly (exit code 0, listed for information), trigger-start services, a list of
          services that stop by design, and delayed-start services in the first 10 minutes
          after boot.
        - Critical events: level 1 events in the System and Application logs in the last
          24 hours (warning at 1, critical at 5).
        - Last update installed: days since the newest hotfix was installed (warning after 35
          days, critical after 60).
        - BitLocker: protection status of the operating system drive, where the BitLocker
          module is available and the report runs elevated.

        Each check is OK, Warning, Critical or Unknown. Unknown means the data could not be read;
        the Detail says why. A failing data source never stops the rest of the report.

        The report runs on the computer being checked. To check a remote computer, run it there,
        for example with Invoke-Command.

    .PARAMETER OutputDirectory
        Folder where health-<computer>-<timestamp>.html and .json are written. Without it, the
        report object is returned and nothing is written.

    .PARAMETER ThresholdPath
        JSON file that overrides some or all thresholds. See config/health-thresholds.example.json.

    .PARAMETER EventWindowHours
        How many hours of event log history to search for critical events, from 1 to 720. The
        default is 24.

    .EXAMPLE
        Get-ItoHealthReport | Select-Object -ExpandProperty Checks | Format-Table Name, Status, Value

        Shows the checks in the console.

    .EXAMPLE
        Get-ItoHealthReport -OutputDirectory C:\Temp\Reports

        Writes the HTML and JSON files and returns the report, including the file paths.

    .EXAMPLE
        Invoke-Command -ComputerName PC-0142 -ScriptBlock { Import-Module ItOpsToolkit; Get-ItoHealthReport }

        Runs the report on a remote computer, where the module is installed.

    .OUTPUTS
        ItOpsToolkit.HealthReport

    .NOTES
        Windows only. BitLocker status needs an elevated session. On Linux use linux/health-report.sh.

    .LINK
        Test-ItoNetwork
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('ItOpsToolkit.HealthReport')]
    param(
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $OutputDirectory,

        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string] $ThresholdPath,

        [ValidateRange(1, 720)]
        [int] $EventWindowHours = 24
    )

    if (-not (Test-ItoWindowsPlatform)) {
        throw 'Get-ItoHealthReport reads Windows data sources (CIM, the registry and the event log), so it runs on Windows only. On Linux use linux/health-report.sh.'
    }

    $thresholds = Read-ItoHealthThreshold -Path $ThresholdPath
    $now = Get-Date
    $checks = New-Object -TypeName System.Collections.Generic.List[object]
    # Each collector runs in its own scope; the service check reuses the boot time through this table.
    $shared = @{ LastBootUpTime = $null }

    $collectors = @(
        @{ Name = 'Disk space'; Category = 'Storage'; Script = { Get-ItoDiskCheck -Disks @(Get-ItoDiskData) -Thresholds $thresholds } }
        @{ Name = 'Memory and uptime'; Category = 'Performance'; Script = {
                $os = Get-ItoOperatingSystemData
                $shared.LastBootUpTime = $os.LastBootUpTime
                Get-ItoMemoryCheck -OperatingSystem $os -Thresholds $thresholds
                Get-ItoUptimeCheck -LastBootUpTime $os.LastBootUpTime -Now $now -Thresholds $thresholds
            }
        }
        @{ Name = 'Pending reboot'; Category = 'Maintenance'; Script = { Get-ItoPendingRebootCheck -Reasons @(Get-ItoPendingRebootData) } }
        @{ Name = 'Automatic services'; Category = 'Services'; Script = {
                Get-ItoServiceCheck -Services @(Get-ItoStoppedServiceData) -Thresholds $thresholds -LastBootUpTime $shared.LastBootUpTime -Now $now
            }
        }
        @{ Name = 'Critical events'; Category = 'Reliability'; Script = { Get-ItoEventCheck -Events @(Get-ItoCriticalEventData -Hours $EventWindowHours) -Hours $EventWindowHours -Thresholds $thresholds } }
        @{ Name = 'Last update installed'; Category = 'Security'; Script = { Get-ItoUpdateCheck -LastUpdate (Get-ItoLastUpdateData) -Now $now -Thresholds $thresholds } }
        @{ Name = 'BitLocker'; Category = 'Security'; Script = { Get-ItoBitLockerCheck -BitLocker (Get-ItoBitLockerData) -Thresholds $thresholds } }
    )

    foreach ($collector in $collectors) {
        Write-Verbose "Checking $($collector.Name)."
        try {
            foreach ($check in @(& $collector.Script)) {
                $checks.Add($check)
            }
        }
        catch {
            $checks.Add((ConvertTo-ItoHealthCheck -Name $collector.Name -Category $collector.Category -Status 'Unknown' -Detail "The data could not be read: $($_.Exception.Message.Trim())"))
        }
    }

    $moduleVersion = '0.0.0'
    if ($null -ne $MyInvocation.MyCommand.Module) {
        $moduleVersion = $MyInvocation.MyCommand.Module.Version.ToString()
    }
    $report = [pscustomobject]@{
        PSTypeName       = 'ItOpsToolkit.HealthReport'
        ComputerName     = [System.Environment]::MachineName
        GeneratedAtUtc   = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        ToolkitVersion   = $moduleVersion
        EventWindowHours = $EventWindowHours
        OverallStatus    = Get-ItoOverallStatus -Checks $checks.ToArray()
        Checks           = $checks.ToArray()
        Thresholds       = $thresholds
        JsonPath         = $null
        HtmlPath         = $null
    }

    if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
        $folder = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
        $safeName = $report.ComputerName -replace '[^A-Za-z0-9-]', '_'
        $stamp = $now.ToUniversalTime().ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $baseName = Join-Path -Path $folder -ChildPath ('health-{0}-{1}' -f $safeName, $stamp)
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        if ($PSCmdlet.ShouldProcess("$baseName.json", 'Write health report JSON')) {
            $json = $report | Select-Object -Property ComputerName, GeneratedAtUtc, ToolkitVersion, EventWindowHours, OverallStatus, Checks, Thresholds |
                ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText("$baseName.json", $json, $utf8)
            $report.JsonPath = "$baseName.json"
        }
        if ($PSCmdlet.ShouldProcess("$baseName.html", 'Write health report HTML')) {
            [System.IO.File]::WriteAllText("$baseName.html", (ConvertTo-ItoHealthHtml -Report $report), $utf8)
            $report.HtmlPath = "$baseName.html"
        }
    }

    $report
}
