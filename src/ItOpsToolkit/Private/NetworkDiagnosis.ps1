function ConvertTo-ItoNetworkLayer {
    [CmdletBinding()]
    [OutputType('ItOpsToolkit.NetworkLayer')]
    param(
        [Parameter(Mandatory)]
        [string] $Layer,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Skip', 'Info')]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Detail,

        [string] $Code = '',

        [AllowNull()]
        [object] $Data = $null
    )

    [pscustomobject]@{
        PSTypeName = 'ItOpsToolkit.NetworkLayer'
        Layer      = $Layer
        Status     = $Status
        Code       = $Code
        Detail     = $Detail
        Data       = $Data
    }
}

function Get-ItoNetworkDiagnosis {
    <#
    .SYNOPSIS
        Turns the layer results into one plain-language diagnosis, naming the lowest failing layer.
    .OUTPUTS
        A hashtable with Text and FailedLayer ($null when healthy).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Layers,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [int] $Port
    )

    $byName = @{}
    foreach ($layer in $Layers) {
        $byName[$layer.Layer] = $layer
    }
    $code = @{}
    foreach ($name in $byName.Keys) {
        $code[$name] = $byName[$name].Code
    }
    $gatewayQuiet = $code['Default gateway'] -eq 'GatewayNoReply'

    switch ($code['IP configuration']) {
        'NoAdapter' {
            return @{ FailedLayer = 'IP configuration'; Text = 'No network adapter is connected. Check the cable or Wi-Fi connection, and that the adapter is enabled (flight mode off, adapter not disabled in Network Connections).' }
        }
        'Apipa' {
            return @{ FailedLayer = 'IP configuration'; Text = 'The computer gave itself a 169.254.x.x address, which means no DHCP server answered. Reconnect to the network and run "ipconfig /renew". If it persists, check the switch port, the Wi-Fi network or the DHCP scope (it may be full).' }
        }
        'NoAddress' {
            return @{ FailedLayer = 'IP configuration'; Text = 'The network adapter is up but has no IPv4 address. Check the adapter settings (DHCP or static) and reconnect.' }
        }
    }

    if ($code['Default gateway'] -eq 'NoGateway') {
        return @{ FailedLayer = 'Default gateway'; Text = 'No default gateway is configured, so traffic cannot leave the local network. Check the DHCP options or the static IP settings (IP address, subnet mask and gateway).' }
    }

    $dns = $byName['DNS resolution']
    if ($null -ne $dns -and $dns.Status -eq 'Fail') {
        if ($code['DNS servers'] -eq 'NoDnsServers') {
            return @{ FailedLayer = 'DNS resolution'; Text = "No DNS servers are configured, so '$Target' cannot be turned into an address. Set the DNS servers (normally through DHCP) and try again." }
        }
        if ($dns.Code -eq 'NameNotFound') {
            return @{ FailedLayer = 'DNS resolution'; Text = "DNS works, but the name '$Target' does not resolve. Check the spelling. For an internal name, check that the record exists and that you are on the office network or VPN (split DNS)." }
        }
        $suffix = ''
        if ($gatewayQuiet) {
            $suffix = ' The default gateway did not answer either, so the local network is the most likely cause.'
        }
        return @{ FailedLayer = 'DNS resolution'; Text = "Name resolution is failing: the DNS servers did not answer. Run 'ipconfig /flushdns', check that the DNS servers are reachable, and check any VPN or proxy client.$suffix" }
    }

    $tcp = $byName['TCP port']
    if ($null -ne $tcp -and $tcp.Status -eq 'Fail') {
        if ($gatewayQuiet) {
            return @{ FailedLayer = 'TCP port'; Text = "The default gateway does not answer and port $Port on '$Target' cannot be reached. The fault is most likely on the local network: cable, Wi-Fi, switch or router." }
        }
        if ($tcp.Code -eq 'TcpRefused') {
            return @{ FailedLayer = 'TCP port'; Text = "'$Target' answered but refused port $Port. The service is not running or not listening on that port, or a firewall is actively rejecting the connection." }
        }
        $traceHint = ''
        $trace = $byName['Route trace']
        if ($null -ne $trace -and $trace.Status -eq 'Info' -and $trace.Code -eq 'TraceStopped') {
            $traceHint = " $($trace.Detail)"
        }
        return @{ FailedLayer = 'TCP port'; Text = "Port $Port on '$Target' did not answer. A firewall is probably dropping the traffic, or the server is down.$traceHint" }
    }

    $https = $byName['HTTPS']
    if ($null -ne $https -and $https.Status -eq 'Fail') {
        switch ($https.Code) {
            'HttpsTls' {
                return @{ FailedLayer = 'HTTPS'; Text = "Port $Port on '$Target' accepts connections, but the HTTPS handshake failed ($($https.Detail)). Check the computer's date and time, the proxy settings, and whether a TLS inspection certificate is missing from the trusted root store." }
            }
            'HttpsTimeout' {
                return @{ FailedLayer = 'HTTPS'; Text = "Port $Port on '$Target' accepts connections, but the web server did not answer in time. The server may be overloaded, or a proxy or firewall is holding the request." }
            }
            'HttpsProxy' {
                return @{ FailedLayer = 'HTTPS'; Text = "The proxy server could not be found. Check the proxy settings (Settings > Network and Internet > Proxy, or the PAC file)." }
            }
            default {
                return @{ FailedLayer = 'HTTPS'; Text = "Port $Port on '$Target' accepts connections, but the HTTPS request failed: $($https.Detail)" }
            }
        }
    }

    if ($null -ne $https -and $https.Status -eq 'Pass') {
        $text = "No fault found: '$Target' resolves, port $Port accepts connections and HTTPS answers."
    }
    else {
        $text = "No fault found: '$Target' resolves and port $Port accepts connections."
    }
    if ($gatewayQuiet) {
        $text += ' The default gateway does not answer ping, which many routers and firewalls do by design.'
    }
    if ($code['DNS servers'] -eq 'NoDnsServers') {
        $text += ' No DNS servers are listed for the adapter; this is normal on some VPN clients.'
    }
    @{ FailedLayer = $null; Text = $text }
}
