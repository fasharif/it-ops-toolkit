function Get-ItoRecordValue {
    <#
    .SYNOPSIS
        Reads a trimmed field from a CSV row, PSCustomObject or hashtable. Missing fields return ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Record,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Record) {
        return ''
    }
    $value = $null
    if ($Record -is [System.Collections.IDictionary]) {
        foreach ($key in $Record.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $Record[$key]
                break
            }
        }
    }
    else {
        $property = $Record.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $value = $property.Value
        }
    }
    if ($null -eq $value) {
        return ''
    }
    ([string]$value).Trim()
}

function Test-ItoOnboardingRecord {
    <#
    .SYNOPSIS
        Validates one HR feed row and returns a list of problems (empty when the row is valid).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Row,

        [Parameter(Mandatory)]
        [hashtable] $Config
    )

    $problems = New-Object -TypeName System.Collections.Generic.List[string]

    if ([string]::IsNullOrEmpty($Row.EmployeeId)) {
        $problems.Add('EmployeeId is required.')
    }
    elseif ($Row.EmployeeId -notmatch '^[A-Za-z0-9-]{1,16}$') {
        $problems.Add("EmployeeId '$($Row.EmployeeId)' must be 1-16 letters, digits or hyphens.")
    }

    $namesValid = $true
    foreach ($field in @('GivenName', 'Surname')) {
        $value = $Row[$field]
        if ([string]::IsNullOrEmpty($value)) {
            $problems.Add("$field is required.")
            $namesValid = $false
        }
        elseif (-not (Test-ItoPersonName -Name $value)) {
            $problems.Add("$field '$value' contains characters that are not allowed in a name.")
            $namesValid = $false
        }
        elseif ((ConvertTo-ItoAsciiName -Name $value).Length -eq 0) {
            $problems.Add("$field '$value' has no letters that can be used in an account name. Add a Latin-script spelling to the HR record.")
            $namesValid = $false
        }
    }

    # The account's CN is 'GivenName Surname', and Active Directory limits CN to 64 characters.
    $fullName = '{0} {1}' -f $Row.GivenName, $Row.Surname
    if ($namesValid -and $fullName.Length -gt 64) {
        $problems.Add("The full name '$fullName' is $($fullName.Length) characters long. Active Directory limits the common name (CN) to 64 characters, so shorten the name in the HR record.")
    }

    if ([string]::IsNullOrEmpty($Row.Department)) {
        $problems.Add('Department is required.')
    }
    elseif (-not $Config.Departments.ContainsKey($Row.Department)) {
        $known = ($Config.Departments.Keys | Sort-Object) -join ', '
        $problems.Add("Department '$($Row.Department)' is not in the configuration. Known departments: $known.")
    }

    if ($Row.Title.Length -gt 64 -or $Row.Title -match '[\x00-\x1F]') {
        $problems.Add('Title must be at most 64 characters with no control characters.')
    }

    if (-not [string]::IsNullOrEmpty($Row.Manager) -and $Row.Manager -notmatch '^[A-Za-z0-9._-]{1,20}$') {
        $problems.Add("Manager '$($Row.Manager)' must be the manager's account name (sAMAccountName).")
    }

    if (-not [string]::IsNullOrEmpty($Row.StartDate)) {
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($Row.StartDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
        if (-not $ok) {
            $problems.Add("StartDate '$($Row.StartDate)' must use the format yyyy-MM-dd.")
        }
    }

    $problems.ToArray()
}
