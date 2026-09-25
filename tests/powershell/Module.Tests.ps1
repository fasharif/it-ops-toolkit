BeforeDiscovery {
    $manifestPath = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/ItOpsToolkit/ItOpsToolkit.psd1'
    $script:exported = @((Import-PowerShellDataFile -Path $manifestPath).FunctionsToExport)
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Module manifest' {
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $script:ModuleManifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'supports Windows PowerShell 5.1 and PowerShell 7' {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleManifest
        $manifest.PowerShellVersion | Should -Be '5.1'
        $manifest.CompatiblePSEditions | Should -Contain 'Desktop'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }

    It 'exports exactly the public functions' {
        $publicFiles = Get-ChildItem -Path (Join-Path -Path $script:RepoRoot -ChildPath 'src/ItOpsToolkit/Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object
        $commands = Get-Command -Module ItOpsToolkit | ForEach-Object { $_.Name } | Sort-Object
        $commands | Should -Be $publicFiles
        (Import-PowerShellDataFile -Path $script:ModuleManifest).FunctionsToExport | Sort-Object | Should -Be $publicFiles
    }

    It 'keeps every PowerShell source file ASCII-only, because Windows PowerShell 5.1 reads BOM-less files as ANSI' {
        $files = Get-ChildItem -Path (Join-Path -Path $script:RepoRoot -ChildPath 'src'), (Join-Path -Path $script:RepoRoot -ChildPath 'tests/powershell'), (Join-Path -Path $script:RepoRoot -ChildPath 'scripts') -Recurse -Include '*.ps1', '*.psm1', '*.psd1'
        $offenders = foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
                $file.Name
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Help for <_>' -ForEach $script:exported {
    BeforeAll {
        $script:help = Get-Help -Name $_ -Full
        $script:command = Get-Command -Name $_
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $script:parameters = @($script:command.Parameters.Keys | Where-Object { $common -notcontains $_ })
    }

    It 'has a synopsis' {
        $script:help.Synopsis | Should -Not -BeNullOrEmpty
        $script:help.Synopsis | Should -Not -Match '^\s*\w+-\w+\s*\[' # not the auto-generated syntax line
    }

    It 'has a description' {
        ($script:help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($script:help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        foreach ($parameter in $script:parameters) {
            $parameterHelp = $script:help.Parameters.Parameter | Where-Object { $_.Name -eq $parameter }
            ($parameterHelp.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "parameter -$parameter needs help text"
        }
    }
}

Describe 'Safety switches' {
    It '<Name> supports -WhatIf and -Confirm' -ForEach @(
        @{ Name = 'New-ItoUser' }
        @{ Name = 'Remove-ItoUser' }
        @{ Name = 'Get-ItoHealthReport' }
    ) {
        $command = Get-Command -Name $Name
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
    }

    It 'Remove-ItoUser has a high confirm impact, so it prompts by default' {
        $attribute = (Get-Command -Name Remove-ItoUser).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attribute.ConfirmImpact | Should -Be 'High'
    }
}

Describe 'Onboarding configuration' {
    BeforeAll {
        $script:examplePath = Join-Path -Path $script:RepoRoot -ChildPath 'config/onboarding.example.json'
    }

    It 'reads the example configuration' {
        InModuleScope ItOpsToolkit -Parameters @{ Path = $script:examplePath } {
            $config = Read-ItoOnboardingConfig -Path $Path
            $config.UpnSuffix | Should -Be 'corp.itops.test'
            $config.DisabledOu | Should -Be 'OU=Disabled Users,DC=corp,DC=itops,DC=test'
            $config.DefaultGroups | Should -Be @('All-Staff')
            $config.Departments.Keys.Count | Should -Be 4
            $config.Departments['finance'].Groups | Should -Be @('Finance-Users', 'Finance-Share-RW')
        }
    }

    It 'matches the JSON schema' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $schema = Join-Path -Path $script:RepoRoot -ChildPath 'config/onboarding.schema.json'
        Get-Content -LiteralPath $script:examplePath -Raw | Test-Json -SchemaFile $schema | Should -BeTrue
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a missing upnSuffix'; Json = '{"disabledOu":"OU=Disabled,DC=a,DC=b","departments":{"X":{"ou":"OU=X,DC=a,DC=b"}}}'; Message = '*upnSuffix*' }
        @{ Case = 'a malformed OU'; Json = '{"upnSuffix":"a.test","disabledOu":"OU=Disabled,DC=a,DC=b","departments":{"X":{"ou":"Finance"}}}'; Message = "*Department 'X' has an invalid 'ou'*" }
        @{ Case = 'an unknown setting'; Json = '{"upnSuffix":"a.test","disabledOu":"OU=Disabled,DC=a,DC=b","departmens":{},"departments":{"X":{"ou":"OU=X,DC=a,DC=b"}}}'; Message = "*Unknown setting 'departmens'*" }
        @{ Case = 'an unsupported name format'; Json = '{"upnSuffix":"a.test","samAccountNameFormat":"last.first","disabledOu":"OU=Disabled,DC=a,DC=b","departments":{"X":{"ou":"OU=X,DC=a,DC=b"}}}'; Message = '*samAccountNameFormat*' }
        @{ Case = 'a group name with a comma'; Json = '{"upnSuffix":"a.test","disabledOu":"OU=Disabled,DC=a,DC=b","departments":{"X":{"ou":"OU=X,DC=a,DC=b","groups":["Bad,Group"]}}}'; Message = '*invalid group name*' }
        @{ Case = 'no departments'; Json = '{"upnSuffix":"a.test","disabledOu":"OU=Disabled,DC=a,DC=b","departments":{}}'; Message = "*'departments' must be an object with at least one department*" }
        @{ Case = 'invalid JSON'; Json = '{"upnSuffix": '; Message = 'Could not read the configuration file*' }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath 'config.json'
        Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
        InModuleScope ItOpsToolkit -Parameters @{ Path = $path; Message = $Message } {
            { Read-ItoOnboardingConfig -Path $Path } | Should -Throw -ExpectedMessage $Message
        }
    }
}

Describe 'Account name rules' {
    BeforeAll {
        $script:cases = @(Import-Csv -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'tests/fixtures/account-names.csv') -Encoding UTF8)
    }

    It 'produces the expected name for every shared test vector (the Bash toolkit uses the same file)' {
        $script:cases.Count | Should -BeGreaterThan 10
        foreach ($case in $script:cases) {
            $actual = InModuleScope ItOpsToolkit -Parameters @{ Case = $case } {
                Get-ItoSamAccountNameCandidate -GivenName (ConvertTo-ItoAsciiName -Name $Case.GivenName) -Surname (ConvertTo-ItoAsciiName -Name $Case.Surname) -Format $Case.Format -Attempt ([int]$Case.Attempt)
            }
            $actual | Should -Be $case.Expected -Because "$($case.GivenName) $($case.Surname) ($($case.Format), attempt $($case.Attempt))"
            $actual.Length | Should -BeLessOrEqual 20
        }
    }

    It 'drops letters that have no ASCII form' {
        InModuleScope ItOpsToolkit {
            $arabic = -join ([char[]](0x0633, 0x0627, 0x0631, 0x0629))
            ConvertTo-ItoAsciiName -Name $arabic | Should -BeExactly ''
            ConvertTo-ItoAsciiName -Name ('Stra' + [char]0x00DF + 'e') | Should -BeExactly 'strae'
        }
    }

    It 'accepts real names and rejects unsafe ones' {
        InModuleScope ItOpsToolkit {
            Test-ItoPersonName -Name "O'Brien" | Should -BeTrue
            Test-ItoPersonName -Name ('Jos' + [char]0x00E9) | Should -BeTrue
            Test-ItoPersonName -Name 'Al Mansoori' | Should -BeTrue
            Test-ItoPersonName -Name 'Jr.' | Should -BeTrue
            Test-ItoPersonName -Name 'Smith, John' | Should -BeFalse
            Test-ItoPersonName -Name 'x*)(cn=*' | Should -BeFalse
            Test-ItoPersonName -Name '-Anna' | Should -BeFalse
            Test-ItoPersonName -Name ('a' * 65) | Should -BeFalse
        }
    }

    It 'escapes LDAP filter values' {
        InModuleScope ItOpsToolkit {
            ConvertTo-ItoLdapFilterValue -Value 'a*b(c)d\e' | Should -BeExactly 'a\2ab\28c\29d\5ce'
        }
    }

    It 'splits distinguished names with escaped commas' {
        InModuleScope ItOpsToolkit {
            $parts = Split-ItoDistinguishedName -DistinguishedName 'CN=Smith\, John,OU=Staff,DC=corp,DC=example'
            $parts.Rdn | Should -BeExactly 'CN=Smith\, John'
            $parts.Parent | Should -BeExactly 'OU=Staff,DC=corp,DC=example'
        }
    }
}
