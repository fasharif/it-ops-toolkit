BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule

    $script:header = 'EmployeeId,GivenName,Surname,Department,Title,Manager,StartDate'
    function New-Feed {
        param([string[]] $Rows, [string] $Header = $script:header)
        $path = Join-Path -Path $TestDrive -ChildPath ('feed-{0}.csv' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $path -Value (@($Header) + $Rows) -Encoding UTF8
        $path
    }
}

Describe 'New-ItoUser' {
    BeforeAll {
        $script:configPath = New-TestConfigFile -Directory $TestDrive
        $script:flastConfigPath = New-TestConfigFile -Directory $TestDrive -Format 'flast'
    }

    BeforeEach {
        $script:created = New-Object -TypeName System.Collections.Generic.List[object]
        $script:takenNames = @()
        $script:takenEmployeeIds = @()
        $script:sameNameInOu = @()
        $script:managers = @('lina.haddad')

        Mock -ModuleName ItOpsToolkit Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = $Identity } }
        Mock -ModuleName ItOpsToolkit Get-ADGroup { [pscustomobject]@{ Name = 'group' } }
        Mock -ModuleName ItOpsToolkit Add-ADGroupMember { }
        Mock -ModuleName ItOpsToolkit Get-ADUser {
            if ($LDAPFilter -match '^\(employeeID=(.+)\)$') {
                if ($script:takenEmployeeIds -contains $Matches[1]) { return New-TestAdUser -SamAccountName 'existing.user' }
                return
            }
            if ($LDAPFilter -match '^\(\|\(sAMAccountName=([^)]+)\)') {
                if ($script:takenNames -contains $Matches[1]) { return New-TestAdUser -SamAccountName $Matches[1] }
                return
            }
            if ($LDAPFilter -match '^\(&\(objectClass=user\)\(cn=(.+)\)\)$') {
                if ($script:sameNameInOu -contains $Matches[1]) { return New-TestAdUser -SamAccountName 'someone.else' }
                return
            }
            if ($LDAPFilter -match '^\(sAMAccountName=(.+)\)$') {
                if ($script:managers -contains $Matches[1]) { return New-TestAdUser -SamAccountName $Matches[1] -DistinguishedName "CN=Manager,OU=Staff,DC=corp,DC=itops,DC=test" }
                return
            }
            throw "Unexpected Get-ADUser call: $LDAPFilter"
        }
        Mock -ModuleName ItOpsToolkit New-ADUser {
            $script:created.Add([pscustomobject]@{
                    Name                  = $Name
                    SamAccountName        = $SamAccountName
                    UserPrincipalName     = $UserPrincipalName
                    EmailAddress          = $EmailAddress
                    DisplayName           = $DisplayName
                    EmployeeID            = $EmployeeID
                    Department            = $Department
                    Title                 = $Title
                    Description           = $Description
                    Manager               = $Manager
                    Path                  = $Path
                    Password              = $AccountPassword
                    ChangePasswordAtLogon = $ChangePasswordAtLogon
                    Enabled               = $Enabled
                })
        }
    }

    Context 'creating accounts' {
        It 'creates each valid row in the department OU with a unique account name' {
            $feed = New-Feed -Rows @(
                'E1,Sara,Ali,Finance,Accounts Assistant,,2026-10-05'
                'E2,Sara,Ali,Sales,Sales Executive,,2026-10-05'
                ('E3,Jos{0},Garc{1}a-L{2}pez,IT,Service Desk Analyst,,' -f [char]0x00E9, [char]0x00ED, [char]0x00F3)
            )
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false)

            $results.Status | Should -Be @('Created', 'Created', 'Created')
            $script:created.SamAccountName | Should -Be @('sara.ali', 'sara.ali2', 'jose.garcialopez')
            $script:created[0].Path | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
            $script:created[1].Path | Should -Be 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
            $script:created[0].UserPrincipalName | Should -Be 'sara.ali@corp.itops.test'
            $script:created[0].EmailAddress | Should -Be 'sara.ali@corp.itops.test'
            $script:created[2].DisplayName | Should -Be ('Jos{0} Garc{1}a-L{2}pez' -f [char]0x00E9, [char]0x00ED, [char]0x00F3)
            $results[0].Row | Should -Be 1
            $results[2].Row | Should -Be 3
        }

        It 'skips account names that are already taken in the directory' {
            $script:takenNames = @('sara.ali', 'sara.ali2')
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $result.SamAccountName | Should -Be 'sara.ali3'
        }

        It 'uses the flast format when the configuration asks for it' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            (New-ItoUser -Path $feed -ConfigPath $script:flastConfigPath -Confirm:$false).SamAccountName | Should -Be 'sali'
        }

        It 'adds the account to the default and department groups' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $result.Groups | Should -Be @('All-Staff', 'Finance-Users', 'Finance-Share-RW')
            Should -Invoke -ModuleName ItOpsToolkit Add-ADGroupMember -Times 3 -Exactly -ParameterFilter { $Members -contains 'sara.ali' }
            Should -Invoke -ModuleName ItOpsToolkit Add-ADGroupMember -Times 1 -Exactly -ParameterFilter { $Identity -eq 'Finance-Share-RW' }
        }

        It 'enables the account and requires a password change at first sign-in' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $script:created[0].Enabled | Should -BeTrue
            $script:created[0].ChangePasswordAtLogon | Should -BeTrue
        }

        It 'records the employee ID, title, department and start date' {
            $feed = New-Feed -Rows @('E77,Sara,Ali,finance,Accounts Assistant,,2026-10-05')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $script:created[0].EmployeeID | Should -Be 'E77'
            $script:created[0].Title | Should -Be 'Accounts Assistant'
            $script:created[0].Department | Should -Be 'Finance'
            $script:created[0].Description | Should -BeLike 'Start date 2026-10-05. Onboarded * by ItOpsToolkit'
        }

        It 'sets the manager when the manager exists and warns when not' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,lina.haddad,', 'E2,Omar,Haddad,Finance,,no.such,')
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue)
            $script:created[0].Manager | Should -Be 'CN=Manager,OU=Staff,DC=corp,DC=itops,DC=test'
            $script:created[1].Manager | Should -BeNullOrEmpty
            $results[1].Status | Should -Be 'Created'
            $results[1].Warnings | Should -Be @("Manager 'no.such' was not found, so no manager was set.")
        }

        It 'adds the account name to the CN when the OU already has someone with the same name' {
            $script:sameNameInOu = @('Sara Ali')
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $script:created[0].Name | Should -Be 'Sara Ali (sara.ali)'
        }

        It 'records a failed group addition as a warning without failing the row' {
            Mock -ModuleName ItOpsToolkit Add-ADGroupMember { throw 'Insufficient access rights' } -ParameterFilter { $Identity -eq 'Finance-Share-RW' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue
            $result.Status | Should -Be 'Created'
            $result.Warnings | Should -Be @("Could not add the account to group 'Finance-Share-RW': Insufficient access rights")
        }

        It 'accepts rows from the pipeline' {
            $rows = @(
                [pscustomobject]@{ EmployeeId = 'E1'; GivenName = 'Sara'; Surname = 'Ali'; Department = 'Finance' }
                @{ EmployeeId = 'E2'; GivenName = 'Omar'; Surname = 'Haddad'; Department = 'Sales' }
            )
            $results = @($rows | New-ItoUser -ConfigPath $script:configPath -Confirm:$false)
            $results.SamAccountName | Should -Be @('sara.ali', 'omar.haddad')
            $results.Row | Should -Be @(1, 2)
        }
    }

    Context 'validation and idempotency' {
        It 'marks invalid rows and carries on with the rest' {
            $feed = New-Feed -Rows @(
                'E1,Sara,Ali,Marketing,,,'
                'E2,Omar,Haddad,Finance,,,05/10/2026'
                'E 3,Lina,Khan,Finance,,,'
                'E4,,Khan,Finance,,,'
                'E5,"Smith, John",Doe,Finance,,,'
                ('E6,{0},Khan,Finance,,,' -f (-join ([char[]](0x0633, 0x0627, 0x0631, 0x0629))))
                'E7,Aisha,Al Mansoori,Finance,,,'
            )
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue)
            $results.Status | Should -Be @('Invalid', 'Invalid', 'Invalid', 'Invalid', 'Invalid', 'Invalid', 'Created')
            $results[0].Message | Should -BeLike "Department 'Marketing' is not in the configuration. Known departments: Finance, IT, Sales."
            $results[1].Message | Should -BeLike '*yyyy-MM-dd*'
            $results[2].Message | Should -BeLike "EmployeeId 'E 3'*"
            $results[3].Message | Should -Be 'GivenName is required.'
            $results[4].Message | Should -BeLike '*characters that are not allowed*'
            $results[5].Message | Should -BeLike '*Latin-script spelling*'
            $script:created.SamAccountName | Should -Be @('aisha.almansoori')
        }

        It 'rejects a duplicate employee ID within one feed' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,', 'E1,Sara,Ali,Finance,,,')
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue)
            $results.Status | Should -Be @('Created', 'Invalid')
            $results[1].Message | Should -BeLike '*appears more than once*'
        }

        It 'stops with a clear error when required columns are missing' {
            $feed = New-Feed -Header 'EmployeeId,FirstName,LastName,Department' -Rows @('E1,Sara,Ali,Finance')
            { New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false } | Should -Throw -ExpectedMessage '*missing required columns: GivenName, Surname*'
        }

        It 'warns and returns nothing for an empty feed' {
            $feed = New-Feed -Rows @()
            $warnings = $null
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue)
            $results.Count | Should -Be 0
            "$warnings" | Should -BeLike '*has no data rows*'
        }

        It 'skips a new starter who already has an account, so the feed can be run again' {
            $script:takenEmployeeIds = @('E1')
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $result.Status | Should -Be 'Exists'
            $result.SamAccountName | Should -Be 'existing.user'
            Should -Invoke -ModuleName ItOpsToolkit New-ADUser -Times 0 -Exactly
        }

        It 'fails only the rows whose OU is missing' {
            Mock -ModuleName ItOpsToolkit Get-ADOrganizationalUnit { throw 'Directory object not found' } -ParameterFilter { $Identity -like 'OU=Sales*' }
            $feed = New-Feed -Rows @('E1,Omar,Haddad,Sales,,,', 'E2,Sara,Ali,Finance,,,', 'E3,Lina,Khan,Sales,,,')
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue)
            $results.Status | Should -Be @('Failed', 'Created', 'Failed')
            $results[0].Message | Should -BeLike "The OU 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test' from the configuration could not be found*"
            Should -Invoke -ModuleName ItOpsToolkit Get-ADOrganizationalUnit -Times 2 -Exactly
        }

        It 'fails rows whose configured group does not exist, before creating anything' {
            Mock -ModuleName ItOpsToolkit Get-ADGroup { } -ParameterFilter { $LDAPFilter -eq '(sAMAccountName=Finance-Share-RW)' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue
            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Be "The group 'Finance-Share-RW' from the configuration does not exist in the directory."
            Should -Invoke -ModuleName ItOpsToolkit New-ADUser -Times 0 -Exactly
        }

        It 'reports a directory error on one row and continues' {
            Mock -ModuleName ItOpsToolkit New-ADUser { throw 'The server is unwilling to process the request' } -ParameterFilter { $SamAccountName -eq 'sara.ali' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,', 'E2,Omar,Haddad,Finance,,,')
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false -WarningAction SilentlyContinue)
            $results.Status | Should -Be @('Failed', 'Created')
            $results[0].InitialPassword | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans the accounts without creating them or generating passwords' {
            Mock -ModuleName ItOpsToolkit New-ItoRandomPassword { throw 'should not be called' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,', 'E2,Sara,Ali,Sales,,,')
            $results = @(New-ItoUser -Path $feed -ConfigPath $script:configPath -WhatIf)
            $results.Status | Should -Be @('Planned', 'Planned')
            $results.SamAccountName | Should -Be @('sara.ali', 'sara.ali2')
            $results[0].Message | Should -Be 'Would create sara.ali@corp.itops.test in OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test and add it to 3 group(s).'
            foreach ($result in $results) {
                $result.InitialPassword | Should -BeNullOrEmpty
            }
            Should -Invoke -ModuleName ItOpsToolkit New-ADUser -Times 0 -Exactly
            Should -Invoke -ModuleName ItOpsToolkit Add-ADGroupMember -Times 0 -Exactly
        }

        It 'does not write the summary file under -WhatIf' {
            $summary = Join-Path -Path $TestDrive -ChildPath 'whatif-summary.csv'
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -SummaryPath $summary -WhatIf
            Test-Path -LiteralPath $summary | Should -BeFalse
        }
    }

    Context 'password handling' {
        It 'sets a strong password that does not contain the account or display name' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false
            $plain = ConvertFrom-TestSecureString -SecureString $script:created[0].Password
            $plain.Length | Should -Be 20
            $plain | Should -Not -Match 'sara'
            $result.InitialPassword | Should -BeOfType [System.Security.SecureString]
            ConvertFrom-TestSecureString -SecureString $result.InitialPassword | Should -BeExactly $plain
        }

        It 'honours -PasswordLength' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -PasswordLength 32 -Confirm:$false
            $script:created[0].Password.Length | Should -Be 32
        }

        It 'never writes the password to output, verbose, warning, information streams, a transcript or the summary' {
            Mock -ModuleName ItOpsToolkit Add-ADGroupMember { throw 'Insufficient access rights' } -ParameterFilter { $Identity -eq 'All-Staff' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,no.such,')
            $summary = Join-Path -Path $TestDrive -ChildPath 'summary-secret-check.csv'
            $transcript = Join-Path -Path $TestDrive -ChildPath 'transcript.txt'

            Start-Transcript -LiteralPath $transcript -Force | Out-Null
            try {
                $streams = New-ItoUser -Path $feed -ConfigPath $script:configPath -SummaryPath $summary -Confirm:$false -Verbose -InformationAction Continue *>&1
                $streams | Format-List -Property * | Out-Host
            }
            finally {
                Stop-Transcript | Out-Null
            }

            $plain = ConvertFrom-TestSecureString -SecureString $script:created[0].Password
            $escaped = [regex]::Escape($plain)
            $allText = ($streams | ForEach-Object { $_ | Format-List -Property * | Out-String -Width 4096 }) -join "`n"
            $allText | Should -Match 'Onboarding summary: 1 created'
            $allText | Should -Match 'no manager was set'
            $allText | Should -Not -Match $escaped
            Get-Content -LiteralPath $summary -Raw | Should -Not -Match $escaped
            Get-Content -LiteralPath $transcript -Raw | Should -Not -Match $escaped
        }

        It 'writes a CMS-encrypted delivery file that the certificate holder can read' {
            $delivery = Join-Path -Path $TestDrive -ChildPath 'delivery'
            $null = New-Item -ItemType Directory -Path $delivery -Force
            $certificate = New-TestDeliveryCertificate -Directory $TestDrive
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')

            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -DeliveryPath $delivery -DeliveryCertificate $certificate.CerPath -Confirm:$false

            $result.DeliveryFile | Should -Be (Join-Path -Path $delivery -ChildPath 'sara.ali.cms')
            $raw = Get-Content -LiteralPath $result.DeliveryFile -Raw
            $raw | Should -Match '-----BEGIN CMS-----'
            $plain = ConvertFrom-TestSecureString -SecureString $script:created[0].Password
            $raw | Should -Not -Match ([regex]::Escape($plain))
            $decrypted = Unprotect-CmsMessage -Content $raw -To $certificate.Certificate
            $decrypted | Should -Match 'Account: sara.ali'
            $decrypted | Should -Match 'Sign-in name: sara.ali@corp.itops.test'
            $decrypted | Should -Match ('Initial password: ' + [regex]::Escape($plain))
        }

        It 'writes delivery files that openssl can decrypt too, for service desks on Linux' -Skip:($PSVersionTable.PSEdition -ne 'Core' -or -not (Get-Command -Name openssl -ErrorAction SilentlyContinue)) {
            $delivery = Join-Path -Path $TestDrive -ChildPath 'delivery-openssl'
            $null = New-Item -ItemType Directory -Path $delivery -Force
            $certificate = New-TestDeliveryCertificate -Directory $TestDrive
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate.Certificate)
            $keyPath = Join-Path -Path $TestDrive -ChildPath 'delivery.key'
            $certPath = Join-Path -Path $TestDrive -ChildPath 'delivery.pem'
            Set-Content -LiteralPath $keyPath -Value ("-----BEGIN PRIVATE KEY-----`n{0}`n-----END PRIVATE KEY-----" -f [Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), 'InsertLineBreaks'))
            Set-Content -LiteralPath $certPath -Value ("-----BEGIN CERTIFICATE-----`n{0}`n-----END CERTIFICATE-----" -f [Convert]::ToBase64String($certificate.Certificate.RawData, 'InsertLineBreaks'))
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')

            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -DeliveryPath $delivery -DeliveryCertificate $certificate.CerPath -Confirm:$false

            $decrypted = & openssl cms -decrypt -binary -inform PEM -in $result.DeliveryFile -inkey $keyPath -recip $certPath
            $LASTEXITCODE | Should -Be 0
            $plain = ConvertFrom-TestSecureString -SecureString $script:created[0].Password
            $decrypted | Should -Contain ('Initial password: ' + $plain)
        }

        It 'requires -DeliveryPath and -DeliveryCertificate together' {
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            { New-ItoUser -Path $feed -ConfigPath $script:configPath -DeliveryPath $TestDrive -Confirm:$false } | Should -Throw -ExpectedMessage '*together*'
        }

        It 'refuses a certificate that cannot encrypt' {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $request = New-Object -TypeName System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN=Signing only', $rsa,
                ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $signingOnly = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            $cerPath = Join-Path -Path $TestDrive -ChildPath 'signing.cer'
            [System.IO.File]::WriteAllBytes($cerPath, $signingOnly.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')

            { New-ItoUser -Path $feed -ConfigPath $script:configPath -DeliveryPath $TestDrive -DeliveryCertificate $cerPath -Confirm:$false } |
                Should -Throw -ExpectedMessage '*cannot be used for encryption*Document Encryption*'
            Should -Invoke -ModuleName ItOpsToolkit New-ADUser -Times 0 -Exactly
        }

        It 'keeps the password on the result when the delivery file cannot be written' {
            Mock -ModuleName ItOpsToolkit Assert-ItoDeliveryCertificate { }
            Mock -ModuleName ItOpsToolkit Write-ItoDeliveryFile { throw 'Access to the path is denied.' }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $result = New-ItoUser -Path $feed -ConfigPath $script:configPath -DeliveryPath $TestDrive -DeliveryCertificate 'placeholder.cer' -Confirm:$false -WarningAction SilentlyContinue
            $result.Status | Should -Be 'Created'
            $result.DeliveryFile | Should -BeNullOrEmpty
            $result.InitialPassword | Should -Not -BeNullOrEmpty
            $result.Warnings[0] | Should -BeLike 'The password delivery file could not be written: Access to the path is denied.*InitialPassword*'
        }
    }

    Context 'summary' {
        It 'writes one summary row per input row, without any password column' {
            $summary = Join-Path -Path $TestDrive -ChildPath 'summary.csv'
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,', 'E2,Omar,Haddad,Marketing,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -SummaryPath $summary -Confirm:$false -WarningAction SilentlyContinue
            $rows = @(Import-Csv -LiteralPath $summary)
            $rows.Count | Should -Be 2
            $rows[0].SamAccountName | Should -Be 'sara.ali'
            $rows[0].Groups | Should -Be 'All-Staff;Finance-Users;Finance-Share-RW'
            $rows[1].Status | Should -Be 'Invalid'
            $rows[0].PSObject.Properties.Name | Should -Not -Contain 'InitialPassword'
        }
    }

    Context 'prerequisites' {
        It 'explains how to install the ActiveDirectory module when it is missing' {
            Mock -ModuleName ItOpsToolkit Get-Command { $null } -ParameterFilter { $Name -like '*-AD*' }
            Mock -ModuleName ItOpsToolkit Get-Module { $null } -ParameterFilter { $ListAvailable }
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            { New-ItoUser -Path $feed -ConfigPath $script:configPath -Confirm:$false } | Should -Throw -ExpectedMessage '*Add-WindowsCapability*RSAT-AD-PowerShell*'
        }

        It 'validates the file paths' {
            { New-ItoUser -Path (Join-Path -Path $TestDrive -ChildPath 'missing.csv') -ConfigPath $script:configPath } | Should -Throw
            { New-ItoUser -Path $script:configPath -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'missing.json') } | Should -Throw
        }

        It 'passes -Server and -Credential to every directory call' {
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'CORP\svc-onboard', (New-Object -TypeName System.Security.SecureString)
            $feed = New-Feed -Rows @('E1,Sara,Ali,Finance,,,')
            $null = New-ItoUser -Path $feed -ConfigPath $script:configPath -Server 'dc1.corp.itops.test' -Credential $credential -Confirm:$false
            Should -Invoke -ModuleName ItOpsToolkit New-ADUser -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc1.corp.itops.test' -and $Credential.UserName -eq 'CORP\svc-onboard' }
            Should -Invoke -ModuleName ItOpsToolkit Get-ADUser -ParameterFilter { $Server -ne 'dc1.corp.itops.test' } -Times 0 -Exactly
            Should -Invoke -ModuleName ItOpsToolkit Add-ADGroupMember -ParameterFilter { $Server -ne 'dc1.corp.itops.test' } -Times 0 -Exactly
        }
    }
}
