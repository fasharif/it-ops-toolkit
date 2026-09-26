<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester tests for the ItOpsToolkit module.

.DESCRIPTION
    Runs the analyzer (which must report nothing) and the Pester suite with code coverage.
    Results go to ./out.

    It needs pinned versions of Pester and PSScriptAnalyzer, and only the ones the chosen stage
    uses. It looks for them in ./out/modules first, then in the usual module folders. When one is
    missing it stops with an error, unless you pass -Install: then it downloads the package from
    the PowerShell Gallery, checks its pinned SHA-256 hash and unpacks it into ./out/modules.
    Nothing is installed outside the repository, and PSModulePath changes only for this process.

    CI and scripts/test-powershell.sh run this inside the mcr.microsoft.com/powershell container
    with -Install. On Windows it also runs in Windows PowerShell 5.1:
    powershell -ExecutionPolicy Bypass -File scripts\Invoke-Tests.ps1 -Stage Test -Install

.PARAMETER Stage
    All (default), Analyze or Test.

.PARAMETER MinimumCoverage
    Fail when Pester's command coverage of src/ItOpsToolkit is below this percentage. The
    default is 0 (report only).

.PARAMETER Install
    Download missing pinned modules into ./out/modules instead of stopping with an error.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Analyze', 'Test')]
    [string] $Stage = 'All',

    [ValidateRange(0, 100)]
    [double] $MinimumCoverage = 0,

    [switch] $Install
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$outDirectory = Join-Path -Path $repoRoot -ChildPath 'out'
$moduleDirectory = Join-Path -Path $outDirectory -ChildPath 'modules'
$null = New-Item -ItemType Directory -Path $moduleDirectory -Force

# Pinned versions, with the SHA-256 of the .nupkg files on the PowerShell Gallery.
$pinned = @{
    Pester           = @{ Version = '5.9.1'; Sha256 = '8DD4060FC3BC895F05BD655E4AB82ABE346DE54A4E6415DFB727CC8378672B69' }
    PSScriptAnalyzer = @{ Version = '1.25.0'; Sha256 = '14E634C828EB98EFB9F40B2918BA90F139ED5ECCDF663A2A747736D996995D60' }
}
$requiredModules = @()
if ($Stage -in @('All', 'Analyze')) {
    $requiredModules += 'PSScriptAnalyzer'
}
if ($Stage -in @('All', 'Test')) {
    $requiredModules += 'Pester'
}

# Modules saved by -Install come first, for this process only.
$env:PSModulePath = $moduleDirectory + [System.IO.Path]::PathSeparator + $env:PSModulePath

function Save-PinnedModule {
    # Downloads a module package from the PowerShell Gallery, checks its hash and unpacks it into
    # <Destination>/<Name>/<Version>, the layout Import-Module expects. Save-Module would do the
    # same, but in Windows PowerShell 5.1 it first installs the NuGet provider into the profile.
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Destination
    )

    $url = 'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f $Name, $Version
    $package = Join-Path -Path $Destination -ChildPath ('{0}.{1}.zip' -f $Name, $Version)
    $target = Join-Path -Path (Join-Path -Path $Destination -ChildPath $Name) -ChildPath $Version
    Write-Information "Downloading $Name $Version from the PowerShell Gallery into $Destination."
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    Invoke-WebRequest -Uri $url -OutFile $package -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($hash -ne $Sha256) {
        Remove-Item -LiteralPath $package -Force
        throw "The $Name $Version package has SHA-256 $hash, but $Sha256 is pinned. Nothing was installed."
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    Expand-Archive -LiteralPath $package -DestinationPath $target
    Remove-Item -LiteralPath $package -Force
    # NuGet packaging files, which Save-Module does not keep either.
    foreach ($item in @('_rels', 'package', '[Content_Types].xml', '.signature.p7s', "$Name.nuspec")) {
        $path = Join-Path -Path $target -ChildPath $item
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

foreach ($name in $requiredModules) {
    $version = [version]$pinned[$name].Version
    if (Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq $version }) {
        continue
    }
    if (-not $Install) {
        throw ("$name $version was not found. Run this script again with -Install to download it into out/modules " +
            '(nothing is installed outside the repository), or install it yourself: ' +
            "Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser")
    }
    Save-PinnedModule -Name $name -Version $pinned[$name].Version -Sha256 $pinned[$name].Sha256 -Destination $moduleDirectory
}

Write-Information ("PowerShell {0} ({1}) on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [System.Environment]::OSVersion.VersionString)
$failed = $false

if ($Stage -in @('All', 'Analyze')) {
    Import-Module -Name PSScriptAnalyzer -RequiredVersion $pinned.PSScriptAnalyzer.Version -Force
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
    Import-Module -Name Pester -RequiredVersion $pinned.Pester.Version -Force
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
        # Pester measures commands (breakpoints), not lines.
        $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
        Write-Information ("Command coverage of src/ItOpsToolkit (Pester): {0}% ({1} of {2} commands)" -f $coverage, $result.CodeCoverage.CommandsExecutedCount, $result.CodeCoverage.CommandsAnalyzedCount)
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
