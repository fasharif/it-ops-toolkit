function Assert-ItoActiveDirectory {
    <#
    .SYNOPSIS
        Makes sure the ActiveDirectory module commands this toolkit uses are available.
    #>
    [CmdletBinding()]
    param()

    $required = @(
        'Get-ADUser', 'New-ADUser', 'Set-ADUser', 'Disable-ADAccount', 'Move-ADObject',
        'Add-ADGroupMember', 'Remove-ADGroupMember', 'Get-ADGroup', 'Get-ADOrganizationalUnit'
    )
    $missing = @($required | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0 -and (Get-Module -ListAvailable -Name 'ActiveDirectory')) {
        Import-Module -Name 'ActiveDirectory' -ErrorAction Stop -Verbose:$false
        $missing = @($required | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    }
    if ($missing.Count -gt 0) {
        throw ('The ActiveDirectory PowerShell module is required, but these commands are missing: {0}. ' +
            "On Windows 10 or 11 install it with: Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'. " +
            'On Windows Server run: Install-WindowsFeature RSAT-AD-PowerShell.') -f ($missing -join ', ')
    }
}

function Get-ItoAdParameter {
    <#
    .SYNOPSIS
        Builds the -Server and -Credential splat shared by every ActiveDirectory call.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Server,

        [System.Management.Automation.PSCredential]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    $parameters = @{}
    if (-not [string]::IsNullOrEmpty($Server)) {
        $parameters['Server'] = $Server
    }
    if ($null -ne $Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $parameters['Credential'] = $Credential
    }
    $parameters
}

function Split-ItoDistinguishedName {
    <#
    .SYNOPSIS
        Splits a distinguished name into its first RDN and the parent DN.
    .DESCRIPTION
        Respects escaped commas, so 'CN=Smith\, John,OU=Staff,DC=corp,DC=example' splits into
        'CN=Smith\, John' and 'OU=Staff,DC=corp,DC=example'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $DistinguishedName
    )

    if ($DistinguishedName -notmatch '^((?:[^,\\]|\\.)+),(.+)$') {
        throw "'$DistinguishedName' is not a distinguished name with a parent."
    }
    @{
        Rdn    = $Matches[1]
        Parent = $Matches[2]
    }
}

function Export-ItoGroupAudit {
    <#
    .SYNOPSIS
        Writes a leaver's group memberships to a CSV audit file before they are removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $SamAccountName,

        [Parameter(Mandatory)]
        [string] $TicketNumber,

        [Parameter(Mandatory)]
        [string[]] $Groups,

        [Parameter(Mandatory)]
        [datetime] $ExportedAtUtc
    )

    $stamp = $ExportedAtUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $Groups | ForEach-Object {
        [pscustomobject]@{
            SamAccountName         = $SamAccountName
            TicketNumber           = $TicketNumber
            GroupDistinguishedName = $_
            ExportedAtUtc          = $stamp
        }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop -WhatIf:$false -Confirm:$false
}

function Resolve-ItoSamAccountName {
    <#
    .SYNOPSIS
        Finds the first free sAMAccountName for a new starter.
    .DESCRIPTION
        A candidate is free when no directory account uses it as sAMAccountName or as the
        prefix of its userPrincipalName, and no earlier row in the same batch reserved it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $GivenName,

        [Parameter(Mandatory)]
        [string] $Surname,

        [Parameter(Mandatory)]
        [string] $Format,

        [Parameter(Mandatory)]
        [string] $UpnSuffix,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Reserved,

        [hashtable] $AdParameters = @{}
    )

    for ($attempt = 1; $attempt -le 99; $attempt++) {
        $candidate = Get-ItoSamAccountNameCandidate -GivenName $GivenName -Surname $Surname -Format $Format -Attempt $attempt
        if ($Reserved.Contains($candidate)) {
            continue
        }
        $filter = '(|(sAMAccountName={0})(userPrincipalName={0}@{1}))' -f (ConvertTo-ItoLdapFilterValue -Value $candidate), (ConvertTo-ItoLdapFilterValue -Value $UpnSuffix)
        $existing = Get-ADUser -LDAPFilter $filter @AdParameters
        if ($null -eq $existing) {
            [void]$Reserved.Add($candidate)
            return $candidate
        }
    }
    throw "No free account name was found for '$GivenName $Surname' after 99 attempts."
}
