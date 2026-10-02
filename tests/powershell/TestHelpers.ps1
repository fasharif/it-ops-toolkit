# Shared helpers, dot-sourced by the test files in BeforeAll.

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ModuleManifest = Join-Path -Path $script:RepoRoot -ChildPath 'src/ItOpsToolkit/ItOpsToolkit.psd1'
$script:StubModule = Join-Path -Path $PSScriptRoot -ChildPath 'stubs/ActiveDirectoryStub.psm1'

function Import-TestModule {
    Import-Module -Name $script:StubModule -Force -Global -Verbose:$false
    Import-Module -Name $script:ModuleManifest -Force -Verbose:$false
}

function ConvertFrom-TestSecureString {
    param([Parameter(Mandatory)] [securestring] $SecureString)
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
}

function New-TestConfigFile {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string] $Format = 'first.last'
    )
    $config = [ordered]@{
        upnSuffix            = 'corp.itops.test'
        samAccountNameFormat = $Format
        disabledOu           = 'OU=Disabled Users,DC=corp,DC=itops,DC=test'
        defaultGroups        = @('All-Staff')
        departments          = [ordered]@{
            Finance = [ordered]@{ ou = 'OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'; groups = @('Finance-Users', 'Finance-Share-RW') }
            Sales   = [ordered]@{ ou = 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'; groups = @('Sales-Users') }
            IT      = [ordered]@{ ou = 'OU=IT,OU=Staff,DC=corp,DC=itops,DC=test'; groups = @() }
        }
    }
    $path = Join-Path -Path $Directory -ChildPath ('onboarding-{0}.json' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $path -Value ($config | ConvertTo-Json -Depth 5) -Encoding UTF8
    $path
}

function New-TestDeliveryCertificate {
    # A self-signed certificate with the Document Encryption EKU, which Protect-CmsMessage requires.
    param([Parameter(Mandatory)] [string] $Directory)

    $x509 = 'System.Security.Cryptography.X509Certificates'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = New-Object -TypeName "$x509.CertificateRequest" -ArgumentList 'CN=ItOpsToolkit Test Delivery', $rsa,
        ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $usage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DataEncipherment
    $request.CertificateExtensions.Add((New-Object -TypeName "$x509.X509KeyUsageExtension" -ArgumentList $usage, $false))
    $oids = New-Object -TypeName System.Security.Cryptography.OidCollection
    [void]$oids.Add((New-Object -TypeName System.Security.Cryptography.Oid -ArgumentList '1.3.6.1.4.1.311.80.1'))
    $request.CertificateExtensions.Add((New-Object -TypeName "$x509.X509EnhancedKeyUsageExtension" -ArgumentList $oids, $false))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(7))

    $cerPath = Join-Path -Path $Directory -ChildPath 'delivery.cer'
    [System.IO.File]::WriteAllBytes($cerPath, $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $pfx = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'pester')
    $withKey = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, 'pester',
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    @{
        CerPath     = $cerPath
        Certificate = $withKey
    }
}

function New-TestAdUser {
    # The shape of a Get-ADUser result, with the properties the toolkit reads.
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [string] $DistinguishedName = ('CN={0},OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test' -f $SamAccountName),
        [bool] $Enabled = $true,
        [string[]] $MemberOf = @(),
        [string] $Description = ''
    )
    [pscustomobject]@{
        SamAccountName    = $SamAccountName
        UserPrincipalName = '{0}@corp.itops.test' -f $SamAccountName
        DistinguishedName = $DistinguishedName
        Enabled           = $Enabled
        MemberOf          = $MemberOf
        Description       = $Description
    }
}
