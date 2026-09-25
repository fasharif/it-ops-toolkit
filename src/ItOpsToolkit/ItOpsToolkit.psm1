#Requires -Version 5.1
Set-StrictMode -Version 3.0

# Private helpers first, so public functions can rely on them at load time.
$privateFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -File)
$publicFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -File)

foreach ($file in ($privateFiles + $publicFiles)) {
    . $file.FullName
}

# Short default views for the result objects. Every property is still there with Format-List *.
$defaultViews = @{
    'ItOpsToolkit.OnboardingResult'  = @('Row', 'SamAccountName', 'Department', 'Status', 'Message')
    'ItOpsToolkit.OffboardingResult' = @('SamAccountName', 'TicketNumber', 'Status', 'Actions')
    'ItOpsToolkit.HealthReport'      = @('ComputerName', 'GeneratedAtUtc', 'OverallStatus', 'Checks')
    'ItOpsToolkit.HealthCheck'       = @('Name', 'Status', 'Value', 'Threshold')
    'ItOpsToolkit.NetworkDiagnosis'  = @('Target', 'Port', 'Healthy', 'Diagnosis')
    'ItOpsToolkit.NetworkLayer'      = @('Layer', 'Status', 'Detail')
    'ItOpsToolkit.LockoutReport'     = @('SamAccountName', 'LockedOut', 'AccountLockoutTime', 'Sources', 'Advice')
}
foreach ($typeName in $defaultViews.Keys) {
    Update-TypeData -TypeName $typeName -DefaultDisplayPropertySet $defaultViews[$typeName] -Force
}

Export-ModuleMember -Function ($publicFiles | ForEach-Object { $_.BaseName })
