function New-ItoUser {
    <#
    .SYNOPSIS
        Creates Active Directory accounts for new starters from an HR feed (CSV).

    .DESCRIPTION
        For each row of the HR feed, New-ItoUser:

        1. Validates the row: required fields, allowed characters, a known department and the date format.
        2. Skips the row when an account with the same employeeID already exists, so the same
           feed can be run again safely. If that account is not in all the configured groups
           (for example because a group add failed on the first run), the result has a warning
           for each missing group; the groups are not added automatically.
        3. Checks that the department's OU and groups exist before creating anything.
        4. Generates a unique sAMAccountName (first.last or flast, at most 20 characters). When a
           name is taken, a number is appended: sara.ali, sara.ali2, sara.ali3.
        5. Creates the account in the department's OU, enabled, with a strong random initial
           password and "User must change password at next logon" set.
        6. Adds the account to the default groups and the department's groups.
        7. Delivers the initial password as a SecureString on the result object and, with
           -DeliveryPath, as a CMS-encrypted file that only the holder of the delivery
           certificate's private key can read. Without -DeliveryPath, a warning at the end says
           that the passwords are only on the results, so keep them ($results = New-ItoUser ...).

        The initial password is never written to the console, verbose output, warnings or the
        summary file, and it is never passed to a command parameter as text, which is what
        PowerShell module logging records. The delivery file is encrypted with .NET's
        EnvelopedCms class for that reason, rather than with Protect-CmsMessage.

        CSV columns: EmployeeId, GivenName, Surname and Department are required. Title, Manager
        (the manager's sAMAccountName) and StartDate (yyyy-MM-dd) are optional.

        GivenNameLatin and SurnameLatin are optional too: a Latin-script spelling of a name
        written in another script, such as Arabic. The account name and sign-in name are built
        from them, while the display name, given name and surname keep the original spelling.
        A name with no Latin letters and no Latin spelling is reported as Invalid.

        Rows with problems do not stop the batch: each row gets a result with a Status of
        Created, Exists, Planned (with -WhatIf), Invalid or Failed.

        At the end, a one-line count ("Onboarding summary: 3 created, 1 invalid.") goes to the
        information stream, which PowerShell hides by default. Add -InformationAction Continue to
        see it, or use -SummaryPath for the full summary as a CSV file.

    .PARAMETER Path
        Path to the HR feed CSV file (UTF-8, comma-separated, with a header row).

    .PARAMETER InputObject
        Rows as objects or hashtables with the same field names as the CSV columns.

    .PARAMETER ConfigPath
        Path to the JSON configuration that maps departments to OUs and groups. See
        config/onboarding.example.json.

    .PARAMETER DeliveryPath
        Folder for the encrypted password delivery files, one <sAMAccountName>.cms file per new
        account. Requires -DeliveryCertificate.

    .PARAMETER DeliveryCertificate
        The certificate used to encrypt delivery files: a path to a .cer or .pem file, the
        thumbprint of a certificate in the CurrentUser or LocalMachine personal (My) store, or an
        X509Certificate2 object. It needs an RSA key and the Document Encryption enhanced key
        usage. Only the public key is needed here. Requires -DeliveryPath.

    .PARAMETER SummaryPath
        Path of a CSV file for the onboarding summary. It never contains passwords.

    .PARAMETER PasswordLength
        Length of the initial passwords, from 14 to 128. The default is 20.

    .PARAMETER Server
        Domain controller to use for every directory call. Without it, one writable domain
        controller in the computer's domain is found at the start and used for the whole run,
        so accounts created early in the batch are visible to the later steps.

    .PARAMETER Credential
        Credential for the directory operations. Defaults to the current user.

    .EXAMPLE
        New-ItoUser -Path .\new-starters.csv -ConfigPath .\onboarding.json -WhatIf

        Shows which accounts would be created, with their account names and OUs, without changing anything.

    .EXAMPLE
        $results = New-ItoUser -Path .\new-starters.csv -ConfigPath .\onboarding.json `
            -DeliveryPath \\fs01\ServiceDesk\Delivery -DeliveryCertificate .\servicedesk.cer `
            -SummaryPath \\fs01\ServiceDesk\Onboarding\onboarding-2026-09-28.csv -InformationAction Continue
        $results | Format-Table Row, SamAccountName, Status, Message

        Creates the accounts, writes one encrypted delivery file per account and a summary CSV to
        the service desk share, and shows the one-line summary. The summary holds names and
        employee IDs, so keep it out of source control and other shared folders.

    .EXAMPLE
        Unprotect-CmsMessage -Path \\fs01\ServiceDesk\Delivery\sara.ali.cms

        Run by the service desk lead, who holds the certificate's private key, to read a delivery file.

    .INPUTS
        System.Management.Automation.PSObject

    .OUTPUTS
        ItOpsToolkit.OnboardingResult

    .NOTES
        Requires the ActiveDirectory module (RSAT). The account running it needs rights to create
        users in the target OUs and to change membership of the configured groups.

    .LINK
        Remove-ItoUser

    .LINK
        New-ItoRandomPassword
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Path')]
    [OutputType('ItOpsToolkit.OnboardingResult')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'InputObject', ValueFromPipeline)]
        [ValidateNotNull()]
        [object[]] $InputObject,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string] $ConfigPath,

        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $DeliveryPath,

        [ValidateNotNull()]
        [object] $DeliveryCertificate,

        [ValidateNotNullOrEmpty()]
        [string] $SummaryPath,

        [ValidateRange(14, 128)]
        [int] $PasswordLength = 20,

        [ValidateNotNullOrEmpty()]
        [string] $Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        $hasDeliveryPath = $PSBoundParameters.ContainsKey('DeliveryPath')
        $hasDeliveryCertificate = $PSBoundParameters.ContainsKey('DeliveryCertificate')
        if ($hasDeliveryPath -ne $hasDeliveryCertificate) {
            throw 'Use -DeliveryPath and -DeliveryCertificate together: delivery files are always encrypted.'
        }

        Assert-ItoActiveDirectory
        $config = Read-ItoOnboardingConfig -Path $ConfigPath
        $deliveryRecipient = $null
        $deliveryFolder = $null
        if ($hasDeliveryCertificate) {
            $deliveryRecipient = Assert-ItoDeliveryCertificate -Certificate $DeliveryCertificate
            # The delivery files are written with .NET, which resolves a relative path against the
            # process directory. Set-Location does not change that, so resolve the folder here,
            # against the current PowerShell location, as the parameter validation did.
            $deliveryFolder = (Resolve-Path -LiteralPath $DeliveryPath).ProviderPath
        }

        $adParameters = Get-ItoAdParameter -Server $Server -Credential $Credential -PinDomainController
        $reservedNames = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        $seenEmployeeIds = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        $targetCache = @{}
        $results = New-Object -TypeName System.Collections.Generic.List[object]
        $rowNumber = 0
        $fields = @('EmployeeId', 'GivenName', 'Surname', 'Department', 'Title', 'Manager', 'StartDate', 'GivenNameLatin', 'SurnameLatin')
        $today = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $records = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
            if ($records.Count -eq 0) {
                Write-Warning "The HR feed '$Path' has no data rows."
                return
            }
            $columns = @($records[0].PSObject.Properties | ForEach-Object { $_.Name })
            $missingColumns = @('EmployeeId', 'GivenName', 'Surname', 'Department') | Where-Object { $columns -notcontains $_ }
            if (@($missingColumns).Count -gt 0) {
                throw ("The HR feed '{0}' is missing required columns: {1}. Expected columns: {2}." -f $Path, ($missingColumns -join ', '), ($fields -join ', '))
            }
        }
        else {
            $records = $InputObject
        }

        foreach ($record in $records) {
            $rowNumber++
            $row = @{}
            foreach ($field in $fields) {
                $row[$field] = Get-ItoRecordValue -Record $record -Name $field
            }
            $result = ConvertTo-ItoOnboardingResult -Row $rowNumber -Record $row
            $warnings = New-Object -TypeName System.Collections.Generic.List[string]

            $problems = @(Test-ItoOnboardingRecord -Row $row -Config $config)
            if ($problems.Count -eq 0 -and -not $seenEmployeeIds.Add($row.EmployeeId)) {
                $problems = @("EmployeeId '$($row.EmployeeId)' appears more than once in this feed.")
            }
            if ($problems.Count -gt 0) {
                $result.Status = 'Invalid'
                $result.Message = $problems -join ' '
                Write-Warning ('Row {0} was not processed: {1}' -f $rowNumber, $result.Message)
                $results.Add($result)
                $result
                continue
            }

            $department = $config.Departments[$row.Department]
            $groups = @(@($config.DefaultGroups) + @($department.Groups) | Where-Object { $_ } | Select-Object -Unique)
            $result.Department = $department.Name
            $result.OrganizationalUnit = $department.Ou
            $result.Groups = [string[]]$groups

            try {
                $idFilter = '(employeeID={0})' -f (ConvertTo-ItoLdapFilterValue -Value $row.EmployeeId)
                $existing = @(Get-ADUser -LDAPFilter $idFilter -Properties 'employeeID', 'MemberOf' @adParameters)
                if ($existing.Count -gt 0) {
                    $result.Status = 'Exists'
                    $result.SamAccountName = $existing[0].SamAccountName
                    $result.UserPrincipalName = $existing[0].UserPrincipalName
                    $result.Message = "An account with employee ID $($row.EmployeeId) already exists ($($existing[0].SamAccountName)). No changes were made."
                    Write-Verbose $result.Message
                    # Report, but do not add, configured groups the account lacks: an earlier group
                    # add may have failed, or the person may have moved department since.
                    foreach ($group in @(Get-ItoMissingGroup -MemberOf @($existing[0].MemberOf) -Groups $groups -Cache $targetCache -AdParameters $adParameters)) {
                        $warnings.Add("The existing account is not in the configured group '$group'. Check that the person still needs it, then add it by hand.")
                        Write-Warning ('Row {0} ({1}): {2}' -f $rowNumber, $result.SamAccountName, $warnings[$warnings.Count - 1])
                    }
                    $result.Warnings = $warnings.ToArray()
                    $results.Add($result)
                    $result
                    continue
                }

                $targetProblem = Get-ItoOnboardingTargetProblem -Ou $department.Ou -Groups $groups -Cache $targetCache -AdParameters $adParameters
                if ($null -ne $targetProblem) {
                    throw $targetProblem
                }

                $accountNameParts = Get-ItoAccountNamePart -Row $row
                $samAccountName = Resolve-ItoSamAccountName -GivenName $accountNameParts.GivenName -Surname $accountNameParts.Surname `
                    -Format $config.SamAccountNameFormat -UpnSuffix $config.UpnSuffix -Reserved $reservedNames -AdParameters $adParameters
                $userPrincipalName = '{0}@{1}' -f $samAccountName, $config.UpnSuffix
                $displayName = '{0} {1}' -f $row.GivenName, $row.Surname
                $result.SamAccountName = $samAccountName
                $result.UserPrincipalName = $userPrincipalName

                # The CN must be unique in the OU, across every object class. When the name is taken,
                # add the account name, or use the account name alone if that would pass the
                # 64-character limit on CN.
                $commonName = $displayName
                $nameFilter = '(cn={0})' -f (ConvertTo-ItoLdapFilterValue -Value $displayName)
                $sameName = @(Get-ADObject -LDAPFilter $nameFilter -SearchBase $department.Ou -SearchScope OneLevel @adParameters)
                if ($sameName.Count -gt 0) {
                    $commonName = '{0} ({1})' -f $displayName, $samAccountName
                    if ($commonName.Length -gt 64) {
                        $commonName = $samAccountName
                    }
                }

                $managerDn = $null
                if (-not [string]::IsNullOrEmpty($row.Manager)) {
                    $managerFilter = '(sAMAccountName={0})' -f (ConvertTo-ItoLdapFilterValue -Value $row.Manager)
                    $manager = @(Get-ADUser -LDAPFilter $managerFilter @adParameters)
                    if ($manager.Count -gt 0) {
                        $managerDn = $manager[0].DistinguishedName
                    }
                    else {
                        $warnings.Add("Manager '$($row.Manager)' was not found, so no manager was set.")
                    }
                }

                $description = 'Onboarded {0} by ItOpsToolkit' -f $today
                if (-not [string]::IsNullOrEmpty($row.StartDate)) {
                    $description = 'Start date {0}. {1}' -f $row.StartDate, $description
                }

                $target = '{0} ({1}) in {2}' -f $samAccountName, $displayName, $department.Ou
                if (-not $PSCmdlet.ShouldProcess($target, 'Create Active Directory user')) {
                    $result.Status = 'Planned'
                    $result.Message = 'Would create {0} in {1} and add it to {2} group(s).' -f $userPrincipalName, $department.Ou, $groups.Count
                    $result.Warnings = $warnings.ToArray()
                    $results.Add($result)
                    $result
                    continue
                }

                $spellings = '{0} {1} {2}' -f $displayName, $row.GivenNameLatin, $row.SurnameLatin
                $nameParts = @($spellings -split '[,.\-_ #\t]' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
                $password = New-ItoRandomPassword -Length $PasswordLength -ExcludeSubstring (@($samAccountName) + $nameParts)

                $newUser = @{
                    Name                  = $commonName
                    SamAccountName        = $samAccountName
                    UserPrincipalName     = $userPrincipalName
                    GivenName             = $row.GivenName
                    Surname               = $row.Surname
                    DisplayName           = $displayName
                    EmailAddress          = $userPrincipalName
                    EmployeeID            = $row.EmployeeId
                    Department            = $department.Name
                    Description           = $description
                    Path                  = $department.Ou
                    AccountPassword       = $password
                    ChangePasswordAtLogon = $true
                    Enabled               = $true
                    ErrorAction           = 'Stop'
                }
                if (-not [string]::IsNullOrEmpty($row.Title)) {
                    $newUser['Title'] = $row.Title
                }
                if ($null -ne $managerDn) {
                    $newUser['Manager'] = $managerDn
                }
                Write-Verbose "Creating $userPrincipalName in $($department.Ou)."
                New-ADUser @newUser @adParameters
                $result.Status = 'Created'
                $result.InitialPassword = $password

                foreach ($group in $groups) {
                    try {
                        Write-Verbose "Adding $samAccountName to $group."
                        Add-ADGroupMember -Identity $group -Members $samAccountName @adParameters -ErrorAction Stop
                    }
                    catch {
                        $warnings.Add("Could not add the account to group '$group': $($_.Exception.Message.Trim())")
                    }
                }

                if ($hasDeliveryPath) {
                    try {
                        $result.DeliveryFile = Write-ItoDeliveryFile -Directory $deliveryFolder -SamAccountName $samAccountName `
                            -UserPrincipalName $userPrincipalName -Password $password -Certificate $deliveryRecipient
                    }
                    catch {
                        $warnings.Add("The password delivery file could not be written: $($_.Exception.Message.Trim()) The password is still available on the InitialPassword property of this result.")
                    }
                }

                $result.Message = 'Created {0} in {1}.' -f $userPrincipalName, $department.Ou
            }
            catch {
                $result.Status = 'Failed'
                $result.Message = $_.Exception.Message.Trim()
                Write-Warning ('Row {0} failed: {1}' -f $rowNumber, $result.Message)
            }

            foreach ($warning in $warnings) {
                Write-Warning ('Row {0} ({1}): {2}' -f $rowNumber, $result.SamAccountName, $warning)
            }
            $result.Warnings = $warnings.ToArray()
            $results.Add($result)
            $result
        }
    }

    end {
        if ($results.Count -eq 0) {
            return
        }
        $counts = $results | Group-Object -Property Status | Sort-Object -Property Name | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name.ToLowerInvariant() }
        Write-Information -MessageData ('Onboarding summary: {0}.' -f ($counts -join ', ')) -Tags 'Summary'

        # onboard-user.sh refuses a real run without delivery files. New-ItoUser allows it, for
        # scripts that hand the SecureString on themselves, but says where the passwords are.
        $createdCount = @($results | Where-Object { $_.Status -eq 'Created' }).Count
        if (-not $hasDeliveryPath -and $createdCount -gt 0) {
            $message = '{0} account(s) were created without -DeliveryPath, so their initial passwords exist only on the InitialPassword property (a SecureString) of the results. ' +
                'If the results were not kept, for example with $results = New-ItoUser ..., reset those passwords before handing the accounts over. ' +
                'Use -DeliveryPath and -DeliveryCertificate to write encrypted delivery files.'
            Write-Warning ($message -f $createdCount)
        }

        if ($PSBoundParameters.ContainsKey('SummaryPath') -and $PSCmdlet.ShouldProcess($SummaryPath, 'Write onboarding summary CSV')) {
            $results |
                Select-Object -Property Row, EmployeeId, DisplayName, SamAccountName, UserPrincipalName, Department, OrganizationalUnit,
                @{ Name = 'Groups'; Expression = { $_.Groups -join ';' } }, Status, Message,
                @{ Name = 'Warnings'; Expression = { $_.Warnings -join ' | ' } }, DeliveryFile |
                Export-Csv -LiteralPath $SummaryPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
        }
    }
}
