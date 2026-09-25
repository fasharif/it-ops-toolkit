# Network probes for Test-ItoNetwork. They use .NET classes rather than Windows-only cmdlets
# (Get-NetIPConfiguration, Test-NetConnection), so the same code runs on Windows and Linux.

function Get-ItoNetworkInterfaceData {
    [CmdletBinding()]
    param()

    $up = [System.Net.NetworkInformation.OperationalStatus]::Up
    $loopback = [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
    $ipv4 = [System.Net.Sockets.AddressFamily]::InterNetwork

    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq $up -and $_.NetworkInterfaceType -ne $loopback } |
        ForEach-Object {
            $properties = $_.GetIPProperties()
            [pscustomobject]@{
                Name          = [string]$_.Name
                Description   = [string]$_.Description
                InterfaceType = [string]$_.NetworkInterfaceType
                IPv4Addresses = @($properties.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq $ipv4 } | ForEach-Object { $_.Address.ToString() })
                Gateways      = @($properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq $ipv4 -and $_.Address.ToString() -ne '0.0.0.0' } | ForEach-Object { $_.Address.ToString() })
                DnsServers    = @($properties.DnsAddresses | ForEach-Object { $_.ToString() })
            }
        }
}

function Invoke-ItoPing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [int] $TimeoutMilliseconds = 2000,

        [ValidateRange(1, 255)]
        [int] $Ttl = 128
    )

    $ping = New-Object -TypeName System.Net.NetworkInformation.Ping
    try {
        $options = New-Object -TypeName System.Net.NetworkInformation.PingOptions -ArgumentList $Ttl, $true
        $buffer = New-Object -TypeName 'byte[]' -ArgumentList 32
        $reply = $ping.Send($Address, $TimeoutMilliseconds, $buffer, $options)
        $replyAddress = $null
        if ($null -ne $reply.Address -and $reply.Address.ToString() -ne '0.0.0.0') {
            $replyAddress = $reply.Address.ToString()
        }
        [pscustomobject]@{
            Status        = [string]$reply.Status
            Address       = $replyAddress
            RoundtripTime = [long]$reply.RoundtripTime
            Error         = $null
        }
    }
    catch {
        [pscustomobject]@{
            Status        = 'Error'
            Address       = $null
            RoundtripTime = 0
            Error         = $_.Exception.GetBaseException().Message
        }
    }
    finally {
        $ping.Dispose()
    }
}

function Resolve-ItoHostAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    # IPv4 first: the gateway and trace layers are IPv4.
    [System.Net.Dns]::GetHostAddresses($Name) |
        Sort-Object -Property @{ Expression = { [int]$_.AddressFamily } } |
        ForEach-Object { $_.ToString() }
}

function Test-ItoTcpConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [int] $Port,

        [int] $TimeoutMilliseconds = 3000
    )

    $ip = [System.Net.IPAddress]::Parse($Address)
    $client = New-Object -TypeName System.Net.Sockets.TcpClient -ArgumentList $ip.AddressFamily
    try {
        $task = $client.ConnectAsync($ip, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) {
            return [pscustomobject]@{ Connected = $false; Reason = 'Timeout'; Error = "No answer within $TimeoutMilliseconds ms." }
        }
        [pscustomobject]@{ Connected = [bool]$client.Connected; Reason = $null; Error = $null }
    }
    catch {
        $base = $_.Exception.GetBaseException()
        $reason = 'Error'
        if ($base -is [System.Net.Sockets.SocketException]) {
            switch ([string]$base.SocketErrorCode) {
                'ConnectionRefused' { $reason = 'Refused' }
                'TimedOut' { $reason = 'Timeout' }
                'HostUnreachable' { $reason = 'Unreachable' }
                'NetworkUnreachable' { $reason = 'Unreachable' }
            }
        }
        [pscustomobject]@{ Connected = $false; Reason = $reason; Error = $base.Message }
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-ItoHttpsProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [int] $TimeoutMilliseconds = 5000
    )

    # Windows PowerShell 5.1 on older .NET Framework builds may not offer TLS 1.2 by default.
    $protocols = [System.Net.ServicePointManager]::SecurityProtocol
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    if ([int]$protocols -ne 0 -and ($protocols -band $tls12) -ne $tls12) {
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols -bor $tls12
    }

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'HEAD'
    $request.Timeout = $TimeoutMilliseconds
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'ItOpsToolkit (Test-ItoNetwork)'
    try {
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Close()
        [pscustomobject]@{ Succeeded = $true; StatusCode = $code; Reason = $null; Error = $null }
    }
    catch [System.Net.WebException] {
        $exception = $_.Exception
        if ($null -ne $exception.Response) {
            # Any HTTP answer, even 403 or 500, proves the network path and TLS work.
            $code = [int]$exception.Response.StatusCode
            $exception.Response.Close()
            return [pscustomobject]@{ Succeeded = $true; StatusCode = $code; Reason = $null; Error = $null }
        }
        $reason = switch ([string]$exception.Status) {
            'TrustFailure' { 'Tls' }
            'SecureChannelFailure' { 'Tls' }
            'Timeout' { 'Timeout' }
            'ProxyNameResolutionFailure' { 'Proxy' }
            'NameResolutionFailure' { 'Name' }
            'ConnectFailure' { 'Connect' }
            default { 'Other' }
        }
        [pscustomobject]@{ Succeeded = $false; StatusCode = $null; Reason = $reason; Error = $exception.GetBaseException().Message }
    }
    catch {
        [pscustomobject]@{ Succeeded = $false; StatusCode = $null; Reason = 'Other'; Error = $_.Exception.GetBaseException().Message }
    }
}

function Invoke-ItoTraceRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [ValidateRange(1, 30)]
        [int] $MaxHops = 15,

        [int] $TimeoutMilliseconds = 1000
    )

    $hops = New-Object -TypeName System.Collections.Generic.List[object]
    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        $reply = Invoke-ItoPing -Address $Address -TimeoutMilliseconds $TimeoutMilliseconds -Ttl $ttl
        $hops.Add([pscustomobject]@{ Hop = $ttl; Address = $reply.Address; Status = $reply.Status })
        if ($reply.Status -eq 'Success') {
            break
        }
    }
    $hops.ToArray()
}
