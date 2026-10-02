# Latin letters that have no Unicode decomposition, with their usual ASCII spelling, keyed by
# code point: sharp s (both cases), ae, oe, o with stroke, l with stroke, d with stroke, eth,
# thorn and dotless i. linux/lib/hrfeed.py has the same table.
$script:ItoTransliteration = @{
    0x00DF = 'ss'; 0x1E9E = 'ss'
    0x00E6 = 'ae'; 0x00C6 = 'ae'
    0x0153 = 'oe'; 0x0152 = 'oe'
    0x00F8 = 'o'; 0x00D8 = 'o'
    0x0142 = 'l'; 0x0141 = 'l'
    0x0111 = 'd'; 0x0110 = 'd'
    0x00F0 = 'd'; 0x00D0 = 'd'
    0x00FE = 'th'; 0x00DE = 'th'
    0x0131 = 'i'
}

function ConvertTo-ItoAsciiName {
    <#
    .SYNOPSIS
        Reduces a person's name to lower-case ASCII letters and digits for account names.
    .DESCRIPTION
        First spells the Latin letters that have no Unicode decomposition in ASCII (sharp s as
        'ss', ae, oe, o and l with stroke, thorn as 'th' and so on), then decomposes the name
        (Unicode NFKD), drops combining marks, and keeps only a-z and 0-9. 'Jos\u00e9' becomes
        'jose', 'Stra\u00dfe' becomes 'strasse', 'Al-Mansoori' becomes 'almansoori' and "O'Brien"
        becomes 'obrien'. Scripts other than Latin (for example Arabic) are dropped.
        linux/lib/hrfeed.py applies the same rules, so both toolkits produce the same names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )

    $spelled = New-Object -TypeName System.Text.StringBuilder
    foreach ($character in $Name.ToCharArray()) {
        $replacement = $script:ItoTransliteration[[int]$character]
        if ($null -ne $replacement) {
            [void]$spelled.Append($replacement)
        }
        else {
            [void]$spelled.Append($character)
        }
    }
    $decomposed = $spelled.ToString().Normalize([System.Text.NormalizationForm]::FormKD)
    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($character in $decomposed.ToCharArray()) {
        $code = [int]$character
        if ($code -ge 65 -and $code -le 90) {
            [void]$builder.Append([char]($code + 32))
        }
        elseif (($code -ge 97 -and $code -le 122) -or ($code -ge 48 -and $code -le 57)) {
            [void]$builder.Append($character)
        }
    }
    $builder.ToString()
}

function Get-ItoSamAccountNameCandidate {
    <#
    .SYNOPSIS
        Builds a sAMAccountName candidate from ASCII name parts.
    .DESCRIPTION
        Attempt 1 has no suffix. Later attempts append the attempt number. The result never
        exceeds the 20-character sAMAccountName limit and never ends with a full stop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+$')]
        [string] $GivenName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+$')]
        [string] $Surname,

        [ValidateSet('first.last', 'flast')]
        [string] $Format = 'first.last',

        [ValidateRange(1, 99)]
        [int] $Attempt = 1
    )

    if ($Format -eq 'flast') {
        $base = $GivenName.Substring(0, 1) + $Surname
    }
    else {
        $base = '{0}.{1}' -f $GivenName, $Surname
    }
    $suffix = ''
    if ($Attempt -gt 1) {
        $suffix = [string]$Attempt
    }
    $maxBase = 20 - $suffix.Length
    if ($base.Length -gt $maxBase) {
        $base = $base.Substring(0, $maxBase)
    }
    $base.TrimEnd('.') + $suffix
}

function Test-ItoPersonName {
    <#
    .SYNOPSIS
        Returns $true when a given name or surname only uses characters that are safe in a directory.
    .DESCRIPTION
        Letters (any script), combining marks, spaces, hyphens, full stops and apostrophes are allowed.
        The name must start with a letter, end with a letter, mark or full stop, and be at most 64 characters.
        These rules keep names safe inside distinguished names and LDAP filters without escaping.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )

    if ($Name.Length -lt 1 -or $Name.Length -gt 64) {
        return $false
    }
    # \u2019 is the typographic apostrophe that HR systems often store in names such as O'Brien.
    $Name -cmatch '^\p{L}(?:[\p{L}\p{M} .''\u2019-]*[\p{L}\p{M}.])?$'
}

function ConvertTo-ItoLdapFilterValue {
    <#
    .SYNOPSIS
        Escapes a value for use inside an LDAP search filter (RFC 4515).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            0 { [void]$builder.Append('\00') }
            40 { [void]$builder.Append('\28') }
            41 { [void]$builder.Append('\29') }
            42 { [void]$builder.Append('\2a') }
            92 { [void]$builder.Append('\5c') }
            default { [void]$builder.Append($character) }
        }
    }
    $builder.ToString()
}
