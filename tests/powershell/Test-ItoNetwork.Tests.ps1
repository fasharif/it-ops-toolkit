BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-TestModule

    function Get-Layer {
        param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string] $Name)
        $Result.Layers | Where-Object { $_.Layer -eq $Name }
    }
}

Describe 'Test-ItoNetwork diagnosis' {
    BeforeEach {
        # A working network. Each test breaks one layer.
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Wi-Fi'; Description = 'Intel Wi-Fi 6'; InterfaceType = 'Wireless80211'; IPv4Addresses = @('192.168.1.23'); Gateways = @('192.168.1.1'); DnsServers = @('192.168.1.1') }
        }
        Mock -ModuleName ItOpsToolkit Invoke-ItoPing { [pscustomobject]@{ Status = 'Success'; Address = $Address; RoundtripTime = 3; Error = $null } }
        Mock -ModuleName ItOpsToolkit Resolve-ItoHostAddress { '203.0.113.10' }
        Mock -ModuleName ItOpsToolkit Test-ItoTcpConnection { [pscustomobject]@{ Connected = $true; Reason = $null; Error = $null } }
        Mock -ModuleName ItOpsToolkit Invoke-ItoHttpsProbe { [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Reason = $null; Error = $null } }
        Mock -ModuleName ItOpsToolkit Invoke-ItoTraceRoute {
            [pscustomobject]@{ Hop = 1; Address = '192.168.1.1'; Status = 'TtlExpired' }
            [pscustomobject]@{ Hop = 2; Address = '203.0.113.10'; Status = 'Success' }
        }
    }

    It 'reports a healthy path when every layer passes' {
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.PSObject.TypeNames | Should -Contain 'ItOpsToolkit.NetworkDiagnosis'
        $result.Healthy | Should -BeTrue
        $result.FailedLayer | Should -BeNullOrEmpty
        $result.Diagnosis | Should -Be "No fault found: 'portal.example.com' resolves, port 443 accepts connections and HTTPS answers."
        $result.Layers.Layer | Should -Be @('IP configuration', 'Default gateway', 'DNS servers', 'DNS resolution', 'TCP port', 'HTTPS', 'Route trace')
        $result.Layers.Status | Should -Be @('Pass', 'Pass', 'Pass', 'Pass', 'Pass', 'Pass', 'Info')
        (Get-Layer $result 'Route trace').Detail | Should -Be 'Reached 203.0.113.10 in 2 hop(s).'
    }

    It 'diagnoses a missing network connection and skips the other layers' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData { }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.Healthy | Should -BeFalse
        $result.FailedLayer | Should -Be 'IP configuration'
        $result.Diagnosis | Should -BeLike 'No network adapter is connected.*'
        @($result.Layers | Where-Object { $_.Status -eq 'Skip' }).Count | Should -Be 6
        Should -Invoke -ModuleName ItOpsToolkit Resolve-ItoHostAddress -Times 0 -Exactly
    }

    It 'diagnoses a DHCP failure from a self-assigned address' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Ethernet'; Description = 'Realtek'; InterfaceType = 'Ethernet'; IPv4Addresses = @('169.254.12.7'); Gateways = @(); DnsServers = @() }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.FailedLayer | Should -Be 'IP configuration'
        (Get-Layer $result 'IP configuration').Detail | Should -Be 'Only self-assigned addresses: 169.254.12.7 on Ethernet.'
        $result.Diagnosis | Should -BeLike '*169.254.x.x*DHCP*ipconfig /renew*'
    }

    It 'prefers the adapter that has a gateway over a virtual adapter' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'vEthernet (WSL)'; Description = 'Hyper-V'; InterfaceType = 'Ethernet'; IPv4Addresses = @('172.20.0.1'); Gateways = @(); DnsServers = @() }
            [pscustomobject]@{ Name = 'Wi-Fi'; Description = 'Intel'; InterfaceType = 'Wireless80211'; IPv4Addresses = @('10.0.0.5'); Gateways = @('10.0.0.1'); DnsServers = @('10.0.0.1') }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        (Get-Layer $result 'IP configuration').Detail | Should -Be 'Wi-Fi: 10.0.0.5'
        Should -Invoke -ModuleName ItOpsToolkit Invoke-ItoPing -ParameterFilter { $Address -eq '10.0.0.1' -and $Ttl -eq 128 } -Times 1 -Exactly
    }

    It 'diagnoses a missing default gateway' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Ethernet'; Description = 'Realtek'; InterfaceType = 'Ethernet'; IPv4Addresses = @('10.1.2.3'); Gateways = @(); DnsServers = @('10.1.0.10') }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.FailedLayer | Should -Be 'Default gateway'
        $result.Diagnosis | Should -BeLike 'No default gateway is configured*'
    }

    It 'treats a gateway that ignores ping as a warning when everything else works' {
        Mock -ModuleName ItOpsToolkit Invoke-ItoPing { [pscustomobject]@{ Status = 'TimedOut'; Address = $null; RoundtripTime = 0; Error = $null } } -ParameterFilter { $Ttl -eq 128 }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.Healthy | Should -BeTrue
        (Get-Layer $result 'Default gateway').Status | Should -Be 'Warn'
        $result.Diagnosis | Should -BeLike '*gateway does not answer ping, which many routers*'
    }

    It 'separates a missing DNS record from a DNS outage' {
        Mock -ModuleName ItOpsToolkit Resolve-ItoHostAddress { throw 'No such host is known.' } -ParameterFilter { $Name -eq 'intranet.corp.example.com' }
        $result = Test-ItoNetwork -ComputerName 'intranet.corp.example.com'
        $result.FailedLayer | Should -Be 'DNS resolution'
        (Get-Layer $result 'DNS resolution').Code | Should -Be 'NameNotFound'
        $result.Diagnosis | Should -BeLike "DNS works, but the name 'intranet.corp.example.com' does not resolve.*VPN*"
        (Get-Layer $result 'TCP port').Status | Should -Be 'Skip'
    }

    It 'diagnoses a DNS outage when the control name fails too' {
        Mock -ModuleName ItOpsToolkit Resolve-ItoHostAddress { throw 'This is usually a temporary error during hostname resolution.' }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        (Get-Layer $result 'DNS resolution').Code | Should -Be 'DnsDown'
        $result.Diagnosis | Should -BeLike 'Name resolution is failing*ipconfig /flushdns*'
    }

    It 'leaves out the fec0:0:0:ffff:: placeholders that Windows lists when no IPv6 DNS server is set' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Wi-Fi'; Description = 'Intel'; InterfaceType = 'Wireless80211'; IPv4Addresses = @('192.168.1.23'); Gateways = @('192.168.1.1')
                DnsServers = @('1.1.1.1', 'fec0:0:0:ffff::1%1', 'fec0:0:0:ffff::2%1', 'fec0:0:0:ffff::3%1', '2606:4700:4700::1111')
            }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com' -SkipTrace
        (Get-Layer $result 'DNS servers').Detail | Should -Be 'DNS servers: 1.1.1.1, 2606:4700:4700::1111.'
    }

    It 'treats an adapter with only the placeholders as having no DNS servers' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Ethernet'; Description = 'Realtek'; InterfaceType = 'Ethernet'; IPv4Addresses = @('10.1.2.3'); Gateways = @('10.1.0.1'); DnsServers = @('fec0:0:0:ffff::1%1', 'fec0:0:0:ffff::2%1') }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com' -SkipTrace
        (Get-Layer $result 'DNS servers').Code | Should -Be 'NoDnsServers'
    }

    It 'says when no DNS servers are configured' {
        Mock -ModuleName ItOpsToolkit Get-ItoNetworkInterfaceData {
            [pscustomobject]@{ Name = 'Ethernet'; Description = 'Realtek'; InterfaceType = 'Ethernet'; IPv4Addresses = @('10.1.2.3'); Gateways = @('10.1.0.1'); DnsServers = @() }
        }
        Mock -ModuleName ItOpsToolkit Resolve-ItoHostAddress { throw 'No such host is known.' }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.Diagnosis | Should -BeLike 'No DNS servers are configured*'
    }

    It 'diagnoses a refused port' {
        Mock -ModuleName ItOpsToolkit Test-ItoTcpConnection { [pscustomobject]@{ Connected = $false; Reason = 'Refused'; Error = 'Connection refused' } }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com' -Port 8443
        $result.FailedLayer | Should -Be 'TCP port'
        $result.Diagnosis | Should -Be "'portal.example.com' answered but refused port 8443. The service is not running or not listening on that port, or a firewall is actively rejecting the connection."
    }

    It 'points at the firewall and where the trace stops when a port times out' {
        Mock -ModuleName ItOpsToolkit Test-ItoTcpConnection { [pscustomobject]@{ Connected = $false; Reason = 'Timeout'; Error = 'No answer within 3000 ms.' } }
        Mock -ModuleName ItOpsToolkit Invoke-ItoTraceRoute {
            [pscustomobject]@{ Hop = 1; Address = '192.168.1.1'; Status = 'TtlExpired' }
            [pscustomobject]@{ Hop = 2; Address = '198.51.100.1'; Status = 'TtlExpired' }
            [pscustomobject]@{ Hop = 3; Address = $null; Status = 'TimedOut' }
        }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        (Get-Layer $result 'TCP port').Code | Should -Be 'TcpTimeout'
        $result.Diagnosis | Should -BeLike 'Port 443 on * did not answer. A firewall is probably dropping the traffic*The trace stops after hop 2 (198.51.100.1)*'
    }

    It 'blames the local network when neither the gateway nor the target answers' {
        Mock -ModuleName ItOpsToolkit Invoke-ItoPing { [pscustomobject]@{ Status = 'TimedOut'; Address = $null; RoundtripTime = 0; Error = $null } }
        Mock -ModuleName ItOpsToolkit Test-ItoTcpConnection { [pscustomobject]@{ Connected = $false; Reason = 'Timeout'; Error = 'No answer' } }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com' -SkipTrace
        $result.Diagnosis | Should -BeLike '*most likely on the local network*'
    }

    It 'diagnoses a failed TLS handshake' {
        Mock -ModuleName ItOpsToolkit Invoke-ItoHttpsProbe { [pscustomobject]@{ Succeeded = $false; StatusCode = $null; Reason = 'Tls'; Error = 'The remote certificate is invalid according to the validation procedure.' } }
        $result = Test-ItoNetwork -ComputerName 'portal.example.com'
        $result.FailedLayer | Should -Be 'HTTPS'
        $result.Diagnosis | Should -BeLike "*HTTPS handshake failed (The remote certificate is invalid*date and time*TLS inspection*"
    }

    It 'skips HTTPS for other ports and skips DNS for an IP address' {
        $result = Test-ItoNetwork -ComputerName '10.20.30.40' -Port 3389 -SkipTrace
        (Get-Layer $result 'DNS resolution').Status | Should -Be 'Skip'
        (Get-Layer $result 'HTTPS').Status | Should -Be 'Skip'
        (Get-Layer $result 'Route trace').Status | Should -Be 'Skip'
        $result.Healthy | Should -BeTrue
        Should -Invoke -ModuleName ItOpsToolkit Test-ItoTcpConnection -ParameterFilter { $Address -eq '10.20.30.40' -and $Port -eq 3389 } -Times 1 -Exactly
        Should -Invoke -ModuleName ItOpsToolkit Invoke-ItoTraceRoute -Times 0 -Exactly
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a host name with spaces'; Arguments = @{ ComputerName = 'bad host' } }
        @{ Case = 'a URL instead of a host name'; Arguments = @{ ComputerName = 'https://example.com' } }
        @{ Case = 'port 0'; Arguments = @{ Port = 0 } }
        @{ Case = 'a timeout of 61 seconds'; Arguments = @{ TimeoutSeconds = 61 } }
    ) {
        { Test-ItoNetwork @Arguments } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Test-ItoNetwork'
    }
}

Describe 'Network probes against real sockets' {
    It 'connects to a listening local port' {
        $listener = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            InModuleScope ItOpsToolkit -Parameters @{ Port = $port } {
                (Test-ItoTcpConnection -Address '127.0.0.1' -Port $Port -TimeoutMilliseconds 2000).Connected | Should -BeTrue
            }
        }
        finally {
            $listener.Stop()
        }
    }

    It 'reports a closed local port as refused' {
        $listener = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        InModuleScope ItOpsToolkit -Parameters @{ Port = $port } {
            # Windows retries a refused connection before reporting it, so allow more than the retries take.
            $result = Test-ItoTcpConnection -Address '127.0.0.1' -Port $Port -TimeoutMilliseconds 8000
            $result.Connected | Should -BeFalse
            $result.Reason | Should -Be 'Refused'
        }
    }

    It 'resolves localhost' {
        InModuleScope ItOpsToolkit {
            $addresses = @(Resolve-ItoHostAddress -Name 'localhost')
            ($addresses -contains '127.0.0.1' -or $addresses -contains '::1') | Should -BeTrue
        }
    }

    It 'lists network interfaces as plain objects' {
        InModuleScope ItOpsToolkit {
            foreach ($interface in @(Get-ItoNetworkInterfaceData)) {
                $interface.PSObject.Properties.Name | Should -Be @('Name', 'Description', 'InterfaceType', 'IPv4Addresses', 'Gateways', 'DnsServers')
            }
        }
    }

    It 'returns a ping status instead of throwing for an invalid address' {
        InModuleScope ItOpsToolkit {
            $reply = Invoke-ItoPing -Address 'invalid..host' -TimeoutMilliseconds 500
            $reply.Status | Should -Be 'Error'
            $reply.Error | Should -Not -BeNullOrEmpty
        }
    }
}
