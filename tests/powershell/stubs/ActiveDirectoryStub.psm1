# Stand-ins for the ActiveDirectory module commands that ItOpsToolkit calls.
#
# Pester can only mock a command that exists, and the real module needs Windows with RSAT.
# These stubs copy the parameters the toolkit uses, so the mocks are checked against the same
# parameter names. Every stub throws if a test forgets to mock it.

function Get-ADUser {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $Filter,
        [string] $LDAPFilter,
        [string[]] $Properties,
        [string] $SearchBase,
        [string] $SearchScope,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADUser stub was called without a mock.'
}

function New-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Name,
        [string] $SamAccountName,
        [string] $UserPrincipalName,
        [string] $GivenName,
        [string] $Surname,
        [string] $DisplayName,
        [string] $EmailAddress,
        [string] $EmployeeID,
        [string] $Department,
        [string] $Title,
        [string] $Description,
        [object] $Manager,
        [string] $Path,
        [securestring] $AccountPassword,
        [bool] $ChangePasswordAtLogon,
        [bool] $Enabled,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'New-ADUser stub was called without a mock.'
}

function Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $Description,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Set-ADUser stub was called without a mock.'
}

function Disable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Disable-ADAccount stub was called without a mock.'
}

function Move-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $TargetPath,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Move-ADObject stub was called without a mock.'
}

function Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [object[]] $Members,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Add-ADGroupMember stub was called without a mock.'
}

function Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [object[]] $Members,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Remove-ADGroupMember stub was called without a mock.'
}

function Get-ADGroup {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $LDAPFilter,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADGroup stub was called without a mock.'
}

function Get-ADOrganizationalUnit {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADOrganizationalUnit stub was called without a mock.'
}

function Get-ADDomain {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADDomain stub was called without a mock.'
}

function Get-ADDomainController {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [switch] $Discover,
        [switch] $Writable,
        [string[]] $Service,
        [string] $DomainName,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADDomainController stub was called without a mock.'
}

function Get-ADObject {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object] $Identity,
        [string] $LDAPFilter,
        [string[]] $Properties,
        [string] $SearchBase,
        [string] $SearchScope,
        [string] $Server,
        [pscredential] $Credential
    )
    throw 'Get-ADObject stub was called without a mock.'
}

Export-ModuleMember -Function *
