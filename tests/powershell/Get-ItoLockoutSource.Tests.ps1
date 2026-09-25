BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Get-ItoLockoutSource' {
    BeforeEach {
        $script:now = Get-Date
        $script:account = [pscustomobject]@{
            SamAccountName         = 'sara.ali'
            LockedOut              = $true
            AccountLockoutTime     = $script:now.AddMinutes(-5)
            BadLogonCount          = 6
            LastBadPasswordAttempt = $script:now.AddMinutes(-5)
            PasswordLastSet        = $script:now.AddDays(-1)
        }
        Mock -ModuleName ItOpsToolkit Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'dc1.corp.itops.test' } }
        Mock -ModuleName ItOpsToolkit Get-ADUser {
            if ($LDAPFilter -like '*(sAMAccountName=sara.ali)*') { return $script:account }
            return
        }
        Mock -ModuleName ItOpsToolkit Get-ItoLockoutEventData {
            [pscustomobject]@{ TimeCreated = $script:now.AddMinutes(-5); TargetUserName = 'sara.ali'; CallerComputer = 'LAPTOP-0142' }
            [pscustomobject]@{ TimeCreated = $script:now.AddMinutes(-65); TargetUserName = 'sara.ali'; CallerComputer = 'LAPTOP-0142' }
            [pscustomobject]@{ TimeCreated = $script:now.AddMinutes(-30); TargetUserName = 'SARA.ALI'; CallerComputer = 'MAILGW01' }
            [pscustomobject]@{ TimeCreated = $script:now.AddMinutes(-10); TargetUserName = 'omar.haddad'; CallerComputer = 'PC-0007' }
        }
    }

    It 'reports the lockout state and ranks the caller computers' {
        $report = Get-ItoLockoutSource -Identity 'sara.ali'
        $report.PSObject.TypeNames | Should -Contain 'ItOpsToolkit.LockoutReport'
        $report.LockedOut | Should -BeTrue
        $report.BadLogonCount | Should -Be 6
        $report.PdcEmulator | Should -Be 'dc1.corp.itops.test'
        $report.Sources.CallerComputer | Should -Be @('LAPTOP-0142', 'MAILGW01')
        $report.Sources[0].Lockouts | Should -Be 2
        $report.Sources[0].LastLockout | Should -Be $script:now.AddMinutes(-5)
        $report.Advice | Should -BeLike 'Start with LAPTOP-0142: *Credential Manager (cmdkey /list)*Unlock the account only after fixing the cause.'
        $report.Warning | Should -BeNullOrEmpty
    }

    It 'ignores lockouts of other accounts and lists events newest first' {
        $report = Get-ItoLockoutSource -Identity 'sara.ali'
        @($report.Events).Count | Should -Be 3
        $report.Events[0].TimeCreated | Should -Be $script:now.AddMinutes(-5)
        $report.Events.CallerComputer | Should -Not -Contain 'PC-0007'
    }

    It 'reads the account from the PDC emulator, where every bad password is counted' {
        $null = Get-ItoLockoutSource -Identity 'sara.ali'
        Should -Invoke -ModuleName ItOpsToolkit Get-ADUser -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc1.corp.itops.test' -and $Properties -contains 'BadLogonCount' }
        Should -Invoke -ModuleName ItOpsToolkit Get-ItoLockoutEventData -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'dc1.corp.itops.test' -and $Hours -eq 24 }
    }

    It 'passes -Server to the domain lookup and -Hours to the event search' {
        $null = Get-ItoLockoutSource -Identity 'sara.ali' -Server 'dc2.corp.itops.test' -Hours 72
        Should -Invoke -ModuleName ItOpsToolkit Get-ADDomain -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc2.corp.itops.test' }
        Should -Invoke -ModuleName ItOpsToolkit Get-ItoLockoutEventData -Times 1 -Exactly -ParameterFilter { $Hours -eq 72 }
    }

    It 'points at a server log when the events name no caller computer' {
        Mock -ModuleName ItOpsToolkit Get-ItoLockoutEventData { [pscustomobject]@{ TimeCreated = $script:now; TargetUserName = 'sara.ali'; CallerComputer = '' } }
        (Get-ItoLockoutSource -Identity 'sara.ali').Advice | Should -BeLike '*do not name a caller computer*Exchange, ADFS or a VPN server*'
    }

    It 'says so when a locked account has no lockout event in the window' {
        Mock -ModuleName ItOpsToolkit Get-ItoLockoutEventData { }
        (Get-ItoLockoutSource -Identity 'sara.ali' -Hours 6).Advice | Should -Be 'The account is locked out, but no lockout event for it was found in the last 6 hours on dc1.corp.itops.test. Search a longer period with -Hours, or check whether auditing of account lockouts is enabled.'
    }

    It 'suggests other causes when the account is not locked out' {
        $script:account.LockedOut = $false
        Mock -ModuleName ItOpsToolkit Get-ItoLockoutEventData { }
        $report = Get-ItoLockoutSource -Identity 'sara.ali'
        $report.LockedOut | Should -BeFalse
        $report.Advice | Should -BeLike 'The account is not locked out.*password expiry*'
    }

    It 'still returns the account state when the Security log cannot be read' {
        Mock -ModuleName ItOpsToolkit Get-ItoLockoutEventData { throw 'Attempted to perform an unauthorized operation.' }
        $warnings = $null
        $report = Get-ItoLockoutSource -Identity 'sara.ali' -WarningVariable warnings -WarningAction SilentlyContinue
        $report.LockedOut | Should -BeTrue
        @($report.Sources).Count | Should -Be 0
        $report.Warning | Should -BeLike 'The Security log on dc1.corp.itops.test could not be read: Attempted to perform an unauthorized operation. *Event Log Readers*'
        "$warnings" | Should -BeLike '*Event Log Readers*'
    }

    It 'writes a non-terminating error for an unknown account and carries on with the pipeline' {
        $errors = $null
        $reports = @('no.such', 'sara.ali' | Get-ItoLockoutSource -ErrorVariable errors -ErrorAction SilentlyContinue)
        $reports.Count | Should -Be 1
        $reports[0].SamAccountName | Should -Be 'sara.ali'
        "$errors" | Should -Be "No user account named 'no.such' was found."
    }

    It 'rejects an account name with LDAP filter characters' {
        { Get-ItoLockoutSource -Identity 'sara*)(cn=*' } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Get-ItoLockoutSource'
    }
}

Describe 'Get-ItoLockoutEventData' {
    BeforeAll {
        # Get-WinEvent only exists on Windows. Pester can only mock a command that exists, so
        # elsewhere a stand-in with the same parameters is defined for the duration of the test.
        if (-not (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) {
            function global:Get-WinEvent {
                [CmdletBinding()]
                param([string] $ComputerName, [hashtable[]] $FilterHashtable, [pscredential] $Credential)
                throw 'Get-WinEvent stand-in was called without a mock.'
            }
            $script:removeStandIn = $true
        }
    }

    AfterAll {
        if ($script:removeStandIn) {
            Remove-Item -Path Function:\Get-WinEvent
        }
    }

    It 'maps event 4740 properties to the account and the caller computer' {
        Mock -ModuleName ItOpsToolkit Get-WinEvent {
            [pscustomobject]@{
                TimeCreated = [datetime]'2026-09-26T08:15:00'
                Properties  = @([pscustomobject]@{ Value = 'sara.ali' }, [pscustomobject]@{ Value = 'LAPTOP-0142' })
            }
        }
        InModuleScope ItOpsToolkit {
            $event4740 = @(Get-ItoLockoutEventData -ComputerName 'dc1' -Hours 24)
            $event4740[0].TargetUserName | Should -Be 'sara.ali'
            $event4740[0].CallerComputer | Should -Be 'LAPTOP-0142'
        }
        Should -Invoke -ModuleName ItOpsToolkit Get-WinEvent -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'dc1' -and $FilterHashtable.Id -eq 4740 -and $FilterHashtable.LogName -eq 'Security' }
    }
}
