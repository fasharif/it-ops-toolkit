@{
    # All default rules at every severity, plus syntax compatibility checks for both editions.
    Severity     = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    Rules        = @{
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        # Cmdlets checked against the Windows PowerShell 5.1 profile. The newer PSUseCompatibleCommands
        # rule needs more than 1.5 GB of memory, so the 5.1 guarantee comes from running the Pester
        # suite in Windows PowerShell 5.1 instead (see docs/decisions.md).
        PSUseCompatibleCmdlets     = @{
            Compatibility = @('desktop-5.1.14393.206-windows')
        }
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }
        PSUseConsistentWhitespace  = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $false
            CheckPipe                       = $true
            CheckPipeForRedundantWhitespace = $false
            CheckSeparator                  = $true
            CheckParameter                  = $false
        }
    }
}
