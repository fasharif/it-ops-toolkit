function Get-ItoLockoutSource {
    <#
    .SYNOPSIS
        Shows whether an account is locked out and which computers caused the lockouts.

    .DESCRIPTION
        Reads the account's lockout state and bad-password counters from the domain's PDC
        emulator, then searches the PDC emulator's Security log for event 4740 ("A user account
        was locked out"). Every lockout in the domain is recorded there, and each event names the
        caller computer: the machine that sent the bad passwords.

        On the caller computer, the usual causes are a phone or mail client still using an old
        password, a mapped drive or a saved entry in Credential Manager, a scheduled task or
        service running as the user, or a disconnected remote desktop session.

        The command only reads. Unlock the account with Unlock-ADAccount once the cause is fixed,
        or it will lock again.

        Reading the Security log needs membership of Event Log Readers (or Domain Admins) on the
        domain controllers, and the Remote Event Log Management firewall rule. Without them, the
        account state is still returned and the Warning property says what failed.

    .PARAMETER Identity
        The account's sAMAccountName. Accepts pipeline input.

    .PARAMETER Hours
        How many hours of Security log to search, from 1 to 720. The default is 24.

    .PARAMETER Server
        Domain controller used to find the domain and its PDC emulator. Defaults to the
        computer's domain. The account itself is always read from the PDC emulator, because
        the bad-password counters are not replicated and the PDC emulator sees every failure.

    .PARAMETER Credential
        Credential for the directory and event log queries. Defaults to the current user.

    .EXAMPLE
        Get-ItoLockoutSource -Identity sara.ali

        Shows whether sara.ali is locked out, the computers that caused lockouts in the last
        24 hours, and advice on where to look first.

    .EXAMPLE
        Get-ItoLockoutSource sara.ali -Hours 72 | Select-Object -ExpandProperty Sources

        Lists the caller computers for the last three days, most lockouts first.

    .OUTPUTS
        ItOpsToolkit.LockoutReport

    .NOTES
        Requires the ActiveDirectory module (RSAT). See docs/kb/01-account-locked-out.md.

    .LINK
        New-ItoRandomPassword
    #>
    [CmdletBinding()]
    [OutputType('ItOpsToolkit.LockoutReport')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName')]
        [ValidatePattern('^[A-Za-z0-9._-]{1,20}$')]
        [string] $Identity,

        [ValidateRange(1, 720)]
        [int] $Hours = 24,

        [ValidateNotNullOrEmpty()]
        [string] $Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        Assert-ItoActiveDirectory
        $domainParameters = Get-ItoAdParameter -Server $Server -Credential $Credential
        $pdc = [string](Get-ADDomain @domainParameters -ErrorAction Stop).PDCEmulator
        $pdcParameters = Get-ItoAdParameter -Server $pdc -Credential $Credential
    }

    process {
        $filter = '(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))' -f (ConvertTo-ItoLdapFilterValue -Value $Identity)
        $properties = @('LockedOut', 'AccountLockoutTime', 'BadLogonCount', 'LastBadPasswordAttempt', 'PasswordLastSet')
        $users = @(Get-ADUser -LDAPFilter $filter -Properties $properties @pdcParameters)
        if ($users.Count -eq 0) {
            Write-Error -Message "No user account named '$Identity' was found." -Category ObjectNotFound -TargetObject $Identity
            return
        }
        $user = $users[0]

        $events = @()
        $warning = $null
        try {
            $events = @(Get-ItoLockoutEventData -ComputerName $pdc -Hours $Hours -Credential $Credential |
                    Where-Object { [string]::Equals($_.TargetUserName, $Identity, [System.StringComparison]::OrdinalIgnoreCase) } |
                    Sort-Object -Property TimeCreated -Descending)
        }
        catch {
            $warning = ('The Security log on {0} could not be read: {1} Reading it needs membership of Event Log Readers on the domain controllers and the Remote Event Log Management firewall rule.' -f $pdc, $_.Exception.Message.Trim())
            Write-Warning $warning
        }

        $sources = @($events | Group-Object -Property CallerComputer | ForEach-Object {
                $latest = ($_.Group | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1).TimeCreated
                [pscustomobject]@{
                    CallerComputer = $_.Name
                    Lockouts       = $_.Count
                    LastLockout    = $latest
                }
            } | Sort-Object -Property @{ Expression = 'Lockouts'; Descending = $true }, @{ Expression = 'LastLockout'; Descending = $true })

        $locked = [bool]$user.LockedOut
        if ($sources.Count -gt 0) {
            $top = $sources[0].CallerComputer
            if ([string]::IsNullOrEmpty($top)) {
                $advice = 'The lockout events do not name a caller computer. That usually means the bad passwords came through a service such as Exchange, ADFS or a VPN server; check that server''s logs.'
            }
            else {
                $advice = ('Start with {0}: look for a phone or mail client with an old password, saved entries in Credential Manager (cmdkey /list), mapped drives, scheduled tasks or services running as {1}, and disconnected remote desktop sessions. Unlock the account only after fixing the cause.' -f $top, $Identity)
            }
        }
        elseif ($locked) {
            $advice = "The account is locked out, but no lockout event for it was found in the last $Hours hours on $pdc. Search a longer period with -Hours, or check whether auditing of account lockouts is enabled."
        }
        else {
            $advice = "The account is not locked out. If the user still cannot sign in, check the password expiry, the account expiry and whether the account is disabled."
        }

        [pscustomobject]@{
            PSTypeName             = 'ItOpsToolkit.LockoutReport'
            SamAccountName         = $Identity
            LockedOut              = $locked
            AccountLockoutTime     = $user.AccountLockoutTime
            BadLogonCount          = $user.BadLogonCount
            LastBadPasswordAttempt = $user.LastBadPasswordAttempt
            PasswordLastSet        = $user.PasswordLastSet
            PdcEmulator            = $pdc
            Sources                = $sources
            Events                 = $events
            Advice                 = $advice
            Warning                = $warning
        }
    }
}
