BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Remove-ItoUser' {
    BeforeAll {
        $script:configPath = New-TestConfigFile -Directory $TestDrive
        $script:disabledOu = 'OU=Disabled Users,DC=corp,DC=itops,DC=test'
        $script:groups = @(
            'CN=Finance-Users,OU=Groups,DC=corp,DC=itops,DC=test'
            'CN=Finance-Share-RW,OU=Groups,DC=corp,DC=itops,DC=test'
        )
    }

    BeforeEach {
        $script:auditPath = Join-Path -Path $TestDrive -ChildPath ('audit-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:auditPath
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -MemberOf $script:groups -Description 'Accounts payable'

        Mock -ModuleName ItOpsToolkit Get-ADUser {
            if ($LDAPFilter -like '*(sAMAccountName=omar.haddad)*') { return $script:user }
            return
        }
        Mock -ModuleName ItOpsToolkit Get-ADDomainController { [pscustomobject]@{ HostName = @('dc7.corp.itops.test') } }
        Mock -ModuleName ItOpsToolkit Disable-ADAccount { }
        Mock -ModuleName ItOpsToolkit Set-ADUser { }
        Mock -ModuleName ItOpsToolkit Remove-ADGroupMember { }
        Mock -ModuleName ItOpsToolkit Move-ADObject { }
    }

    It 'offboards an active account in the documented order' {
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'inc0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false

        $result.Status | Should -Be 'Offboarded'
        $result.TicketNumber | Should -Be 'INC0012345'
        $result.Actions | Should -Be @('Exported group memberships', 'Disabled account', 'Recorded ticket in description', 'Removed from 2 group(s)', 'Moved to disabled users OU')
        $result.GroupsRemoved | Should -Be $script:groups
        $result.DistinguishedName | Should -Be "CN=omar.haddad,$script:disabledOu"

        Should -Invoke -ModuleName ItOpsToolkit Disable-ADAccount -Times 1 -Exactly -ParameterFilter { $Identity -eq 'CN=omar.haddad,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test' }
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 1 -Exactly -ParameterFilter { $Description -match '^Offboarded \d{4}-\d{2}-\d{2} ticket INC0012345 \| previous: Accounts payable$' }
        Should -Invoke -ModuleName ItOpsToolkit Remove-ADGroupMember -Times 2 -Exactly -ParameterFilter { $Members -contains 'CN=omar.haddad,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test' }
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 1 -Exactly -ParameterFilter { $TargetPath -eq $script:disabledOu }
    }

    It 'makes every directory call on one writable domain controller when -Server is not given' {
        $null = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        Should -Invoke -ModuleName ItOpsToolkit Get-ADDomainController -Times 1 -Exactly
        foreach ($command in 'Get-ADUser', 'Disable-ADAccount', 'Set-ADUser', 'Remove-ADGroupMember', 'Move-ADObject') {
            Should -Invoke -ModuleName ItOpsToolkit $command -ParameterFilter { $Server -ne 'dc7.corp.itops.test' } -Times 0 -Exactly
        }
    }

    It 'uses -Server as given, without looking for a domain controller' {
        $null = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Server 'dc2.corp.itops.test' -Confirm:$false
        Should -Invoke -ModuleName ItOpsToolkit Get-ADDomainController -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc2.corp.itops.test' }
    }

    It 'exports the group memberships before removing them' {
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        $result.AuditFile | Should -Match 'omar\.haddad_INC0012345_\d{8}T\d{6}Z_groups\.csv$'
        $rows = @(Import-Csv -LiteralPath $result.AuditFile)
        $rows.GroupDistinguishedName | Should -Be $script:groups
        $rows[0].TicketNumber | Should -Be 'INC0012345'
        $rows[0].SamAccountName | Should -Be 'omar.haddad'
    }

    It 'changes nothing when the account is already offboarded' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Enabled $false -MemberOf @() `
            -DistinguishedName "CN=omar.haddad,$script:disabledOu" -Description 'Offboarded 2026-09-01 ticket INC0012345 | previous: Accounts payable'

        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false

        $result.Status | Should -Be 'AlreadyOffboarded'
        $result.Actions | Should -BeNullOrEmpty
        $result.AuditFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:auditPath).Count | Should -Be 0
        Should -Invoke -ModuleName ItOpsToolkit Disable-ADAccount -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Remove-ADGroupMember -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 0 -Exactly
    }

    It 'records a ticket whose number is only a prefix of a ticket already in the description' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Description 'Offboarded 2026-09-01 ticket INC12345'
        $null = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC1' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Description -match '^Offboarded \d{4}-\d{2}-\d{2} ticket INC1 \| previous: Offboarded 2026-09-01 ticket INC12345$'
        }
    }

    It 'treats the ticket as recorded when it appears as a whole token, in any case' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Description 'Leaver, see req-2041.'
        $null = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'REQ-2041' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 0 -Exactly
    }

    It 'finishes a partly completed offboarding' {
        # Disabled by hand, but still in a group and still in the staff OU.
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Enabled $false -MemberOf @($script:groups[0])
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        $result.Status | Should -Be 'Offboarded'
        $result.Actions | Should -Not -Contain 'Disabled account'
        Should -Invoke -ModuleName ItOpsToolkit Disable-ADAccount -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Remove-ADGroupMember -Times 1 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 1 -Exactly
    }

    It 'makes no changes and writes no files with -WhatIf' {
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -WhatIf
        $result.Status | Should -Be 'Planned'
        $result.Message | Should -BeLike 'No changes were made (-WhatIf). Would export group memberships, disable the account, *remove 2 group membership(s)*'
        @(Get-ChildItem -LiteralPath $script:auditPath).Count | Should -Be 0
        Should -Invoke -ModuleName ItOpsToolkit Disable-ADAccount -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Remove-ADGroupMember -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 0 -Exactly
    }

    It 'reports an offboarded account as AlreadyOffboarded under -WhatIf too' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Enabled $false -MemberOf @() `
            -DistinguishedName "CN=omar.haddad,$script:disabledOu" -Description 'Offboarded 2026-09-01 ticket INC0012345'
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -WhatIf
        $result.Status | Should -Be 'AlreadyOffboarded'
    }

    It 'removes no groups when the audit export fails' {
        Mock -ModuleName ItOpsToolkit Export-ItoGroupAudit { throw 'There is not enough space on the disk.' }
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false -ErrorAction SilentlyContinue
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Be 'There is not enough space on the disk.'
        Should -Invoke -ModuleName ItOpsToolkit Disable-ADAccount -Times 0 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Remove-ADGroupMember -Times 0 -Exactly
    }

    It 'reports an unknown account as a non-terminating error' {
        $errors = $null
        $result = Remove-ItoUser -Identity 'no.such' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable errors
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Be "No user account named 'no.such' was found."
        @($errors).Count | Should -Be 1
        "$errors" | Should -Be "Offboarding no.such failed: No user account named 'no.such' was found."
    }

    It 'processes several accounts from the pipeline' {
        $results = @('omar.haddad', 'no.such' | Remove-ItoUser -TicketNumber 'REQ-2041' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false -ErrorAction SilentlyContinue)
        $results.Status | Should -Be @('Offboarded', 'Failed')
        $results[0].TicketNumber | Should -Be 'REQ-2041'
    }

    It 'accepts objects with a SamAccountName property from the pipeline' {
        $result = [pscustomobject]@{ SamAccountName = 'omar.haddad' } | Remove-ItoUser -TicketNumber 'REQ-2041' -DisabledOu 'OU=Leavers,DC=corp,DC=itops,DC=test' -AuditPath $script:auditPath -Confirm:$false
        $result.Status | Should -Be 'Offboarded'
        Should -Invoke -ModuleName ItOpsToolkit Move-ADObject -Times 1 -Exactly -ParameterFilter { $TargetPath -eq 'OU=Leavers,DC=corp,DC=itops,DC=test' }
    }

    It 'keeps the escaped comma when moving an account whose CN contains a comma' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -DistinguishedName 'CN=Haddad\, Omar,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
        $result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        $result.DistinguishedName | Should -Be "CN=Haddad\, Omar,$script:disabledOu"
    }

    It 'limits the description to the 1024 characters Active Directory allows' {
        $script:user = New-TestAdUser -SamAccountName 'omar.haddad' -Description ('x' * 1100)
        $null = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false
        Should -Invoke -ModuleName ItOpsToolkit Set-ADUser -Times 1 -Exactly -ParameterFilter { $Description.Length -eq 1024 }
    }

    Context 'answers at the confirmation prompts' {
        # Pester cannot answer a real ShouldProcess prompt, so these tests run Remove-ItoUser in a
        # child PowerShell process (the same edition as the test run) and type the answers on its
        # standard input, as an operator would. The ActiveDirectory commands are stand-ins that
        # record their names.
        BeforeAll {
            $script:childScript = Join-Path -Path $TestDrive -ChildPath 'offboard-with-answers.ps1'
            Set-Content -LiteralPath $script:childScript -Encoding UTF8 -Value @'
param(
    [Parameter(Mandatory)] [string] $ModulePath,
    [Parameter(Mandatory)] [string] $ConfigPath,
    [Parameter(Mandatory)] [string] $AuditPath
)
$ErrorActionPreference = 'Stop'
$global:calls = New-Object -TypeName System.Collections.Generic.List[string]
$global:leaver = [pscustomobject]@{
    SamAccountName    = 'omar.haddad'
    Enabled           = $true
    Description       = 'Accounts payable'
    DistinguishedName = 'CN=omar.haddad,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
    MemberOf          = @('CN=Finance-Users,OU=Groups,DC=corp,DC=itops,DC=test', 'CN=Finance-Share-RW,OU=Groups,DC=corp,DC=itops,DC=test')
}
foreach ($name in 'New-ADUser', 'Set-ADUser', 'Disable-ADAccount', 'Move-ADObject', 'Add-ADGroupMember', 'Remove-ADGroupMember',
    'Get-ADGroup', 'Get-ADOrganizationalUnit', 'Get-ADDomain', 'Get-ADObject') {
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("`$global:calls.Add('$name')"))
}
function global:Get-ADUser { $global:leaver }
function global:Get-ADDomainController { [pscustomobject]@{ HostName = @('dc1.corp.itops.test') } }
Import-Module -Name $ModulePath
$result = Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC0012345' -ConfigPath $ConfigPath -AuditPath $AuditPath -WarningVariable warnings -WarningAction SilentlyContinue
'RESULT:' + ([pscustomobject]@{
        Status        = $result.Status
        Message       = $result.Message
        Actions       = @($result.Actions)
        GroupsRemoved = @($result.GroupsRemoved)
        AuditFile     = $result.AuditFile
        Calls         = @($global:calls)
        Warnings      = @($warnings | ForEach-Object { [string]$_ })
    } | ConvertTo-Json -Compress -Depth 3)
'@

            function Invoke-OffboardingWithAnswer {
                param([Parameter(Mandatory)] [string[]] $Answer)
                $executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                $arguments = @('-NoProfile')
                if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
                    $arguments += @('-ExecutionPolicy', 'Bypass')
                }
                $arguments += @('-File', $script:childScript, '-ModulePath', $script:ModuleManifest, '-ConfigPath', $script:configPath, '-AuditPath', $script:auditPath)
                $output = ($Answer -join "`n") | & $executable @arguments
                $line = @($output | Where-Object { $_ -like 'RESULT:*' })
                $line.Count | Should -Be 1 -Because ($output -join "`n")
                $line[0].Substring(7) | ConvertFrom-Json
            }
        }

        It 'removes no groups when the audit export is declined, and reports Partial with a warning' {
            # No to the export, then Yes to All for the remaining prompts.
            $result = Invoke-OffboardingWithAnswer -Answer 'N', 'A'

            $result.Status | Should -Be 'Partial'
            $result.AuditFile | Should -BeNullOrEmpty
            @($result.GroupsRemoved).Count | Should -Be 0
            $result.Calls | Should -Not -Contain 'Remove-ADGroupMember'
            $result.Calls | Should -Contain 'Disable-ADAccount'
            $result.Calls | Should -Contain 'Move-ADObject'
            $result.Actions | Should -Be @('Disabled account', 'Recorded ticket in description', 'Moved to disabled users OU')
            $result.Message | Should -BeLike '*Not done (declined): export group memberships, remove 2 group membership(s), skipped because the audit export was declined. Run Remove-ItoUser again to finish.'
            $result.Warnings | Should -Be @("Offboarding omar.haddad: $($result.Message)")
            @(Get-ChildItem -LiteralPath $script:auditPath).Count | Should -Be 0
        }

        It 'changes nothing and reports Declined when every step is declined' {
            # No to All.
            $result = Invoke-OffboardingWithAnswer -Answer 'L'

            $result.Status | Should -Be 'Declined'
            $result.Message | Should -BeLike 'No changes were made: every step was declined (*'
            $result.Calls | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:auditPath).Count | Should -Be 0
        }

        It 'offboards completely when every step is accepted' {
            # Yes to All.
            $result = Invoke-OffboardingWithAnswer -Answer 'A'

            $result.Status | Should -Be 'Offboarded'
            $result.AuditFile | Should -Not -BeNullOrEmpty
            @($result.GroupsRemoved).Count | Should -Be 2
            @($result.Calls | Where-Object { $_ -eq 'Remove-ADGroupMember' }).Count | Should -Be 2
        }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a ticket number without a prefix'; Ticket = '12345'; Identity = 'omar.haddad' }
        @{ Case = 'a ticket number with spaces'; Ticket = 'INC 12345'; Identity = 'omar.haddad' }
        @{ Case = 'an identity with LDAP filter characters'; Ticket = 'INC1'; Identity = 'omar*)(cn=*' }
        @{ Case = 'an identity longer than 20 characters'; Ticket = 'INC1'; Identity = 'a.very.long.account.name' }
    ) {
        { Remove-ItoUser -Identity $Identity -TicketNumber $Ticket -ConfigPath $script:configPath -AuditPath $script:auditPath -Confirm:$false } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError,Remove-ItoUser'
    }

    It 'rejects a -DisabledOu written in lower case, as the configuration file does' {
        { Remove-ItoUser -Identity 'omar.haddad' -TicketNumber 'INC1' -DisabledOu 'ou=Leavers,dc=corp,dc=itops,dc=test' -AuditPath $script:auditPath -Confirm:$false } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError,Remove-ItoUser'
    }
}
