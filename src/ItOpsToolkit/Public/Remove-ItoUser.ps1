function Remove-ItoUser {
    <#
    .SYNOPSIS
        Offboards a leaver: disables the account, records the ticket, exports and removes group
        memberships and moves the account to the disabled users OU.

    .DESCRIPTION
        Remove-ItoUser does not delete the account. It makes the account unusable and keeps an
        audit trail, so access can be restored or reviewed later:

        1. Exports the account's group memberships to a CSV file in -AuditPath, before anything
           is removed. If the export fails, nothing else is changed.
        2. Disables the account.
        3. Records the ticket number and date in the description, keeping the old description.
        4. Removes the account from every group except its primary group (usually Domain Users,
           which Active Directory does not allow you to remove).
        5. Moves the account to the disabled users OU.

        Every step checks the current state first, so running the command again for the same
        leaver changes nothing and reports AlreadyOffboarded.

        ConfirmImpact is High, so PowerShell asks before each step. If you answer No to the
        audit export, the group memberships are not removed either: memberships are never removed
        without a record. The other steps you accept still run, and the result says what was not
        done. Run the command again to finish.

        The Status of each result is Offboarded, AlreadyOffboarded, Planned (-WhatIf), Partial
        (you declined some steps), Declined (you declined every step) or Failed.

    .PARAMETER Identity
        The leaver's sAMAccountName. Accepts pipeline input, including objects with a
        SamAccountName property such as the output of Get-ADUser.

    .PARAMETER TicketNumber
        The service desk ticket that authorised the offboarding, for example INC0012345 or REQ-2041.

    .PARAMETER AuditPath
        Folder for the group membership export files.

    .PARAMETER ConfigPath
        Path to the JSON configuration. Its disabledOu setting is the target OU.

    .PARAMETER DisabledOu
        Distinguished name of the target OU. Use instead of -ConfigPath.

    .PARAMETER Server
        Domain controller or domain to use. Defaults to the computer's domain.

    .PARAMETER Credential
        Credential for the directory operations. Defaults to the current user.

    .EXAMPLE
        Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath .\onboarding.json -AuditPath .\audit -WhatIf

        Lists every change that would be made, without making any.

    .EXAMPLE
        Import-Csv .\leavers.csv | Remove-ItoUser -TicketNumber 'REQ-2041' -ConfigPath .\onboarding.json -AuditPath \\fs01\Audit -Confirm:$false

        Offboards every account in the SamAccountName column of leavers.csv without prompting.

    .INPUTS
        System.String

    .OUTPUTS
        ItOpsToolkit.OffboardingResult

    .NOTES
        Requires the ActiveDirectory module (RSAT). ConfirmImpact is High, so PowerShell asks for
        confirmation unless you pass -Confirm:$false.

    .LINK
        New-ItoUser
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Config')]
    [OutputType('ItOpsToolkit.OffboardingResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName')]
        [ValidatePattern('^[A-Za-z0-9._-]{1,20}$')]
        [string] $Identity,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]{2,10}-?[0-9]{1,12}$')]
        [string] $TicketNumber,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $AuditPath,

        [Parameter(Mandatory, ParameterSetName = 'Config')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string] $ConfigPath,

        [Parameter(Mandatory, ParameterSetName = 'Ou')]
        [ValidatePattern('^(?:(?:OU|CN)=[^,=]+,)+(?:DC=[A-Za-z0-9-]+,)*DC=[A-Za-z0-9-]+$')]
        [string] $DisabledOu,

        [ValidateNotNullOrEmpty()]
        [string] $Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        Assert-ItoActiveDirectory
        if ($PSCmdlet.ParameterSetName -eq 'Config') {
            $DisabledOu = (Read-ItoOnboardingConfig -Path $ConfigPath).DisabledOu
        }
        $adParameters = Get-ItoAdParameter -Server $Server -Credential $Credential
        $ticket = $TicketNumber.ToUpperInvariant()
        $auditFolder = (Resolve-Path -LiteralPath $AuditPath).ProviderPath
    }

    process {
        $result = [pscustomobject]@{
            PSTypeName        = 'ItOpsToolkit.OffboardingResult'
            SamAccountName    = $Identity
            TicketNumber      = $ticket
            Status            = 'Pending'
            Actions           = @()
            GroupsRemoved     = @()
            AuditFile         = $null
            DistinguishedName = $null
            Message           = ''
        }
        $actions = New-Object -TypeName System.Collections.Generic.List[string]
        $removed = New-Object -TypeName System.Collections.Generic.List[string]
        # Steps that were not carried out: planned under -WhatIf, or answered No at a prompt.
        $notDone = New-Object -TypeName System.Collections.Generic.List[string]
        $whatIf = [bool]$WhatIfPreference

        try {
            $filter = '(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))' -f (ConvertTo-ItoLdapFilterValue -Value $Identity)
            $users = @(Get-ADUser -LDAPFilter $filter -Properties 'MemberOf', 'Description', 'Enabled' @adParameters)
            if ($users.Count -eq 0) {
                $result.Status = 'Failed'
                $result.Message = "No user account named '$Identity' was found."
                Write-Error -Message ('Offboarding {0} failed: {1}' -f $Identity, $result.Message) -Category ObjectNotFound -TargetObject $Identity
                $result
                return
            }
            $user = $users[0]
            $dn = [string]$user.DistinguishedName
            $groups = @($user.MemberOf | Where-Object { $_ })
            $result.DistinguishedName = $dn
            $utcNow = (Get-Date).ToUniversalTime()
            $stamp = $utcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)

            # 1. Audit export first: group removal must never happen without a record of what was removed.
            $auditWritten = $groups.Count -eq 0
            if ($groups.Count -gt 0) {
                $auditFile = Join-Path -Path $auditFolder -ChildPath ('{0}_{1}_{2}_groups.csv' -f $Identity, $ticket, $stamp)
                if ($PSCmdlet.ShouldProcess($auditFile, "Export $($groups.Count) group membership(s) of $Identity")) {
                    Export-ItoGroupAudit -Path $auditFile -SamAccountName $Identity -TicketNumber $ticket -Groups $groups -ExportedAtUtc $utcNow
                    $result.AuditFile = $auditFile
                    $actions.Add('Exported group memberships')
                    $auditWritten = $true
                }
                else {
                    $notDone.Add('export group memberships')
                }
            }

            # 2. Disable.
            if ($user.Enabled) {
                if ($PSCmdlet.ShouldProcess($dn, 'Disable account')) {
                    Disable-ADAccount -Identity $dn @adParameters -ErrorAction Stop
                    $actions.Add('Disabled account')
                }
                else {
                    $notDone.Add('disable the account')
                }
            }

            # 3. Ticket in the description (only once, however often the command runs).
            $oldDescription = [string]$user.Description
            if ($oldDescription -notmatch [regex]::Escape($ticket)) {
                $newDescription = 'Offboarded {0} ticket {1}' -f $utcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture), $ticket
                if (-not [string]::IsNullOrWhiteSpace($oldDescription)) {
                    $newDescription = '{0} | previous: {1}' -f $newDescription, $oldDescription
                }
                if ($newDescription.Length -gt 1024) {
                    $newDescription = $newDescription.Substring(0, 1024)
                }
                if ($PSCmdlet.ShouldProcess($dn, "Set description to '$newDescription'")) {
                    Set-ADUser -Identity $dn -Description $newDescription @adParameters -ErrorAction Stop
                    $actions.Add('Recorded ticket in description')
                }
                else {
                    $notDone.Add('record the ticket in the description')
                }
            }

            # 4. Remove group memberships, but only once they are on record. Under -WhatIf the
            # removals are still listed, so the preview shows the whole plan.
            if ($auditWritten -or $whatIf) {
                $declinedGroups = 0
                foreach ($group in $groups) {
                    if ($PSCmdlet.ShouldProcess($group, "Remove $Identity from group")) {
                        Remove-ADGroupMember -Identity $group -Members $dn @adParameters -Confirm:$false -ErrorAction Stop
                        $removed.Add($group)
                    }
                    else {
                        $declinedGroups++
                    }
                }
                if ($declinedGroups -gt 0) {
                    $notDone.Add(('remove {0} group membership(s)' -f $declinedGroups))
                }
            }
            else {
                $notDone.Add(('remove {0} group membership(s), skipped because the audit export was declined' -f $groups.Count))
            }
            if ($removed.Count -gt 0) {
                $actions.Add(('Removed from {0} group(s)' -f $removed.Count))
            }

            # 5. Move to the disabled users OU.
            $dnParts = Split-ItoDistinguishedName -DistinguishedName $dn
            if (-not [string]::Equals($dnParts.Parent, $DisabledOu, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($PSCmdlet.ShouldProcess($dn, "Move to $DisabledOu")) {
                    Move-ADObject -Identity $dn -TargetPath $DisabledOu @adParameters -ErrorAction Stop
                    $result.DistinguishedName = '{0},{1}' -f $dnParts.Rdn, $DisabledOu
                    $actions.Add('Moved to disabled users OU')
                }
                else {
                    $notDone.Add('move the account to the disabled users OU')
                }
            }

            if ($notDone.Count -eq 0 -and $actions.Count -eq 0) {
                $result.Status = 'AlreadyOffboarded'
                $result.Message = "$Identity is already offboarded. No changes were needed."
            }
            elseif ($notDone.Count -eq 0) {
                $result.Status = 'Offboarded'
                $result.Message = '{0} offboarded under {1}: {2}.' -f $Identity, $ticket, ($actions -join ', ')
            }
            elseif ($whatIf) {
                $result.Status = 'Planned'
                $result.Message = 'No changes were made (-WhatIf). Would {0}.' -f ($notDone -join ', ')
            }
            elseif ($actions.Count -eq 0) {
                $result.Status = 'Declined'
                $result.Message = 'No changes were made: every step was declined ({0}).' -f ($notDone -join ', ')
                Write-Warning ('Offboarding {0}: {1}' -f $Identity, $result.Message)
            }
            else {
                $result.Status = 'Partial'
                $result.Message = '{0} was only partly offboarded under {1}. Done: {2}. Not done (declined): {3}. Run Remove-ItoUser again to finish.' -f $Identity, $ticket, ($actions -join ', '), ($notDone -join ', ')
                Write-Warning ('Offboarding {0}: {1}' -f $Identity, $result.Message)
            }
        }
        catch {
            $result.Status = 'Failed'
            $result.Message = $_.Exception.Message.Trim()
            Write-Error -Message ("Offboarding {0} failed: {1}" -f $Identity, $_.Exception.Message.Trim()) -Category InvalidOperation -TargetObject $Identity
        }

        $result.Actions = $actions.ToArray()
        $result.GroupsRemoved = $removed.ToArray()
        $result
    }
}
