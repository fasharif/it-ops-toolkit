# Thin wrappers around Windows data sources. Each returns plain objects so the evaluation code
# can be tested with mocks on any platform. They are only called on Windows.

function Test-ItoWindowsPlatform {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Get-ItoDiskData {
    [CmdletBinding()]
    param()

    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Drive     = [string]$_.DeviceID
            SizeBytes = [double]$_.Size
            FreeBytes = [double]$_.FreeSpace
        }
    }
}

function Get-ItoOperatingSystemData {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        Caption        = [string]$os.Caption
        Version        = [string]$os.Version
        TotalMemoryKB  = [double]$os.TotalVisibleMemorySize
        FreeMemoryKB   = [double]$os.FreePhysicalMemory
        LastBootUpTime = [datetime]$os.LastBootUpTime
    }
}

function Get-ItoPendingRebootData {
    [CmdletBinding()]
    param()

    $reasons = New-Object -TypeName System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing (Windows features or cumulative update)')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($null -ne $sessionManager -and $null -ne $sessionManager.PendingFileRenameOperations) {
        $reasons.Add('Pending file rename operations (often left by installers)')
    }
    $active = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName' -ErrorAction SilentlyContinue
    $pending = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName' -ErrorAction SilentlyContinue
    if ($null -ne $active -and $null -ne $pending -and $active.ComputerName -ne $pending.ComputerName) {
        $reasons.Add('Computer rename')
    }
    $reasons.ToArray()
}

function Get-ItoStoppedServiceData {
    [CmdletBinding()]
    param()

    Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto' AND State <> 'Running'" -ErrorAction Stop | ForEach-Object {
        $delayed = $false
        if ($null -ne $_.PSObject.Properties['DelayedAutoStart']) {
            $delayed = [bool]$_.DelayedAutoStart
        }
        [pscustomobject]@{
            Name             = [string]$_.Name
            DisplayName      = [string]$_.DisplayName
            State            = [string]$_.State
            DelayedAutoStart = $delayed
            # Trigger-start services stop by design when idle, so they are not faults.
            TriggerStart     = Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}\TriggerInfo' -f $_.Name)
            ExitCode         = [int]$_.ExitCode
        }
    }
}

function Get-ItoCriticalEventData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $Hours
    )

    $filter = @{
        LogName   = @('System', 'Application')
        Level     = 1
        StartTime = (Get-Date).AddHours(-$Hours)
    }
    try {
        Get-WinEvent -FilterHashtable $filter -MaxEvents 200 -ErrorAction Stop | ForEach-Object {
            $message = [string]$_.Message
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = '(no message text)'
            }
            [pscustomobject]@{
                TimeCreated  = [datetime]$_.TimeCreated
                LogName      = [string]$_.LogName
                ProviderName = [string]$_.ProviderName
                Id           = [int]$_.Id
                Message      = ($message -split "`r?`n")[0]
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return
        }
        throw
    }
}

function Get-ItoLastUpdateData {
    [CmdletBinding()]
    param()

    Get-HotFix -ErrorAction Stop |
        Where-Object { $null -ne $_.InstalledOn } |
        Sort-Object -Property InstalledOn -Descending |
        Select-Object -First 1 |
        ForEach-Object {
            [pscustomobject]@{
                HotFixId    = [string]$_.HotFixID
                Description = [string]$_.Description
                InstalledOn = [datetime]$_.InstalledOn
            }
        }
}

function Get-ItoBitLockerData {
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Available = $false
            Reason    = 'The BitLocker PowerShell module is not installed (Windows Home editions do not include it).'
        }
    }
    try {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        [pscustomobject]@{
            Available            = $true
            MountPoint           = [string]$volume.MountPoint
            ProtectionStatus     = [string]$volume.ProtectionStatus
            VolumeStatus         = [string]$volume.VolumeStatus
            EncryptionPercentage = [double]$volume.EncryptionPercentage
        }
    }
    catch {
        [pscustomobject]@{
            Available = $false
            Reason    = "BitLocker status could not be read ($($_.Exception.Message.Trim())). Run the report as an administrator."
        }
    }
}
