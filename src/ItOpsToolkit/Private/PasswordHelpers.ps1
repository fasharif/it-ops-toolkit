function Get-ItoRandomIndex {
    <#
    .SYNOPSIS
        Returns a uniformly distributed integer in [0, Maximum) from a cryptographic generator.
    .DESCRIPTION
        Uses rejection sampling, so there is no modulo bias. RandomNumberGenerator.GetInt32 would
        do the same job but does not exist in .NET Framework, which Windows PowerShell 5.1 runs on.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.RandomNumberGenerator] $Generator,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65536)]
        [int] $Maximum
    )

    $buffer = New-Object -TypeName 'byte[]' -ArgumentList 4
    $range = [uint64]4294967296
    $limit = $range - ($range % [uint64]$Maximum)
    do {
        $Generator.GetBytes($buffer)
        $value = [uint64][BitConverter]::ToUInt32($buffer, 0)
    } while ($value -ge $limit)
    [int]($value % [uint64]$Maximum)
}

function Import-ItoCmsAssembly {
    <#
    .SYNOPSIS
        Loads the .NET CMS (PKCS #7) classes: System.Security in .NET Framework, the
        System.Security.Cryptography.Pkcs assembly that ships with PowerShell 7.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq ('System.Security.Cryptography.Pkcs.EnvelopedCms' -as [type])) {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName 'System.Security'
        }
        else {
            Add-Type -AssemblyName 'System.Security.Cryptography.Pkcs'
        }
    }
}

function Get-ItoStoreCertificate {
    <#
    .SYNOPSIS
        Finds a certificate by thumbprint in the CurrentUser, then the LocalMachine, personal store.
    .OUTPUTS
        The certificate, or nothing when neither store has it.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]{40}$')]
        [string] $Thumbprint
    )

    foreach ($location in @('CurrentUser', 'LocalMachine')) {
        $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList 'My', $location
        try {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly')
            $found = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $Thumbprint, $false)
            if ($found.Count -gt 0) {
                return $found[0]
            }
        }
        catch {
            # Linux has no LocalMachine personal store, and an empty CurrentUser store may not exist yet.
            Write-Verbose "The $location personal certificate store could not be read: $($_.Exception.Message.Trim())"
        }
        finally {
            $store.Close()
        }
    }
}

function Resolve-ItoDeliveryCertificate {
    <#
    .SYNOPSIS
        Turns the -DeliveryCertificate value into a certificate: an X509Certificate2 object, the
        path of a .cer or .pem file, or the thumbprint of a certificate in a personal store.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)]
        [object] $Certificate
    )

    if ($Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
        return $Certificate
    }
    $text = [string]$Certificate
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'The delivery certificate is empty. Give a certificate file, a thumbprint or an X509Certificate2 object.'
    }
    if (Test-Path -LiteralPath $text -PathType Leaf) {
        $path = (Resolve-Path -LiteralPath $text).ProviderPath
        try {
            return New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $path
        }
        catch {
            throw "The delivery certificate file '$text' could not be read as a certificate: $($_.Exception.Message.Trim())"
        }
    }
    $thumbprint = $text -replace '\s', ''
    if ($thumbprint -match '^[0-9A-Fa-f]{40}$') {
        $found = Get-ItoStoreCertificate -Thumbprint $thumbprint
        if ($null -eq $found) {
            throw "No certificate with the thumbprint $thumbprint is in the CurrentUser or LocalMachine personal (My) store."
        }
        return $found
    }
    throw "The delivery certificate '$text' is neither an existing certificate file (.cer or .pem) nor a certificate thumbprint (40 hexadecimal characters)."
}

function Protect-ItoSecretText {
    <#
    .SYNOPSIS
        Encrypts Prefix + the secret + Suffix to a certificate as a PEM-armoured CMS message.
    .DESCRIPTION
        The message is CMS (PKCS #7) enveloped data, AES-256-CBC, with the key encrypted to the
        certificate's RSA key: the same format as Protect-CmsMessage and 'openssl cms -encrypt'.

        It uses the .NET EnvelopedCms class through method calls only. The secret goes from the
        SecureString to a byte array, which is cleared afterwards, and is never turned into a
        string or passed to a command parameter. PowerShell module logging (event 4103) records
        every command's parameter values, so passing the text to Protect-CmsMessage -Content
        would put it in the event log on computers where that logging is enabled.
    .OUTPUTS
        The PEM text, which is safe to write to a file or log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [System.Security.SecureString] $Secret,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Suffix,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    Import-ItoCmsAssembly
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $prefixBytes = $utf8.GetBytes($Prefix)
    $suffixBytes = $utf8.GetBytes($Suffix)
    $characters = [char[]]::new($Secret.Length)
    $secretBytes = [byte[]]::new(0)
    $content = [byte[]]::new(0)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
        [System.Runtime.InteropServices.Marshal]::Copy($pointer, $characters, 0, $characters.Length)
        $secretBytes = $utf8.GetBytes($characters)
        $content = [byte[]]::new($prefixBytes.Length + $secretBytes.Length + $suffixBytes.Length)
        [System.Buffer]::BlockCopy($prefixBytes, 0, $content, 0, $prefixBytes.Length)
        [System.Buffer]::BlockCopy($secretBytes, 0, $content, $prefixBytes.Length, $secretBytes.Length)
        [System.Buffer]::BlockCopy($suffixBytes, 0, $content, $prefixBytes.Length + $secretBytes.Length, $suffixBytes.Length)

        $aes256 = [System.Security.Cryptography.Pkcs.AlgorithmIdentifier]::new([System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.42'))
        $envelope = [System.Security.Cryptography.Pkcs.EnvelopedCms]::new([System.Security.Cryptography.Pkcs.ContentInfo]::new($content), $aes256)
        $envelope.Encrypt([System.Security.Cryptography.Pkcs.CmsRecipient]::new($Certificate))
        $base64 = [Convert]::ToBase64String($envelope.Encode())
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
        }
        [Array]::Clear($characters, 0, $characters.Length)
        [Array]::Clear($secretBytes, 0, $secretBytes.Length)
        [Array]::Clear($content, 0, $content.Length)
    }

    $pem = New-Object -TypeName System.Text.StringBuilder
    [void]$pem.Append("-----BEGIN CMS-----`n")
    for ($offset = 0; $offset -lt $base64.Length; $offset += 64) {
        [void]$pem.Append($base64.Substring($offset, [Math]::Min(64, $base64.Length - $offset))).Append("`n")
    }
    [void]$pem.Append("-----END CMS-----`n")
    $pem.ToString()
}

function Assert-ItoDeliveryCertificate {
    <#
    .SYNOPSIS
        Resolves the delivery certificate and fails early when it cannot encrypt delivery files.
    .OUTPUTS
        The certificate, as an X509Certificate2.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)]
        [object] $Certificate
    )

    $resolved = Resolve-ItoDeliveryCertificate -Certificate $Certificate
    $problem = $null
    $eku = @($resolved.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
    $keyUsage = @($resolved.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension] })
    if ($resolved.PublicKey.Oid.Value -ne '1.2.840.113549.1.1.1') {
        $problem = 'its public key is not an RSA key.'
    }
    elseif ($eku.Count -eq 0 -or -not (@($eku[0].EnhancedKeyUsages | ForEach-Object { $_.Value }) -contains '1.3.6.1.4.1.311.80.1')) {
        $problem = 'it does not have the Document Encryption enhanced key usage.'
    }
    elseif ($keyUsage.Count -gt 0 -and -not ($keyUsage[0].KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment)) {
        $problem = 'its key usage does not include Key Encipherment.'
    }
    elseif ($resolved.NotAfter -lt (Get-Date)) {
        $problem = 'it expired on {0}.' -f $resolved.NotAfter.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        try {
            $null = Protect-ItoSecretText -Prefix 'certificate check' -Secret (New-Object -TypeName System.Security.SecureString) -Suffix '' -Certificate $resolved
        }
        catch {
            $problem = $_.Exception.Message.Trim()
        }
    }
    if ($null -ne $problem) {
        throw ('The delivery certificate {0} cannot be used for encryption: {1} ' +
            'It needs an RSA key, the Document Encryption enhanced key usage (1.3.6.1.4.1.311.80.1) and the Key Encipherment key usage.') -f $resolved.Subject, $problem
    }
    $resolved
}

function Write-ItoDeliveryFile {
    <#
    .SYNOPSIS
        Writes a CMS-encrypted file with the new account's sign-in details.
    .DESCRIPTION
        Only the holder of the delivery certificate's private key can read the file, for example
        with Unprotect-CmsMessage on Windows or 'openssl cms -decrypt' on Linux.
    .OUTPUTS
        The path of the file written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Directory,

        [Parameter(Mandatory)]
        [string] $SamAccountName,

        [Parameter(Mandatory)]
        [string] $UserPrincipalName,

        [Parameter(Mandatory)]
        [System.Security.SecureString] $Password,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $path = Join-Path -Path $Directory -ChildPath ('{0}.cms' -f $SamAccountName)
    $prefix = "Account: {0}`nSign-in name: {1}`nInitial password: " -f $SamAccountName, $UserPrincipalName
    $suffix = "`nThe user must choose a new password at first sign-in.`n"
    $pem = Protect-ItoSecretText -Prefix $prefix -Secret $Password -Suffix $suffix -Certificate $Certificate
    [System.IO.File]::WriteAllText($path, $pem, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    $path
}
