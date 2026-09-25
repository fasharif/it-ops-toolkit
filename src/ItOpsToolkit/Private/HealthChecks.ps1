# Pure evaluation code for Get-ItoHealthReport: data in, check objects out.

function Get-ItoDefaultHealthThreshold {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        DiskFreePercentWarning    = 20
        DiskFreePercentCritical   = 10
        MemoryUsedPercentWarning  = 85
        MemoryUsedPercentCritical = 95
        UptimeDaysWarning         = 14
        UptimeDaysCritical        = 30
        StoppedServicesWarning    = 1
        StoppedServicesCritical   = 5
        CriticalEventsWarning     = 1
        CriticalEventsCritical    = 5
        UpdateAgeDaysWarning      = 35
        UpdateAgeDaysCritical     = 60
        BitLockerOffStatus        = 'Warning'
        IgnoredServices           = @('clr_optimization_*', 'edgeupdate*', 'gupdate*', 'GoogleUpdater*', 'MapsBroker', 'RemoteRegistry', 'sppsvc', 'tiledatamodelsvc')
    }
}

function Read-ItoHealthThreshold {
    <#
    .SYNOPSIS
        Returns the default thresholds, overridden by any values in an optional JSON file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path
    )

    $thresholds = Get-ItoDefaultHealthThreshold
    if ([string]::IsNullOrEmpty($Path)) {
        return $thresholds
    }

    try {
        $data = ConvertTo-ItoHashtable -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Could not read the threshold file '$Path': $($_.Exception.Message)"
    }
    if ($data -isnot [hashtable]) {
        throw "The threshold file '$Path' must contain a JSON object."
    }

    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($key in @($data.Keys)) {
        if ($key -like '$*') {
            continue
        }
        if (-not $thresholds.ContainsKey($key)) {
            $problems.Add("Unknown threshold '$key'.")
            continue
        }
        $value = $data[$key]
        switch -Wildcard ($key) {
            'BitLockerOffStatus' {
                if (@('OK', 'Warning', 'Critical') -notcontains [string]$value) {
                    $problems.Add("'$key' must be OK, Warning or Critical.")
                }
                else {
                    $thresholds['BitLockerOffStatus'] = [string]$value
                }
            }
            'IgnoredServices' {
                $thresholds['IgnoredServices'] = [string[]]@($value)
            }
            default {
                if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) {
                    $problems.Add("'$key' must be a number.")
                }
                elseif ([double]$value -lt 0) {
                    $problems.Add("'$key' cannot be negative.")
                }
                else {
                    # Hashtable keys are case-insensitive, so 'diskFreePercentWarning' updates DiskFreePercentWarning.
                    $thresholds[$key] = [double]$value
                }
            }
        }
    }

    if ($thresholds.DiskFreePercentCritical -gt $thresholds.DiskFreePercentWarning) {
        $problems.Add('DiskFreePercentCritical must not be greater than DiskFreePercentWarning (less free space is worse).')
    }
    foreach ($pair in @('MemoryUsedPercent', 'UptimeDays', 'StoppedServices', 'CriticalEvents', 'UpdateAgeDays')) {
        if ($thresholds[$pair + 'Critical'] -lt $thresholds[$pair + 'Warning']) {
            $problems.Add("${pair}Critical must not be lower than ${pair}Warning.")
        }
    }

    if ($problems.Count -gt 0) {
        throw ("The threshold file '{0}' is not valid:{1} - {2}" -f $Path, [Environment]::NewLine, ($problems -join ([Environment]::NewLine + ' - ')))
    }
    $thresholds
}

function Format-ItoInvariant {
    <#
    .SYNOPSIS
        String formatting with the invariant culture, so reports read the same on every locale.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Format,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object[]] $Arguments
    )

    [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $Format, $Arguments)
}

function Get-ItoThresholdStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double] $Value,

        [Parameter(Mandatory)]
        [double] $Warning,

        [Parameter(Mandatory)]
        [double] $Critical,

        [switch] $LowerIsWorse
    )

    if ($LowerIsWorse) {
        if ($Value -lt $Critical) { return 'Critical' }
        if ($Value -lt $Warning) { return 'Warning' }
        return 'OK'
    }
    if ($Value -ge $Critical) { return 'Critical' }
    if ($Value -ge $Warning) { return 'Warning' }
    'OK'
}

function ConvertTo-ItoHealthCheck {
    [CmdletBinding()]
    [OutputType('ItOpsToolkit.HealthCheck')]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Category,

        [Parameter(Mandatory)]
        [ValidateSet('OK', 'Warning', 'Critical', 'Unknown')]
        [string] $Status,

        [AllowEmptyString()]
        [string] $Value = '',

        [AllowEmptyString()]
        [string] $Threshold = '',

        [AllowEmptyString()]
        [string] $Detail = '',

        [AllowNull()]
        [object] $Data = $null
    )

    [pscustomobject]@{
        PSTypeName = 'ItOpsToolkit.HealthCheck'
        Name       = $Name
        Category   = $Category
        Status     = $Status
        Value      = $Value
        Threshold  = $Threshold
        Detail     = $Detail
        Data       = $Data
    }
}

function Get-ItoDiskCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Disks,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $threshold = Format-ItoInvariant -Format 'Warning below {0}% free, critical below {1}% free' -Arguments $Thresholds.DiskFreePercentWarning, $Thresholds.DiskFreePercentCritical
    $fixed = @($Disks | Where-Object { $_.SizeBytes -gt 0 })
    if ($fixed.Count -eq 0) {
        return ConvertTo-ItoHealthCheck -Name 'Disk space' -Category 'Storage' -Status 'Unknown' -Threshold $threshold -Detail 'No fixed disks were reported.'
    }
    foreach ($disk in $fixed) {
        $freePercent = [math]::Round($disk.FreeBytes / $disk.SizeBytes * 100, 1)
        $status = Get-ItoThresholdStatus -Value $freePercent -Warning $Thresholds.DiskFreePercentWarning -Critical $Thresholds.DiskFreePercentCritical -LowerIsWorse
        $detail = ''
        if ($status -ne 'OK') {
            $detail = 'Free up space: empty the Recycle Bin, run Disk Clean-up (cleanmgr /sageset), and check large folders such as Downloads and the Outlook OST file.'
        }
        ConvertTo-ItoHealthCheck -Name ('Disk space {0}' -f $disk.Drive) -Category 'Storage' -Status $status -Threshold $threshold -Detail $detail `
            -Value (Format-ItoInvariant -Format '{0:0.0}% free ({1:0.0} GB of {2:0.0} GB)' -Arguments $freePercent, ($disk.FreeBytes / 1GB), ($disk.SizeBytes / 1GB)) `
            -Data ([pscustomobject]@{ Drive = $disk.Drive; FreePercent = $freePercent; FreeBytes = $disk.FreeBytes; SizeBytes = $disk.SizeBytes })
    }
}

function Get-ItoMemoryCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $OperatingSystem,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $threshold = Format-ItoInvariant -Format 'Warning at {0}% used, critical at {1}% used' -Arguments $Thresholds.MemoryUsedPercentWarning, $Thresholds.MemoryUsedPercentCritical
    if ($OperatingSystem.TotalMemoryKB -le 0) {
        return ConvertTo-ItoHealthCheck -Name 'Memory' -Category 'Performance' -Status 'Unknown' -Threshold $threshold -Detail 'Total memory was reported as zero.'
    }
    $usedPercent = [math]::Round(($OperatingSystem.TotalMemoryKB - $OperatingSystem.FreeMemoryKB) / $OperatingSystem.TotalMemoryKB * 100, 1)
    $status = Get-ItoThresholdStatus -Value $usedPercent -Warning $Thresholds.MemoryUsedPercentWarning -Critical $Thresholds.MemoryUsedPercentCritical
    $detail = ''
    if ($status -ne 'OK') {
        $detail = 'Open Task Manager, sort by Memory, and close or restart the heaviest applications. Repeated high use points to a memory upgrade.'
    }
    ConvertTo-ItoHealthCheck -Name 'Memory' -Category 'Performance' -Status $status -Threshold $threshold -Detail $detail `
        -Value (Format-ItoInvariant -Format '{0:0.0}% used ({1:0.0} GB free of {2:0.0} GB)' -Arguments $usedPercent, ($OperatingSystem.FreeMemoryKB / 1MB), ($OperatingSystem.TotalMemoryKB / 1MB)) `
        -Data ([pscustomobject]@{ UsedPercent = $usedPercent; TotalKB = $OperatingSystem.TotalMemoryKB; FreeKB = $OperatingSystem.FreeMemoryKB })
}

function Get-ItoUptimeCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime] $LastBootUpTime,

        [Parameter(Mandatory)]
        [datetime] $Now,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $days = [math]::Round(($Now - $LastBootUpTime).TotalDays, 1)
    $status = Get-ItoThresholdStatus -Value $days -Warning $Thresholds.UptimeDaysWarning -Critical $Thresholds.UptimeDaysCritical
    $detail = ''
    if ($status -ne 'OK') {
        $detail = 'Restart the computer: long uptimes delay updates and let memory leaks build up. Fast Startup means "Shut down" does not reset uptime; use Restart.'
    }
    ConvertTo-ItoHealthCheck -Name 'Uptime' -Category 'Maintenance' -Status $status `
        -Threshold (Format-ItoInvariant -Format 'Warning at {0} days, critical at {1} days' -Arguments $Thresholds.UptimeDaysWarning, $Thresholds.UptimeDaysCritical) `
        -Value (Format-ItoInvariant -Format '{0:0.0} days (last boot {1:yyyy-MM-dd HH:mm})' -Arguments $days, $LastBootUpTime) -Detail $detail `
        -Data ([pscustomobject]@{ UptimeDays = $days; LastBootUpTime = $LastBootUpTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) })
}

function Get-ItoPendingRebootCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Reasons
    )

    if ($Reasons.Count -eq 0) {
        return ConvertTo-ItoHealthCheck -Name 'Pending reboot' -Category 'Maintenance' -Status 'OK' -Value 'No reboot pending' -Threshold 'Warning when a reboot is pending' -Data ([pscustomobject]@{ Reasons = @() })
    }
    ConvertTo-ItoHealthCheck -Name 'Pending reboot' -Category 'Maintenance' -Status 'Warning' -Value ('Reboot pending: {0}' -f ($Reasons -join '; ')) `
        -Threshold 'Warning when a reboot is pending' -Detail 'Restart the computer to finish installing updates or software.' -Data ([pscustomobject]@{ Reasons = $Reasons })
}

function Get-ItoServiceCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Services,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $ignored = @($Thresholds.IgnoredServices)
    $stopped = @($Services | Where-Object {
            $service = $_
            -not $service.TriggerStart -and -not ($ignored | Where-Object { $service.Name -like $_ })
        } | Sort-Object -Property Name)
    $status = Get-ItoThresholdStatus -Value $stopped.Count -Warning $Thresholds.StoppedServicesWarning -Critical $Thresholds.StoppedServicesCritical
    $value = 'All automatic services are running'
    $detail = ''
    if ($stopped.Count -gt 0) {
        $value = '{0} automatic service(s) stopped: {1}' -f $stopped.Count, (($stopped | ForEach-Object { $_.Name }) -join ', ')
        $detail = 'Check each service in services.msc and the System event log (source Service Control Manager, event 7000-7043) for the reason it stopped.'
    }
    ConvertTo-ItoHealthCheck -Name 'Automatic services' -Category 'Services' -Status $status -Value $value -Detail $detail `
        -Threshold (Format-ItoInvariant -Format 'Warning at {0} stopped, critical at {1} stopped (trigger-start and ignored services excluded)' -Arguments $Thresholds.StoppedServicesWarning, $Thresholds.StoppedServicesCritical) `
        -Data @($stopped | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; State = $_.State; ExitCode = $_.ExitCode } })
}

function Get-ItoEventCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Events,

        [Parameter(Mandatory)]
        [int] $Hours,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $sorted = @($Events | Sort-Object -Property TimeCreated -Descending)
    $status = Get-ItoThresholdStatus -Value $sorted.Count -Warning $Thresholds.CriticalEventsWarning -Critical $Thresholds.CriticalEventsCritical
    $value = 'No critical events in the last {0} hours' -f $Hours
    $detail = ''
    if ($sorted.Count -gt 0) {
        $top = $sorted | Group-Object -Property ProviderName, Id | Sort-Object -Property Count -Descending | Select-Object -First 3 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }
        $value = '{0} critical event(s) in the last {1} hours' -f $sorted.Count, $Hours
        $detail = 'Most frequent: {0}. Kernel-Power 41 means the computer lost power or was forced off without a clean shutdown.' -f ($top -join '; ')
    }
    $eventData = foreach ($entry in @($sorted | Select-Object -First 20)) {
        [pscustomobject]@{
            TimeCreated  = ([datetime]$entry.TimeCreated).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            LogName      = $entry.LogName
            ProviderName = $entry.ProviderName
            Id           = $entry.Id
            Message      = $entry.Message
        }
    }
    ConvertTo-ItoHealthCheck -Name 'Critical events' -Category 'Reliability' -Status $status -Value $value -Detail $detail `
        -Threshold (Format-ItoInvariant -Format 'Warning at {0} event(s), critical at {1} (System and Application logs, level Critical)' -Arguments $Thresholds.CriticalEventsWarning, $Thresholds.CriticalEventsCritical) `
        -Data @($eventData)
}

function Get-ItoUpdateCheck {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $LastUpdate,

        [Parameter(Mandatory)]
        [datetime] $Now,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $threshold = Format-ItoInvariant -Format 'Warning after {0} days, critical after {1} days' -Arguments $Thresholds.UpdateAgeDaysWarning, $Thresholds.UpdateAgeDaysCritical
    if ($null -eq $LastUpdate) {
        return ConvertTo-ItoHealthCheck -Name 'Last update installed' -Category 'Security' -Status 'Unknown' -Threshold $threshold -Detail 'No installed updates with an installation date were found.'
    }
    $installedOn = [datetime]$LastUpdate.InstalledOn
    $days = [math]::Floor(($Now.Date - $installedOn.Date).TotalDays)
    $status = Get-ItoThresholdStatus -Value $days -Warning $Thresholds.UpdateAgeDaysWarning -Critical $Thresholds.UpdateAgeDaysCritical
    $detail = ''
    if ($status -ne 'OK') {
        $detail = 'Open Settings > Windows Update and install pending updates. If updates fail, check the WindowsUpdateClient events and free disk space.'
    }
    ConvertTo-ItoHealthCheck -Name 'Last update installed' -Category 'Security' -Status $status -Threshold $threshold -Detail $detail `
        -Value (Format-ItoInvariant -Format '{0} installed {1:yyyy-MM-dd} ({2} days ago)' -Arguments $LastUpdate.HotFixId, $installedOn, $days) `
        -Data ([pscustomobject]@{ HotFixId = $LastUpdate.HotFixId; InstalledOn = $installedOn.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture); AgeDays = $days })
}

function Get-ItoBitLockerCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $BitLocker,

        [Parameter(Mandatory)]
        [hashtable] $Thresholds
    )

    $threshold = 'OS drive protection should be On (status when Off: {0})' -f $Thresholds.BitLockerOffStatus
    if (-not $BitLocker.Available) {
        return ConvertTo-ItoHealthCheck -Name 'BitLocker' -Category 'Security' -Status 'Unknown' -Threshold $threshold -Detail $BitLocker.Reason
    }
    if ($BitLocker.ProtectionStatus -eq 'On') {
        return ConvertTo-ItoHealthCheck -Name 'BitLocker' -Category 'Security' -Status 'OK' -Threshold $threshold `
            -Value (Format-ItoInvariant -Format 'Protection on for {0} ({1}, {2:0}% encrypted)' -Arguments $BitLocker.MountPoint, $BitLocker.VolumeStatus, $BitLocker.EncryptionPercentage)
    }
    ConvertTo-ItoHealthCheck -Name 'BitLocker' -Category 'Security' -Status $Thresholds.BitLockerOffStatus -Threshold $threshold `
        -Value (Format-ItoInvariant -Format 'Protection {0} for {1} ({2}, {3:0}% encrypted)' -Arguments $BitLocker.ProtectionStatus, $BitLocker.MountPoint, $BitLocker.VolumeStatus, $BitLocker.EncryptionPercentage) `
        -Detail 'Protection is suspended or the drive is not encrypted. Resume it with Resume-BitLocker, or escalate to the endpoint team if the device should be encrypted.'
}

function Get-ItoOverallStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Checks
    )

    $rank = @{ OK = 0; Unknown = 1; Warning = 2; Critical = 3 }
    $worst = 'OK'
    foreach ($check in $Checks) {
        if ($rank[$check.Status] -gt $rank[$worst]) {
            $worst = $check.Status
        }
    }
    $worst
}
