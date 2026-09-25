function Get-ItoLockoutEventData {
    <#
    .SYNOPSIS
        Reads "a user account was locked out" events (ID 4740) from a domain controller's Security log.
    .DESCRIPTION
        In event 4740 the first property is the locked account and the second is the caller
        computer, the machine that sent the bad passwords.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ComputerName,

        [Parameter(Mandatory)]
        [int] $Hours,

        [System.Management.Automation.PSCredential]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    $parameters = @{
        ComputerName    = $ComputerName
        FilterHashtable = @{ LogName = 'Security'; Id = 4740; StartTime = (Get-Date).AddHours(-$Hours) }
        ErrorAction     = 'Stop'
    }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $parameters['Credential'] = $Credential
    }
    try {
        Get-WinEvent @parameters | ForEach-Object {
            [pscustomobject]@{
                TimeCreated    = [datetime]$_.TimeCreated
                TargetUserName = [string]$_.Properties[0].Value
                CallerComputer = [string]$_.Properties[1].Value
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
