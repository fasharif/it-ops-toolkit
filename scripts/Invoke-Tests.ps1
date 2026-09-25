<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester tests for the ItOpsToolkit module.

.DESCRIPTION
    Runs the analyzer (which must report nothing) and the Pester suite with code coverage.
    Results go to ./out.

    It needs the pinned versions of Pester and PSScriptAnalyzer, and only the ones the chosen
    stage uses. When one is missing it installs it from the PowerShell Gallery into the current
    user's scope, which is what the throwaway CI runners and containers want. On your own
    machine, pass -NoInstall to get an error instead of an installation.

    CI and scripts/test-powershell.sh run this inside the mcr.microsoft.com/powershell container.
    On Windows it also runs in Windows PowerShell 5.1: powershell -File scripts/Invoke-Tests.ps1

.PARAMETER Stage
    All (default), Analyze or Test.

.PARAMETER MinimumCoverage
    Fail when line coverage of src/ is below this percentage. The default is 0 (report only).

.PARAMETER NoInstall
    Stop with an error when a required module version is missing, instead of installing it.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCmdlets', '',
    Justification = 'PackageManagement and PowerShellGet ship with Windows PowerShell 5.1; the analyzer profile predates them.')]
[CmdletBinding()]
param(
    [ValidateSet('All', 'Analyze', 'Test')]
    [string] $Stage = 'All',

    [ValidateRange(0, 100)]
    [double] $MinimumCoverage = 0,

    [switch] $NoInstall
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$outDirectory = Join-Path -Path $repoRoot -ChildPath 'out'
$null = New-Item -ItemType Directory -Path $outDirectory -Force

$pinnedVersions = @{
    Pester           = '5.9.1'
    PSScriptAnalyzer = '1.25.0'
}
$requiredModules = [ordered]@{}
if ($Stage -in @('All', 'Analyze')) {
    $requiredModules['PSScriptAnalyzer'] = $pinnedVersions.PSScriptAnalyzer
}
if ($Stage -in @('All', 'Test')) {
    $requiredModules['Pester'] = $pinnedVersions.Pester
}

foreach ($name in $requiredModules.Keys) {
    $version = [version]$requiredModules[$name]
    if (-not (Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq $version })) {
        if ($NoInstall) {
            throw "$name $version is not installed. Install it with: Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser"
        }
        Write-Information "Installing $name $version from the PowerShell Gallery."
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and -not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
        }
        $install = @{
            Name            = $name
            RequiredVersion = $version
            Scope           = 'CurrentUser'
            Force           = $true
            AllowClobber    = $true
        }
        if ((Get-Command -Name Install-Module).Parameters.ContainsKey('SkipPublisherCheck')) {
            $install['SkipPublisherCheck'] = $true
        }
        Install-Module @install
    }
}

Write-Information ("PowerShell {0} ({1}) on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [System.Environment]::OSVersion.VersionString)
$failed = $false

if ($Stage -in @('All', 'Analyze')) {
    Import-Module -Name PSScriptAnalyzer -RequiredVersion $pinnedVersions.PSScriptAnalyzer -Force
    $targets = @(
        @{ Path = Join-Path -Path $repoRoot -ChildPath 'src'; Settings = Join-Path -Path $repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1' }
        @{ Path = Join-Path -Path $repoRoot -ChildPath 'scripts'; Settings = Join-Path -Path $repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1' }
        @{ Path = Join-Path -Path $repoRoot -ChildPath 'tests/powershell'; Settings = Join-Path -Path $repoRoot -ChildPath 'tests/powershell/PSScriptAnalyzerSettings.psd1' }
    )
    $findings = @(foreach ($target in $targets) {
            Invoke-ScriptAnalyzer -Path $target.Path -Recurse -Settings $target.Settings
        })
    if ($findings.Count -gt 0) {
        $findings | Sort-Object -Property ScriptName, Line | Format-Table -Property Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Information
        Write-Information ('PSScriptAnalyzer: {0} finding(s).' -f $findings.Count)
        $failed = $true
    }
    else {
        Write-Information 'PSScriptAnalyzer: no findings.'
    }
}

if ($Stage -in @('All', 'Test')) {
    Import-Module -Name Pester -RequiredVersion $pinnedVersions.Pester -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path -Path $repoRoot -ChildPath 'tests/powershell'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path -Path $outDirectory -ChildPath ('pester-{0}.xml' -f $PSVersionTable.PSEdition.ToLowerInvariant())
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = Join-Path -Path $repoRoot -ChildPath 'src/ItOpsToolkit'
    $configuration.CodeCoverage.OutputPath = Join-Path -Path $outDirectory -ChildPath ('coverage-{0}.xml' -f $PSVersionTable.PSEdition.ToLowerInvariant())
    $result = Invoke-Pester -Configuration $configuration

    if ($result.Result -ne 'Passed') {
        $failed = $true
    }
    if ($null -ne $result.CodeCoverage) {
        $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
        Write-Information ("Line coverage of src/ItOpsToolkit: {0}% ({1} of {2} commands)" -f $coverage, $result.CodeCoverage.CommandsExecutedCount, $result.CodeCoverage.CommandsAnalyzedCount)
        if ($coverage -lt $MinimumCoverage) {
            Write-Information "Coverage is below the minimum of $MinimumCoverage%."
            $failed = $true
        }
    }
}

if ($failed) {
    exit 1
}
exit 0
