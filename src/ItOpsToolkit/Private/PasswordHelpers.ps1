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

function ConvertFrom-ItoSecureString {
    <#
    .SYNOPSIS
        Reads a SecureString into a string. Used only to build the encrypted delivery message.
    .DESCRIPTION
        ConvertFrom-SecureString -AsPlainText only exists in PowerShell 7, so this uses the
        Marshal class, which works in both editions, and zeroes the unmanaged copy afterwards.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString] $SecureString
    )

    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
}

function Assert-ItoDeliveryCertificate {
    <#
    .SYNOPSIS
        Fails early when the delivery certificate cannot encrypt CMS messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Certificate
    )

    if ($Certificate -is [string] -and -not (Test-Path -LiteralPath $Certificate -PathType Leaf)) {
        throw "The delivery certificate file '$Certificate' does not exist."
    }
    try {
        $null = Protect-CmsMessage -To $Certificate -Content 'certificate check' -ErrorAction Stop
    }
    catch {
        throw ('The delivery certificate cannot be used for encryption: {0} ' +
            'It needs the Document Encryption enhanced key usage (1.3.6.1.4.1.311.80.1) and the Key Encipherment key usage.') -f $_.Exception.Message
    }
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
        [object] $Certificate
    )

    $path = Join-Path -Path $Directory -ChildPath ('{0}.cms' -f $SamAccountName)
    $lines = @(
        ('Account: {0}' -f $SamAccountName)
        ('Sign-in name: {0}' -f $UserPrincipalName)
        ('Initial password: {0}' -f (ConvertFrom-ItoSecureString -SecureString $Password))
        'The user must choose a new password at first sign-in.'
    )
    Protect-CmsMessage -To $Certificate -Content ($lines -join "`n") -OutFile $path -ErrorAction Stop
    $path
}
