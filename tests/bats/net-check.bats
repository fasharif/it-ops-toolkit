#!/usr/bin/env bats
#
# Unit tests for linux/net-check.sh. Every network tool is faked, so the tests control each
# layer's result and never touch the real network.

# The fakes are written in single quotes so their variables expand when they run (SC2016).
# Each @test runs in its own subshell, so exporting per test is the intent (SC2030, SC2031).
# FAKE_BIN is set by helpers/common.bash (SC2153).
# shellcheck disable=SC2016,SC2030,SC2031,SC2153

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    common_setup
    T=$BATS_TEST_TMPDIR

    # A working network: eth0 with a DHCP address, a gateway that answers, a DNS server.
    export FAKE_LINKS=$'1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536\n2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'
    export FAKE_ADDRS=$'1: lo    inet 127.0.0.1/8 scope host lo\n2: eth0    inet 192.168.1.23/24 brd 192.168.1.255 scope global dynamic eth0'
    export FAKE_ROUTE='default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.23 metric 100'
    export FAKE_PING=ok FAKE_TCP=ok FAKE_CURL_RC=0 FAKE_HTTP_CODE=200 FAKE_CURL_ERROR=''
    export FAKE_HOSTS="$T/hosts"
    printf 'portal.example.com 203.0.113.10\nwww.microsoft.com 198.51.100.7\n' >"$FAKE_HOSTS"
    printf 'nameserver 192.168.1.1\nsearch corp.example.com\n' >"$T/resolv.conf"
    export ITO_RESOLV_CONF="$T/resolv.conf"
    export FAKE_TRACE=$' 1  192.168.1.1  0.412 ms\n 2  198.51.100.1  3.100 ms\n 3  203.0.113.10  9.800 ms'

    fake ip 'case "$*" in
    "-o link show up") printf "%s\n" "$FAKE_LINKS" ;;
    "-o -4 addr show up") printf "%s\n" "$FAKE_ADDRS" ;;
    "-4 route show default") printf "%s\n" "$FAKE_ROUTE" ;;
    *) echo "unexpected ip $*" >&2; exit 1 ;;
esac'
    fake ping '[[ $FAKE_PING == ok ]]'
    fake getent 'name=$2
address=$(awk -v n="$name" "\$1 == n { print \$2 }" "$FAKE_HOSTS")
[[ -n $address ]] || exit 2
printf "%s STREAM %s\n%s DGRAM\n%s RAW\n" "$address" "$name" "$address" "$address"'
    fake timeout 'printf "%s\n" "$*" >>"$FAKE_LDB/timeout.log"
case $FAKE_TCP in
    ok) exit 0 ;;
    refused) echo "bash: connect: Connection refused" >&2; echo "bash: line 1: /dev/tcp/x/443: Connection refused" >&2; exit 1 ;;
    unreachable) echo "bash: connect: Network is unreachable" >&2; exit 1 ;;
    timeout) exit 124 ;;
esac'
    fake curl 'printf "%s" "$FAKE_HTTP_CODE"
if [[ -n $FAKE_CURL_ERROR ]]; then echo "curl: ($FAKE_CURL_RC) $FAKE_CURL_ERROR" >&2; fi
exit "$FAKE_CURL_RC"'
    fake traceroute 'echo "traceroute to $7 ($7), 15 hops max, 60 byte packets"; printf "%s\n" "$FAKE_TRACE"'
}

check() {
    "$REPO_ROOT/linux/net-check.sh" "$@"
}

@test 'reports a healthy path and exits 0' {
    run check portal.example.com
    assert_success
    assert_line 'Network check: portal.example.com port 443'
    assert_line --regexp '^IP configuration +Pass +eth0: 192\.168\.1\.23$'
    assert_line --regexp '^Default gateway +Pass +192\.168\.1\.1 answers ping\.$'
    assert_line --regexp '^DNS servers +Pass +DNS servers: 192\.168\.1\.1\.$'
    assert_line --regexp '^DNS resolution +Pass +portal\.example\.com resolves to 203\.0\.113\.10\.$'
    assert_line --regexp '^TCP port +Pass +Connected to 203\.0\.113\.10 on port 443\.$'
    assert_line --regexp '^HTTPS +Pass +TLS handshake completed; the server answered with HTTP status 200\.$'
    assert_line --regexp '^Route trace +Info +Reached 203\.0\.113\.10 in 3 hop\(s\)\.$'
    assert_line "Diagnosis: No fault found: 'portal.example.com' resolves, port 443 accepts connections and HTTPS answers."
}

@test 'checks www.microsoft.com when no host is given' {
    run check --no-trace
    assert_success
    assert_line 'Network check: www.microsoft.com port 443'
}

@test 'diagnoses a missing network connection and skips the other layers' {
    export FAKE_LINKS='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536' FAKE_ADDRS='' FAKE_ROUTE=''
    run check portal.example.com
    assert_failure 1
    assert_line --regexp '^IP configuration +Fail +No network interface is up\.$'
    assert_line --regexp '^TCP port +Skip +Skipped because there is no usable IP configuration\.$'
    assert_line --partial 'Diagnosis: No network interface is up. Check the cable or Wi-Fi connection'
}

@test 'diagnoses a DHCP failure from a self-assigned address' {
    export FAKE_ADDRS='2: eth0    inet 169.254.12.7/16 brd 169.254.255.255 scope link eth0' FAKE_ROUTE=''
    run check portal.example.com
    assert_failure 1
    assert_line --regexp '^IP configuration +Fail +Only self-assigned addresses: 169\.254\.12\.7 on eth0\.$'
    assert_line --partial 'Diagnosis: The machine gave itself a 169.254.x.x address, which means no DHCP server answered.'
}

@test 'diagnoses an interface without an address' {
    export FAKE_ADDRS='' FAKE_ROUTE=''
    run check portal.example.com
    assert_failure 1
    assert_line --partial 'Diagnosis: The network interface is up but has no IPv4 address.'
}

@test 'prefers the interface that holds the default route' {
    export FAKE_LINKS=$'2: docker0: <UP> mtu 1500\n3: wlan0: <UP> mtu 1500'
    export FAKE_ADDRS=$'2: docker0    inet 172.17.0.1/16 scope global docker0\n3: wlan0    inet 10.0.0.5/24 scope global wlan0'
    export FAKE_ROUTE='default via 10.0.0.1 dev wlan0'
    run check --no-trace portal.example.com
    assert_line --regexp '^IP configuration +Pass +wlan0: 10\.0\.0\.5$'
}

@test 'diagnoses a missing default gateway' {
    export FAKE_ROUTE=''
    run check portal.example.com
    assert_failure 1
    assert_line --regexp '^Default gateway +Fail +No default gateway is configured\.$'
    assert_line --partial 'Diagnosis: No default gateway is configured, so traffic cannot leave the local network.'
}

@test 'treats a gateway that ignores ping as a warning when everything else works' {
    export FAKE_PING=no
    run check --no-trace portal.example.com
    assert_success
    assert_line --regexp '^Default gateway +Warn +192\.168\.1\.1 did not answer ping\.$'
    assert_line --partial 'The default gateway does not answer ping, which many routers and firewalls do by design.'
}

@test 'separates a missing DNS record from a DNS outage' {
    run check --no-trace intranet.corp.example.com
    assert_failure 1
    assert_line --regexp "^DNS resolution +Fail +'intranet\.corp\.example\.com' did not resolve, but 'www\.microsoft\.com' did\.$"
    assert_line --partial "Diagnosis: DNS works, but the name 'intranet.corp.example.com' does not resolve."
    : >"$FAKE_HOSTS"
    run check --no-trace portal.example.com
    assert_line --regexp "^DNS resolution +Fail +'portal\.example\.com' did not resolve, and neither did the control name 'www\.microsoft\.com'\.$"
    assert_line --partial 'Diagnosis: Name resolution is failing: the DNS servers did not answer.'
}

@test 'uses an internal control name when told to' {
    printf 'corp.example.com 10.1.0.10\n' >"$FAKE_HOSTS"
    run check --no-trace --control-name corp.example.com fs01.corp.example.com
    assert_line --partial "but 'corp.example.com' did."
}

@test 'says when no DNS servers are configured' {
    : >"$T/resolv.conf"
    : >"$FAKE_HOSTS"
    run check --no-trace portal.example.com
    assert_line --regexp '^DNS servers +Warn +No DNS servers are listed in '
    assert_line --partial 'Diagnosis: No DNS servers are configured in'
}

@test 'diagnoses a refused port' {
    export FAKE_TCP=refused
    run check --no-trace --port 8443 portal.example.com
    assert_failure 1
    assert_line --regexp '^TCP port +Fail +No connection to 203\.0\.113\.10 on port 8443: Connection refused$'
    assert_line "Diagnosis: 'portal.example.com' answered but refused port 8443. The service is not running or not listening on that port, or a firewall is actively rejecting the connection."
    run cat "$FAKE_LDB/timeout.log"
    assert_output --partial '203.0.113.10 8443'
}

@test 'points at a firewall, and at where the trace stops, when a port times out' {
    export FAKE_TCP=timeout
    export FAKE_TRACE=$' 1  192.168.1.1  0.412 ms\n 2  198.51.100.1  3.100 ms\n 3  *\n 4  *'
    run check --timeout 2 portal.example.com
    assert_failure 1
    assert_line --regexp '^TCP port +Fail +No connection to 203\.0\.113\.10 on port 443: No answer within 2 seconds\.$'
    assert_line --regexp '^Route trace +Info +The trace stops after hop 2 \(198\.51\.100\.1\); later hops did not answer within 4 hops\.$'
    assert_line "Diagnosis: Port 443 on 'portal.example.com' did not answer. A firewall is probably dropping the traffic, or the server is down. The trace stops after hop 2 (198.51.100.1); later hops did not answer within 4 hops."
}

@test 'blames the local network when neither the gateway nor the target answers' {
    export FAKE_PING=no FAKE_TCP=unreachable
    run check --no-trace portal.example.com
    assert_failure 1
    assert_line --regexp '^TCP port +Fail +.*Network is unreachable$'
    assert_line --partial 'The fault is most likely on the local network: cable, Wi-Fi, switch or router.'
}

@test 'diagnoses a failed TLS handshake, a slow web server and a missing proxy' {
    export FAKE_CURL_RC=60 FAKE_HTTP_CODE=000 FAKE_CURL_ERROR='SSL certificate problem: unable to get local issuer certificate'
    run check --no-trace portal.example.com
    assert_failure 1
    assert_line --regexp '^HTTPS +Fail +\(60\) SSL certificate problem: unable to get local issuer certificate$'
    assert_line --partial 'but the HTTPS handshake failed ((60) SSL certificate problem'
    assert_line --partial 'update-ca-certificates'
    export FAKE_CURL_RC=28 FAKE_CURL_ERROR='Operation timed out after 3001 milliseconds with 0 bytes received'
    run check --no-trace portal.example.com
    assert_line --partial 'but the web server did not answer in time.'
    export FAKE_CURL_RC=5 FAKE_CURL_ERROR='Could not resolve proxy: proxy.corp.example.com'
    run check --no-trace portal.example.com
    assert_line 'Diagnosis: The proxy server could not be found. Check the https_proxy and HTTPS_PROXY settings.'
}

@test 'counts any HTTP status, even an error page, as a working HTTPS path' {
    export FAKE_HTTP_CODE=403
    run check --no-trace portal.example.com
    assert_success
    assert_line --regexp '^HTTPS +Pass +TLS handshake completed; the server answered with HTTP status 403\.$'
}

@test 'skips HTTPS for other ports and DNS for an IP address' {
    run check --no-trace --port 3389 10.20.30.40
    assert_success
    assert_line --regexp '^DNS resolution +Skip +The target is an IP address, so no name lookup is needed\.$'
    assert_line --regexp '^HTTPS +Skip +Skipped: the HTTPS check runs for port 443 only\.$'
    assert_line --regexp '^Route trace +Skip +Skipped \(--no-trace\)\.$'
}

@test 'reads tracepath output when traceroute is not installed' {
    rm -f "$FAKE_BIN/traceroute"
    fake tracepath 'printf " 1?: [LOCALHOST]                      pmtu 1500\n 1:  192.168.1.1                                           0.412ms\n 1:  192.168.1.1                                           0.380ms\n 2:  no reply\n 3:  203.0.113.10                                          9.800ms reached\n     Resume: pmtu 1500 hops 3 back 3\n"'
    isolate_path ip ping getent timeout curl
    run check portal.example.com
    assert_success
    assert_line --regexp '^Route trace +Info +Reached 203\.0\.113\.10 in 3 hop\(s\)\.$'
}

@test 'says when no hop answers the trace' {
    export FAKE_TRACE=$' 1  *\n 2  *\n 3  *'
    run check portal.example.com
    assert_line --regexp '^Route trace +Info +No hop answered\. ICMP is probably blocked on this network'
}

@test 'skips the trace when no trace tool is installed' {
    rm -f "$FAKE_BIN/traceroute"
    isolate_path ip ping getent timeout curl
    run check portal.example.com
    assert_success
    assert_line --regexp '^Route trace +Skip +Skipped: neither traceroute nor tracepath is available\.$'
}

@test 'prints valid JSON' {
    export FAKE_TCP=refused
    run check --json --no-trace portal.example.com
    assert_failure 1
    printf '%s\n' "$output" >"$T/result.json"
    run python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["Healthy"], data["FailedLayer"], data["Port"])
print(len(data["Layers"]), data["Layers"][4]["Code"])
' "$T/result.json"
    assert_line --index 0 'False TCP port 443'
    assert_line --index 1 '7 TcpRefused'
}

@test 'rejects bad arguments with exit code 64' {
    run check 'bad host'
    assert_failure 64
    run check https://example.com
    assert_failure 64
    run check --port 0
    assert_failure 64
    run check --timeout 61
    assert_failure 64
    run check --max-hops 31
    assert_failure 64
    run check --bogus
    assert_failure 64
    assert_output --partial "Unknown option '--bogus'."
}
