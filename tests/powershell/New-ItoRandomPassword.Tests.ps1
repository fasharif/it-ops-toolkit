BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'New-ItoRandomPassword' {
    It 'returns a read-only SecureString of the default length 20' {
        $password = New-ItoRandomPassword
        $password | Should -BeOfType [System.Security.SecureString]
        $password.IsReadOnly() | Should -BeTrue
        $password.Length | Should -Be 20
    }

    It 'honours -Length' {
        (New-ItoRandomPassword -Length 64).Length | Should -Be 64
    }

    It 'rejects lengths outside 12-128' {
        { New-ItoRandomPassword -Length 11 } | Should -Throw
        { New-ItoRandomPassword -Length 129 } | Should -Throw
    }

    It 'always includes upper case, lower case, a digit and a symbol, and only allowed characters' {
        for ($i = 0; $i -lt 200; $i++) {
            $plain = ConvertFrom-TestSecureString -SecureString (New-ItoRandomPassword -Length 12)
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -MatchExactly '[0-9]'
            $plain | Should -MatchExactly '[!#$%&*+=?@^_-]'
            $plain | Should -MatchExactly '^[A-HJ-NP-Za-km-z2-9!#$%&*+=?@^_-]{12}$'
        }
    }

    It 'never repeats across 500 passwords' {
        $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        for ($i = 0; $i -lt 500; $i++) {
            $seen.Add((ConvertFrom-TestSecureString -SecureString (New-ItoRandomPassword))) | Should -BeTrue
        }
    }

    It 'uses every allowed character (no character is unreachable)' {
        # A HashSet[char] compares case-sensitively; a PowerShell hashtable would merge 'A' and 'a'.
        $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[char]'
        for ($i = 0; $i -lt 400; $i++) {
            foreach ($character in (ConvertFrom-TestSecureString -SecureString (New-ItoRandomPassword -Length 64)).ToCharArray()) {
                [void]$seen.Add($character)
            }
        }
        # 24 upper + 25 lower + 8 digits + 13 symbols
        $seen.Count | Should -Be 70
    }

    It 'retries when the password contains an excluded substring, and gives up after 100 attempts' {
        # With the random index forced to 0, every attempt produces 'a2!AAAAAAAAA', which contains 'aaa'
        # when compared without regard to case. 23 random draws per attempt, 100 attempts.
        Mock -ModuleName ItOpsToolkit Get-ItoRandomIndex { 0 }
        { New-ItoRandomPassword -Length 12 -ExcludeSubstring 'aaa' } | Should -Throw -ExpectedMessage '*after 100 attempts*'
        Should -Invoke -ModuleName ItOpsToolkit Get-ItoRandomIndex -Times 2300 -Exactly -Scope It
    }

    It 'ignores excluded values shorter than three characters' {
        Mock -ModuleName ItOpsToolkit Get-ItoRandomIndex { 0 }
        { New-ItoRandomPassword -Length 12 -ExcludeSubstring 'aa', 'A' } | Should -Not -Throw
    }
}

Describe 'Get-ItoRandomIndex' {
    It 'stays within range and covers every value' {
        InModuleScope ItOpsToolkit {
            $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $values = for ($i = 0; $i -lt 2000; $i++) { Get-ItoRandomIndex -Generator $generator -Maximum 7 }
            }
            finally {
                $generator.Dispose()
            }
            ($values | Measure-Object -Minimum -Maximum).Minimum | Should -Be 0
            ($values | Measure-Object -Minimum -Maximum).Maximum | Should -Be 6
            @($values | Select-Object -Unique).Count | Should -Be 7
        }
    }
}
