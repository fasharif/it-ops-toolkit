@{
    # Test code: the same rules as the module, minus the ones that misfire on Pester idioms.
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # Variables set in BeforeAll or BeforeEach and used in It blocks look unused to the analyzer.
        'PSUseDeclaredVarsMoreThanAssignments'
        # The ActiveDirectory stubs mirror real command names such as New-ADUser and Set-ADUser.
        'PSUseShouldProcessForStateChangingFunctions'
        # Stub parameters must match the real cmdlets, which use these names and types.
        'PSAvoidUsingPlainTextForPassword'
        # Stub bodies throw without using their parameters.
        'PSReviewUnusedParameter'
        # The stubs declare SupportsShouldProcess so callers can pass -Confirm:$false, as they do to the real cmdlets.
        'PSShouldProcess'
        # Tests pass fixed, fictional host names such as portal.example.com on purpose.
        'PSAvoidUsingComputerNameHardcoded'
    )
    Rules               = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
