function Test-ItoNetwork {
    <#
    .SYNOPSIS
        Troubleshoots a network connection layer by layer and ends with a plain-language diagnosis.

    .DESCRIPTION
        Test-ItoNetwork works up the stack, the way a service desk analyst would:

        1. IP configuration: is an adapter up with a usable IPv4 address? A 169.254.x.x address
           means DHCP did not answer.
        2. Default gateway: is one configured, and does it answer ping? (Many routers ignore ping,
           so no answer is a warning, not a failure.)
        3. DNS servers: are any configured?
        4. DNS resolution: does the target name resolve? If not, a control name is tried to tell
           "this name does not exist" apart from "DNS is down".
        5. TCP port: does the target accept a connection on the port?
        6. HTTPS: for port 443, does a TLS handshake and HTTP request succeed?
        7. Route trace: how many hops to the target, or where replies stop.

        The diagnosis names the lowest layer that failed and says what to do next. The
        command only reads; it changes no settings.

        It uses .NET networking classes rather than Windows-only cmdlets. It has been run in
        Windows PowerShell 5.1 on Windows 11 and in PowerShell 7.5 on Linux (see docs/samples).
        PowerShell 7 on Windows and macOS have not been tried yet.

    .PARAMETER ComputerName
        Host name or IP address to test. The default is www.microsoft.com.

    .PARAMETER Port
        TCP port to test. The default is 443. The HTTPS layer runs only for port 443.

    .PARAMETER TimeoutSeconds
        Timeout for each probe, from 1 to 60 seconds. The default is 3.

    .PARAMETER ControlName
        A name that should always resolve, used to tell a missing DNS record apart from a DNS
        outage. The default is www.microsoft.com. On a network without internet access, use an
        internal name such as the domain name.

    .PARAMETER SkipHttps
        Skips the HTTPS layer.

    .PARAMETER SkipTrace
        Skips the route trace, which can take up to MaxHops x TimeoutSeconds when hops do not answer.

    .PARAMETER MaxHops
        Maximum hops for the route trace, from 1 to 30. The default is 15.

    .EXAMPLE
        Test-ItoNetwork

        Checks the path to the internet (www.microsoft.com on port 443).

    .EXAMPLE
        Test-ItoNetwork -ComputerName mail.corp.example.com -Port 443 | Select-Object -ExpandProperty Layers

        Shows each layer's result for the mail server.

    .EXAMPLE
        Test-ItoNetwork -ComputerName fs01.corp.example.com -Port 445 -ControlName corp.example.com -SkipTrace

        Checks SMB file share access on an internal network without internet access.

    .OUTPUTS
        ItOpsToolkit.NetworkDiagnosis

    .LINK
        Get-ItoHealthReport
    #>
    [CmdletBinding()]
    [OutputType('ItOpsToolkit.NetworkDiagnosis')]
    param(
        [Parameter(Position = 0)]
        [Alias('Target')]
        [ValidatePattern('^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|[0-9A-Fa-f:.]{2,45})$')]
        [string] $ComputerName = 'www.microsoft.com',

        [ValidateRange(1, 65535)]
        [int] $Port = 443,

        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 3,

        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$')]
        [string] $ControlName = 'www.microsoft.com',

        [switch] $SkipHttps,

        [switch] $SkipTrace,

        [ValidateRange(1, 30)]
        [int] $MaxHops = 15
    )

    $timeout = $TimeoutSeconds * 1000
    $layers = New-Object -TypeName System.Collections.Generic.List[object]
    $parsedAddress = $null
    $targetIsAddress = [System.Net.IPAddress]::TryParse($ComputerName, [ref]$parsedAddress)

    # 1. IP configuration
    Write-Verbose 'Layer 1: IP configuration.'
    $interfaces = @(Get-ItoNetworkInterfaceData)
    $usable = @($interfaces | Where-Object { @($_.IPv4Addresses | Where-Object { $_ -notlike '169.254.*' }).Count -gt 0 })
    $selfAssigned = @($interfaces | Where-Object { @($_.IPv4Addresses | Where-Object { $_ -like '169.254.*' }).Count -gt 0 })
    $ipFailed = $true
    if ($interfaces.Count -eq 0) {
        $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'IP configuration' -Status 'Fail' -Code 'NoAdapter' -Detail 'No network adapter is up.'))
    }
    elseif ($usable.Count -eq 0 -and $selfAssigned.Count -gt 0) {
        $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'IP configuration' -Status 'Fail' -Code 'Apipa' -Detail ('Only self-assigned addresses: {0} on {1}.' -f ($selfAssigned[0].IPv4Addresses -join ', '), $selfAssigned[0].Name)))
    }
    elseif ($usable.Count -eq 0) {
        $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'IP configuration' -Status 'Fail' -Code 'NoAddress' -Detail 'Adapters are up, but none has an IPv4 address.'))
    }
    else {
        $ipFailed = $false
        # Prefer the adapter that has a gateway: VPN and virtual switch adapters often do not.
        $primary = (@($usable | Where-Object { $_.Gateways.Count -gt 0 }) + $usable) | Select-Object -First 1
        $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'IP configuration' -Status 'Pass' -Code 'Ok' -Detail ('{0}: {1}' -f $primary.Name, ($primary.IPv4Addresses -join ', ')) -Data $primary))
    }

    if ($ipFailed) {
        foreach ($name in @('Default gateway', 'DNS servers', 'DNS resolution', 'TCP port', 'HTTPS', 'Route trace')) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer $name -Status 'Skip' -Code 'Skipped' -Detail 'Skipped because there is no usable IP configuration.'))
        }
    }
    else {
        # 2. Default gateway
        Write-Verbose 'Layer 2: default gateway.'
        if ($primary.Gateways.Count -eq 0) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Default gateway' -Status 'Fail' -Code 'NoGateway' -Detail 'No default gateway is configured.'))
        }
        else {
            $gateway = $primary.Gateways[0]
            $reply = Invoke-ItoPing -Address $gateway -TimeoutMilliseconds $timeout -Ttl 128
            if ($reply.Status -eq 'Success') {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Default gateway' -Status 'Pass' -Code 'Ok' -Detail ('{0} answers ping ({1} ms).' -f $gateway, $reply.RoundtripTime)))
            }
            else {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Default gateway' -Status 'Warn' -Code 'GatewayNoReply' -Detail ('{0} did not answer ping ({1}).' -f $gateway, $reply.Status)))
            }
        }

        # 3. DNS servers
        Write-Verbose 'Layer 3: DNS servers.'
        # Windows lists fec0:0:0:ffff::1, ::2 and ::3 (deprecated site-local placeholders) as IPv6
        # DNS servers when none is configured; they are not real servers, so leave them out.
        $dnsServers = @($usable | ForEach-Object { $_.DnsServers } | Where-Object { $_ -and $_ -notmatch '^fec0:0:0:ffff::[1-3](%\d+)?$' } | Select-Object -Unique)
        if ($dnsServers.Count -eq 0) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS servers' -Status 'Warn' -Code 'NoDnsServers' -Detail 'No DNS servers are configured on the active adapters.'))
        }
        else {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS servers' -Status 'Pass' -Code 'Ok' -Detail ('DNS servers: {0}.' -f ($dnsServers -join ', '))))
        }

        # 4. DNS resolution
        Write-Verbose 'Layer 4: DNS resolution.'
        $addresses = @()
        if ($targetIsAddress) {
            $addresses = @($ComputerName)
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS resolution' -Status 'Skip' -Code 'Skipped' -Detail 'The target is an IP address, so no name lookup is needed.'))
        }
        else {
            try {
                $addresses = @(Resolve-ItoHostAddress -Name $ComputerName)
                if ($addresses.Count -eq 0) {
                    throw "No addresses returned for '$ComputerName'."
                }
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS resolution' -Status 'Pass' -Code 'Ok' -Detail ('{0} resolves to {1}.' -f $ComputerName, ($addresses -join ', '))))
            }
            catch {
                $lookupError = $_.Exception.GetBaseException().Message
                $addresses = @()
                $controlWorks = $false
                if ($ControlName -ne $ComputerName) {
                    try {
                        $controlWorks = @(Resolve-ItoHostAddress -Name $ControlName).Count -gt 0
                    }
                    catch {
                        $controlWorks = $false
                    }
                }
                if ($controlWorks) {
                    $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS resolution' -Status 'Fail' -Code 'NameNotFound' -Detail ("'{0}' did not resolve ({1}), but '{2}' did." -f $ComputerName, $lookupError, $ControlName)))
                }
                else {
                    $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'DNS resolution' -Status 'Fail' -Code 'DnsDown' -Detail ("'{0}' did not resolve ({1}), and neither did the control name '{2}'." -f $ComputerName, $lookupError, $ControlName)))
                }
            }
        }

        # 5. TCP port
        Write-Verbose 'Layer 5: TCP port.'
        $tcpPassed = $false
        if ($addresses.Count -eq 0) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'TCP port' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped because the name did not resolve.'))
        }
        else {
            $address = $addresses[0]
            $tcp = Test-ItoTcpConnection -Address $address -Port $Port -TimeoutMilliseconds $timeout
            if ($tcp.Connected) {
                $tcpPassed = $true
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'TCP port' -Status 'Pass' -Code 'Ok' -Detail ('Connected to {0} on port {1}.' -f $address, $Port)))
            }
            else {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'TCP port' -Status 'Fail' -Code ('Tcp' + $tcp.Reason) -Detail ('No connection to {0} on port {1}: {2}' -f $address, $Port, $tcp.Error)))
            }
        }

        # 6. HTTPS
        Write-Verbose 'Layer 6: HTTPS.'
        if ($SkipHttps -or $Port -ne 443) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'HTTPS' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped: the HTTPS check runs for port 443 only.'))
        }
        elseif (-not $tcpPassed) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'HTTPS' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped because the TCP connection failed.'))
        }
        else {
            $uriHost = $ComputerName
            if ($targetIsAddress -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $uriHost = '[{0}]' -f $ComputerName
            }
            $https = Invoke-ItoHttpsProbe -Uri ('https://{0}:{1}/' -f $uriHost, $Port) -TimeoutMilliseconds $timeout
            if ($https.Succeeded) {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'HTTPS' -Status 'Pass' -Code 'Ok' -Detail ('TLS handshake completed; the server answered with HTTP status {0}.' -f $https.StatusCode)))
            }
            else {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'HTTPS' -Status 'Fail' -Code ('Https' + $https.Reason) -Detail $https.Error))
            }
        }

        # 7. Route trace
        Write-Verbose 'Layer 7: route trace.'
        if ($SkipTrace) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped (-SkipTrace).'))
        }
        elseif ($addresses.Count -eq 0) {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped because there is no address to trace.'))
        }
        elseif ($addresses[0] -match ':') {
            $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Skip' -Code 'Skipped' -Detail 'Skipped: the trace supports IPv4 targets only.'))
        }
        else {
            $hops = @(Invoke-ItoTraceRoute -Address $addresses[0] -MaxHops $MaxHops -TimeoutMilliseconds ([math]::Min($timeout, 1000)))
            $answered = @($hops | Where-Object { $null -ne $_.Address })
            $last = $hops[$hops.Count - 1]
            if ($last.Status -eq 'Success') {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Info' -Code 'TraceReached' -Detail ('Reached {0} in {1} hop(s).' -f $addresses[0], $hops.Count) -Data $hops))
            }
            elseif ($answered.Count -gt 0) {
                $lastAnswer = $answered[$answered.Count - 1]
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Info' -Code 'TraceStopped' -Detail ('The trace stops after hop {0} ({1}); later hops did not answer within {2} hops.' -f $lastAnswer.Hop, $lastAnswer.Address, $hops.Count) -Data $hops))
            }
            else {
                $layers.Add((ConvertTo-ItoNetworkLayer -Layer 'Route trace' -Status 'Info' -Code 'TraceSilent' -Detail 'No hop answered. ICMP is probably blocked on this network, so the trace cannot show the path.' -Data $hops))
            }
        }
    }

    $layerArray = $layers.ToArray()
    $diagnosis = Get-ItoNetworkDiagnosis -Layers $layerArray -Target $ComputerName -Port $Port
    [pscustomobject]@{
        PSTypeName   = 'ItOpsToolkit.NetworkDiagnosis'
        Target       = $ComputerName
        Port         = $Port
        Healthy      = $null -eq $diagnosis.FailedLayer
        FailedLayer  = $diagnosis.FailedLayer
        Diagnosis    = $diagnosis.Text
        Layers       = $layerArray
        CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}
