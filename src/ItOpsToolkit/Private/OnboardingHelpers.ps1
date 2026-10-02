function ConvertTo-ItoOnboardingResult {
    <#
    .SYNOPSIS
        Creates the result object for one HR feed row, before any directory work is done.
    #>
    [CmdletBinding()]
    [OutputType('ItOpsToolkit.OnboardingResult')]
    param(
        [Parameter(Mandatory)]
        [int] $Row,

        [Parameter(Mandatory)]
        [hashtable] $Record
    )

    [pscustomobject]@{
        PSTypeName         = 'ItOpsToolkit.OnboardingResult'
        Row                = $Row
        EmployeeId         = $Record.EmployeeId
        DisplayName        = ('{0} {1}' -f $Record.GivenName, $Record.Surname).Trim()
        SamAccountName     = $null
        UserPrincipalName  = $null
        Department         = $Record.Department
        OrganizationalUnit = $null
        Groups             = @()
        Status             = 'Pending'
        Message            = ''
        Warnings           = @()
        DeliveryFile       = $null
        InitialPassword    = $null
    }
}

function Get-ItoOnboardingTargetProblem {
    <#
    .SYNOPSIS
        Checks that a department's OU and groups exist before any account is created.
    .DESCRIPTION
        Results are cached per OU and group, so a feed with 200 finance starters checks the
        finance OU once. Returns $null when everything exists, otherwise a message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Ou,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Groups,

        [Parameter(Mandatory)]
        [hashtable] $Cache,

        [hashtable] $AdParameters = @{}
    )

    $key = 'ou:' + $Ou
    if (-not $Cache.ContainsKey($key)) {
        try {
            $null = Get-ADOrganizationalUnit -Identity $Ou @AdParameters -ErrorAction Stop
            $Cache[$key] = $null
        }
        catch {
            $Cache[$key] = "The OU '$Ou' from the configuration could not be found: $($_.Exception.Message.Trim())"
        }
    }
    if ($null -ne $Cache[$key]) {
        return $Cache[$key]
    }

    foreach ($group in $Groups) {
        $key = 'group:' + $group
        if (-not $Cache.ContainsKey($key)) {
            $filter = '(sAMAccountName={0})' -f (ConvertTo-ItoLdapFilterValue -Value $group)
            $found = Get-ADGroup -LDAPFilter $filter @AdParameters
            if ($null -eq $found) {
                $Cache[$key] = "The group '$group' from the configuration does not exist in the directory."
            }
            else {
                $Cache[$key] = $null
            }
        }
        if ($null -ne $Cache[$key]) {
            return $Cache[$key]
        }
    }
    return $null
}

function Get-ItoMissingGroup {
    <#
    .SYNOPSIS
        Lists the configured groups that an existing account is not a member of.
    .DESCRIPTION
        Group names are resolved to distinguished names once per run (cached) and compared with
        the account's memberOf values. Groups that do not exist in the directory are left out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $MemberOf,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Groups,

        [Parameter(Mandatory)]
        [hashtable] $Cache,

        [hashtable] $AdParameters = @{}
    )

    $current = @($MemberOf | Where-Object { $_ })
    foreach ($group in $Groups) {
        $key = 'dn:' + $group
        if (-not $Cache.ContainsKey($key)) {
            $filter = '(sAMAccountName={0})' -f (ConvertTo-ItoLdapFilterValue -Value $group)
            $found = @(Get-ADGroup -LDAPFilter $filter @AdParameters)
            $Cache[$key] = $null
            if ($found.Count -gt 0) {
                $Cache[$key] = [string]$found[0].DistinguishedName
            }
        }
        $groupDn = $Cache[$key]
        if ([string]::IsNullOrEmpty($groupDn)) {
            continue
        }
        $isMember = @($current | Where-Object { [string]::Equals($_, $groupDn, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $isMember) {
            $group
        }
    }
}
