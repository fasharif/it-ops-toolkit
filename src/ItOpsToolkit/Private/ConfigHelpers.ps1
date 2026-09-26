function ConvertTo-ItoHashtable {
    <#
    .SYNOPSIS
        Converts the output of ConvertFrom-Json into nested hashtables and arrays.
    .DESCRIPTION
        Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, so this walks the
        PSCustomObject graph instead. The hashtables are case-sensitive, as JSON keys are, unlike
        PowerShell's @{}: a setting written as 'OU' must not be read as 'ou'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable], [object[]])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = New-Object -TypeName System.Collections.Hashtable -ArgumentList ([System.StringComparer]::Ordinal)
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-ItoHashtable -InputObject $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = New-Object -TypeName System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-ItoHashtable -InputObject $item))
        }
        return , $items.ToArray()
    }
    return $InputObject
}

function Read-ItoOnboardingConfig {
    <#
    .SYNOPSIS
        Reads and validates the shared onboarding and offboarding JSON configuration.
    .DESCRIPTION
        The rules match linux/lib/config-check.jq and config/onboarding.schema.json. Like the
        schema, they are case-sensitive: setting names, samAccountNameFormat and the OU=, CN=
        and DC= parts of distinguished names must be written exactly as shown. PowerShell's
        hashtables and -match ignore case by default, so the checks below use -c operators.
    .OUTPUTS
        A hashtable with UpnSuffix, SamAccountNameFormat, DisabledOu, DefaultGroups and Departments.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Could not read the configuration file '$Path': $($_.Exception.Message.Trim())"
    }

    $data = ConvertTo-ItoHashtable -InputObject $json
    if ($data -isnot [hashtable]) {
        throw "The configuration file '$Path' must contain a JSON object."
    }

    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    $dnPattern = '^(?:(?:OU|CN)=[^,=]+,)+(?:DC=[A-Za-z0-9-]+,)*DC=[A-Za-z0-9-]+$'
    $dnsPattern = '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
    $groupPattern = '^[^"/\\\[\]:;|=,+*?<>]{1,64}$'
    $knownKeys = @('upnSuffix', 'samAccountNameFormat', 'disabledOu', 'defaultGroups', 'departments')

    foreach ($key in $data.Keys) {
        if ($key -notlike '$*' -and $knownKeys -cnotcontains $key) {
            $problems.Add("Unknown setting '$key'. Known settings: $($knownKeys -join ', ').")
        }
    }

    $upnSuffix = [string]$data['upnSuffix']
    if ($upnSuffix -notmatch $dnsPattern) {
        $problems.Add("'upnSuffix' must be a DNS domain name such as corp.example.com (found '$upnSuffix').")
    }

    $format = 'first.last'
    if ($data.ContainsKey('samAccountNameFormat')) {
        $format = [string]$data['samAccountNameFormat']
        if (@('first.last', 'flast') -cnotcontains $format) {
            $problems.Add("'samAccountNameFormat' must be 'first.last' or 'flast' (found '$format').")
        }
    }

    $disabledOu = [string]$data['disabledOu']
    if ($disabledOu -cnotmatch $dnPattern) {
        $problems.Add("'disabledOu' must be a distinguished name such as OU=Disabled Users,DC=corp,DC=example,DC=com, with OU=, CN= and DC= in capitals (found '$disabledOu').")
    }

    $defaultGroups = @()
    if ($null -ne $data['defaultGroups']) {
        if ($data['defaultGroups'] -isnot [array]) {
            $problems.Add("'defaultGroups' must be a list of group names.")
        }
        else {
            $defaultGroups = @($data['defaultGroups'])
            foreach ($group in $defaultGroups) {
                if ($group -isnot [string] -or $group -notmatch $groupPattern) {
                    $problems.Add("Default group name '$group' is not a valid group name.")
                }
            }
        }
    }

    $departments = @{}
    $rawDepartments = $data['departments']
    if ($rawDepartments -isnot [hashtable] -or $rawDepartments.Count -eq 0) {
        $problems.Add("'departments' must be an object with at least one department.")
    }
    else {
        foreach ($name in $rawDepartments.Keys) {
            $entry = $rawDepartments[$name]
            if ($entry -isnot [hashtable]) {
                $problems.Add("Department '$name' must be an object with 'ou' and 'groups'.")
                continue
            }
            foreach ($entryKey in $entry.Keys) {
                if (@('ou', 'groups') -cnotcontains $entryKey) {
                    $problems.Add("Department '$name' has an unknown setting '$entryKey'. Known settings: ou, groups.")
                }
            }
            $ou = [string]$entry['ou']
            if ($ou -cnotmatch $dnPattern) {
                $problems.Add("Department '$name' has an invalid 'ou' distinguished name ('$ou').")
            }
            $groups = @()
            if ($null -ne $entry['groups']) {
                if ($entry['groups'] -isnot [array]) {
                    $problems.Add("Department '$name' has a 'groups' setting that is not a list of group names.")
                }
                else {
                    $groups = @($entry['groups'])
                }
            }
            foreach ($group in $groups) {
                if ($group -isnot [string] -or $group -notmatch $groupPattern) {
                    $problems.Add("Department '$name' lists an invalid group name ('$group').")
                }
            }
            $departments[$name] = @{
                Name   = [string]$name
                Ou     = $ou
                Groups = [string[]]$groups
            }
        }
    }

    if ($problems.Count -gt 0) {
        throw ("The configuration file '{0}' is not valid:{1} - {2}" -f $Path, [Environment]::NewLine, ($problems -join ([Environment]::NewLine + ' - ')))
    }

    @{
        UpnSuffix            = $upnSuffix.ToLowerInvariant()
        SamAccountNameFormat = $format
        DisabledOu           = $disabledOu
        DefaultGroups        = [string[]]$defaultGroups
        Departments          = $departments
    }
}
