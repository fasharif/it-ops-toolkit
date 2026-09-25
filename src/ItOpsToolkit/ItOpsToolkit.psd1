@{
    RootModule           = 'ItOpsToolkit.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = '0718a9d6-5c80-40df-a9a3-125375a412fd'
    Author               = 'Farah Sharif'
    CompanyName          = 'Farah Sharif'
    Copyright            = '(c) 2026 Farah Sharif. Released under the MIT licence.'
    Description          = 'Help-desk automation: Active Directory onboarding, offboarding and lockout tracing, Windows health reports and layered network troubleshooting.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @(
        'New-ItoUser'
        'Remove-ItoUser'
        'Get-ItoHealthReport'
        'Test-ItoNetwork'
        'Get-ItoLockoutSource'
        'New-ItoRandomPassword'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'HelpDesk', 'Onboarding', 'Offboarding', 'HealthCheck', 'Network', 'Windows')
            LicenseUri = 'https://github.com/fasharif/it-ops-toolkit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/fasharif/it-ops-toolkit'
        }
    }
}
