function New-ItoRandomPassword {
    <#
    .SYNOPSIS
        Generates a strong random password and returns it as a SecureString.

    .DESCRIPTION
        Characters are drawn from the operating system's cryptographic random number generator
        with rejection sampling, so every character is equally likely. The password always contains
        at least one upper-case letter, one lower-case letter, one digit and one symbol, which meets
        the Active Directory complexity rule.

        Characters that are easy to misread (0, O, 1, l, I) and characters that cause trouble when
        typed, dictated or pasted into a shell or CSV file (quotes, backslash, comma, semicolon,
        space) are never used.

        The password is only ever returned as a SecureString. It is not written to the pipeline,
        the console or any log as plain text.

    .PARAMETER Length
        Number of characters, from 12 to 128. The default is 20.

    .PARAMETER ExcludeSubstring
        Strings that must not appear in the password, compared without regard to case. Active
        Directory rejects a password that contains the account name, or any part of the display
        name that is three or more characters long, so New-ItoUser passes those values here.
        Values shorter than three characters are ignored.

    .EXAMPLE
        $password = New-ItoRandomPassword -Length 24
        Set-ADAccountPassword -Identity 'sara.ali' -Reset -NewPassword $password

        Resets a password to a new random value during a password reset ticket.

    .EXAMPLE
        New-ItoRandomPassword -ExcludeSubstring 'sara.ali', 'Sara', 'Ali'

        Generates a password that does not contain the account name or name parts.

    .OUTPUTS
        System.Security.SecureString

    .LINK
        New-ItoUser
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a value in memory only; no system state changes.')]
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [ValidateRange(12, 128)]
        [int] $Length = 20,

        [AllowEmptyCollection()]
        [string[]] $ExcludeSubstring = @()
    )

    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
        '!#$%&*+-=?@^_'
    )
    $allCharacters = -join $classes
    $excluded = @($ExcludeSubstring | Where-Object { $null -ne $_ -and $_.Length -ge 3 })

    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($attempt = 1; $attempt -le 100; $attempt++) {
            $characters = New-Object -TypeName 'char[]' -ArgumentList $Length
            for ($i = 0; $i -lt $classes.Count; $i++) {
                $set = $classes[$i]
                $characters[$i] = $set[(Get-ItoRandomIndex -Generator $generator -Maximum $set.Length)]
            }
            for ($i = $classes.Count; $i -lt $Length; $i++) {
                $characters[$i] = $allCharacters[(Get-ItoRandomIndex -Generator $generator -Maximum $allCharacters.Length)]
            }
            # Fisher-Yates shuffle so the guaranteed characters are not always at the start.
            for ($i = $Length - 1; $i -gt 0; $i--) {
                $j = Get-ItoRandomIndex -Generator $generator -Maximum ($i + 1)
                $swap = $characters[$i]
                $characters[$i] = $characters[$j]
                $characters[$j] = $swap
            }

            $candidate = New-Object -TypeName string -ArgumentList (, $characters)
            $clash = $false
            foreach ($value in $excluded) {
                if ($candidate.IndexOf($value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $clash = $true
                    break
                }
            }
            if (-not $clash) {
                $secure = New-Object -TypeName System.Security.SecureString
                foreach ($character in $characters) {
                    $secure.AppendChar($character)
                }
                [Array]::Clear($characters, 0, $characters.Length)
                $secure.MakeReadOnly()
                return $secure
            }
            [Array]::Clear($characters, 0, $characters.Length)
        }
    }
    finally {
        $generator.Dispose()
    }
    throw 'Could not generate a password without the excluded substrings after 100 attempts.'
}
