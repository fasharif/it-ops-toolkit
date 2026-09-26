#!/usr/bin/env bash
#
# net-check.sh - layered network troubleshooting that ends in a plain-language diagnosis.
#
# The Linux counterpart of Test-ItoNetwork: the same layers and the same diagnosis rules, with
# Linux commands in the advice. See --help.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

RESOLV_CONF=${ITO_RESOLV_CONF:-/etc/resolv.conf}

usage() {
    cat <<'EOF'
Usage: net-check.sh [options] [HOST]

Works up the network stack the way a service desk analyst would, then names the lowest
layer that failed and says what to do:
  1. IP configuration  an interface is up with a usable IPv4 address (169.254.x.x means DHCP failed)
  2. Default gateway   one is configured, and whether it answers ping (no answer is only a warning)
  3. DNS servers       any are configured in /etc/resolv.conf (or, behind the systemd-resolved
                       stub 127.0.0.53, the servers resolvectl lists)
  4. DNS resolution    HOST resolves; if not, a control name tells a missing record from a DNS outage
  5. TCP port          HOST accepts a connection on the port
  6. HTTPS             for port 443, a TLS handshake and HTTP request succeed
  7. Route trace       hops to HOST, or where replies stop (traceroute or tracepath)

HOST defaults to www.microsoft.com. The script only reads; it changes no settings.

Options:
  --port N            TCP port to test (default 443). HTTPS is checked for port 443 only.
  --timeout S         Seconds to wait for each probe, 1-60 (default 3).
  --control-name NAME Name that should always resolve (default www.microsoft.com). On a
                      network without internet access, use an internal name.
  --no-https          Skip the HTTPS layer.
  --no-trace          Skip the route trace.
  --max-hops N        Maximum hops for the trace, 1-30 (default 15).
  --json              Print the result as JSON.
  -h, --help          Show this help.

Exit status: 0 no fault found; 1 a fault was found; 64 usage error.
EOF
}

TARGET=www.microsoft.com
PORT=443
TIMEOUT=3
CONTROL_NAME=www.microsoft.com
CHECK_HTTPS=true
CHECK_TRACE=true
MAX_HOPS=15
JSON=false
HOST_PATTERN='^([A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|[0-9A-Fa-f:.]{2,45})$'

while (($# > 0)); do
    case $1 in
        --port) PORT=${2:?}; shift 2 ;;
        --timeout) TIMEOUT=${2:?}; shift 2 ;;
        --control-name) CONTROL_NAME=${2:?}; shift 2 ;;
        --no-https) CHECK_HTTPS=false; shift ;;
        --no-trace) CHECK_TRACE=false; shift ;;
        --max-hops) MAX_HOPS=${2:?}; shift 2 ;;
        --json) JSON=true; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) usage_error "Unknown option '$1'." ;;
        *) TARGET=$1; shift ;;
    esac
done

[[ $TARGET =~ $HOST_PATTERN ]] || usage_error "'$TARGET' is not a host name or IP address."
[[ $CONTROL_NAME =~ $HOST_PATTERN ]] || usage_error "'$CONTROL_NAME' is not a host name."
if ! is_integer "$PORT" || ((PORT < 1 || PORT > 65535)); then usage_error '--port must be from 1 to 65535.'; fi
if ! is_integer "$TIMEOUT" || ((TIMEOUT < 1 || TIMEOUT > 60)); then usage_error '--timeout must be from 1 to 60 seconds.'; fi
if ! is_integer "$MAX_HOPS" || ((MAX_HOPS < 1 || MAX_HOPS > 30)); then usage_error '--max-hops must be from 1 to 30.'; fi
require_cmd ip getent timeout

TARGET_IS_ADDRESS=false
if [[ $TARGET =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $TARGET == *:* ]]; then
    TARGET_IS_ADDRESS=true
fi

LAYERS=()
STATUSES=()
CODES=()
DETAILS=()

# add_layer NAME STATUS CODE DETAIL. STATUS is Pass, Warn, Fail, Skip or Info.
add_layer() {
    LAYERS+=("$1")
    STATUSES+=("$2")
    CODES+=("$3")
    DETAILS+=("$4")
}

# code_of LAYER: the code recorded for a layer, or nothing.
code_of() {
    local i
    for i in "${!LAYERS[@]}"; do
        if [[ ${LAYERS[i]} == "$1" ]]; then
            printf '%s' "${CODES[i]}"
            return
        fi
    done
}

detail_of() {
    local i
    for i in "${!LAYERS[@]}"; do
        if [[ ${LAYERS[i]} == "$1" ]]; then
            printf '%s' "${DETAILS[i]}"
            return
        fi
    done
}

skip_rest() {
    local layer
    for layer in "$@"; do
        add_layer "$layer" Skip Skipped "Skipped because $SKIP_REASON."
    done
}

# 1. IP configuration
mapfile -t up_links < <(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" { sub(/@.*/, "", $2); print $2 }')
mapfile -t addresses < <(ip -o -4 addr show up 2>/dev/null | awk '$2 != "lo" && $3 == "inet" { split($4, a, "/"); print $2 " " a[1] }')
usable=()
self_assigned=()
for entry in "${addresses[@]}"; do
    if [[ ${entry#* } == 169.254.* ]]; then
        self_assigned+=("$entry")
    else
        usable+=("$entry")
    fi
done

default_route=$(ip -4 route show default 2>/dev/null | sed -n '1p')
gateway=$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) }' <<<"$default_route" | sed -n '1p')
route_interface=$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<<"$default_route" | sed -n '1p')

ip_failed=true
if ((${#up_links[@]} == 0)); then
    add_layer 'IP configuration' Fail NoAdapter 'No network interface is up.'
elif ((${#usable[@]} == 0 && ${#self_assigned[@]} > 0)); then
    add_layer 'IP configuration' Fail Apipa "Only self-assigned addresses: ${self_assigned[0]#* } on ${self_assigned[0]%% *}."
elif ((${#usable[@]} == 0)); then
    add_layer 'IP configuration' Fail NoAddress 'Interfaces are up, but none has an IPv4 address.'
else
    ip_failed=false
    primary=${usable[0]}
    # Prefer the interface that holds the default route: VPN and bridge interfaces often do not.
    for entry in "${usable[@]}"; do
        if [[ ${entry%% *} == "$route_interface" ]]; then
            primary=$entry
            break
        fi
    done
    add_layer 'IP configuration' Pass Ok "${primary%% *}: ${primary#* }"
fi

if [[ $ip_failed == true ]]; then
    SKIP_REASON='there is no usable IP configuration'
    skip_rest 'Default gateway' 'DNS servers' 'DNS resolution' 'TCP port' 'HTTPS' 'Route trace'
else
    # 2. Default gateway
    if [[ -z $gateway ]]; then
        add_layer 'Default gateway' Fail NoGateway 'No default gateway is configured.'
    elif ! command -v ping >/dev/null 2>&1; then
        add_layer 'Default gateway' Pass Ok "Gateway $gateway (not pinged: ping is not installed)."
    elif ping -c 1 -W "$TIMEOUT" "$gateway" >/dev/null 2>&1; then
        add_layer 'Default gateway' Pass Ok "$gateway answers ping."
    else
        add_layer 'Default gateway' Warn GatewayNoReply "$gateway did not answer ping."
    fi

    # 3. DNS servers. With systemd-resolved (Ubuntu and others), /etc/resolv.conf lists only its
    # local stub, 127.0.0.53, so ask resolvectl for the servers it forwards to. Its lines look
    # like "Global: 1.1.1.1" or "Link 2 (eth0): 192.168.1.1 fd00::1".
    mapfile -t dns_servers < <(awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF" 2>/dev/null)
    dns_source=''
    if [[ ${dns_servers[*]:-} == 127.0.0.53 ]] && command -v resolvectl >/dev/null 2>&1; then
        mapfile -t upstream < <(resolvectl dns 2>/dev/null |
            awk -F': ' 'NF > 1 { n = split($2, a, " "); for (i = 1; i <= n; i++) if (!seen[a[i]]++) print a[i] }')
        if ((${#upstream[@]} > 0)); then
            dns_servers=("${upstream[@]}")
            dns_source=' (from systemd-resolved)'
        fi
    fi
    if ((${#dns_servers[@]} == 0)); then
        add_layer 'DNS servers' Warn NoDnsServers "No DNS servers are listed in $RESOLV_CONF."
    else
        add_layer 'DNS servers' Pass Ok "DNS servers$dns_source: $(join_by ', ' "${dns_servers[@]}")."
    fi

    # 4. DNS resolution (through NSS, as applications resolve names)
    resolved=()
    if [[ $TARGET_IS_ADDRESS == true ]]; then
        resolved=("$TARGET")
        add_layer 'DNS resolution' Skip Skipped 'The target is an IP address, so no name lookup is needed.'
    else
        mapfile -t resolved < <({ getent ahostsv4 "$TARGET" 2>/dev/null || getent ahosts "$TARGET" 2>/dev/null || true; } | awk '!seen[$1]++ { print $1 }')
        if ((${#resolved[@]} > 0)); then
            add_layer 'DNS resolution' Pass Ok "$TARGET resolves to $(join_by ', ' "${resolved[@]}")."
        elif [[ $CONTROL_NAME != "$TARGET" ]] && getent ahosts "$CONTROL_NAME" >/dev/null 2>&1; then
            add_layer 'DNS resolution' Fail NameNotFound "'$TARGET' did not resolve, but '$CONTROL_NAME' did."
        else
            add_layer 'DNS resolution' Fail DnsDown "'$TARGET' did not resolve, and neither did the control name '$CONTROL_NAME'."
        fi
    fi

    # 5. TCP port
    tcp_passed=false
    if ((${#resolved[@]} == 0)); then
        add_layer 'TCP port' Skip Skipped 'Skipped because the name did not resolve.'
    else
        address=${resolved[0]}
        tcp_rc=0
        # The inner script gets the address and port as $1 and $2, so single quotes are intended.
        # shellcheck disable=SC2016
        tcp_output=$(timeout "$TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$address" "$PORT" 2>&1) || tcp_rc=$?
        if ((tcp_rc == 0)); then
            tcp_passed=true
            add_layer 'TCP port' Pass Ok "Connected to $address on port $PORT."
        else
            if ((tcp_rc == 124)); then
                reason=Timeout
                tcp_error="No answer within $TIMEOUT seconds."
            else
                tcp_error=${tcp_output##*: }
                case ${tcp_output,,} in
                    *refused*) reason=Refused ;;
                    *unreachable*) reason=Unreachable ;;
                    *) reason=Error ;;
                esac
            fi
            add_layer 'TCP port' Fail "Tcp$reason" "No connection to $address on port $PORT: $tcp_error"
        fi
    fi

    # 6. HTTPS
    if [[ $CHECK_HTTPS == false || $PORT -ne 443 ]]; then
        add_layer HTTPS Skip Skipped 'Skipped: the HTTPS check runs for port 443 only.'
    elif [[ $tcp_passed == false ]]; then
        add_layer HTTPS Skip Skipped 'Skipped because the TCP connection failed.'
    elif ! command -v curl >/dev/null 2>&1; then
        add_layer HTTPS Skip Skipped 'Skipped: curl is not installed.'
    else
        url_host=$TARGET
        if [[ $TARGET == *:* ]]; then
            url_host="[$TARGET]"
        fi
        https_error_file=$(mktemp)
        https_rc=0
        status_code=$(curl -sS -o /dev/null -w '%{http_code}' --head --max-time "$TIMEOUT" "https://$url_host:$PORT/" 2>"$https_error_file") || https_rc=$?
        https_error=$(sed -n '1p' "$https_error_file")
        https_error=${https_error#curl: }
        rm -f -- "$https_error_file"
        if ((https_rc == 0)); then
            add_layer HTTPS Pass Ok "TLS handshake completed; the server answered with HTTP status $status_code."
        else
            case $https_rc in
                35 | 51 | 53 | 54 | 58 | 59 | 60 | 77 | 80 | 83 | 90 | 91) code=HttpsTls ;;
                28) code=HttpsTimeout ;;
                5) code=HttpsProxy ;;
                *) code=HttpsOther ;;
            esac
            add_layer HTTPS Fail "$code" "${https_error:-curl exit code $https_rc}"
        fi
    fi

    # 7. Route trace
    if [[ $CHECK_TRACE == false ]]; then
        add_layer 'Route trace' Skip Skipped 'Skipped (--no-trace).'
    elif ((${#resolved[@]} == 0)); then
        add_layer 'Route trace' Skip Skipped 'Skipped because there is no address to trace.'
    elif [[ ${resolved[0]} == *:* ]]; then
        add_layer 'Route trace' Skip Skipped 'Skipped: the trace supports IPv4 targets only.'
    else
        destination=${resolved[0]}
        hops=''
        if command -v traceroute >/dev/null 2>&1; then
            # Lines look like " 1  192.168.1.1  0.412 ms" or " 3  *".
            hops=$(traceroute -n -q 1 -w 1 -m "$MAX_HOPS" "$destination" 2>/dev/null |
                awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1, ($2 == "*" ? "*" : $2) }') || true
        elif command -v tracepath >/dev/null 2>&1; then
            # Lines look like " 1:  192.168.1.1   0.412ms", " 2:  no reply" or " 1?: [LOCALHOST] pmtu 1500".
            hops=$(tracepath -n -m "$MAX_HOPS" "$destination" 2>/dev/null |
                awk '$1 ~ /^[0-9]+:$/ { hop = $1; sub(/:$/, "", hop); if (!seen[hop]++) print hop, ($2 == "no" ? "*" : $2) }') || true
        fi
        if [[ -z $hops ]]; then
            add_layer 'Route trace' Skip Skipped 'Skipped: neither traceroute nor tracepath is available.'
        else
            hop_count=$(awk 'END { print NR }' <<<"$hops")
            reached=$(awk -v d="$destination" '$2 == d { print $1 }' <<<"$hops" | sed -n '1p')
            last_answer=$(awk '$2 != "*" { hop = $1; addr = $2 } END { if (hop != "") print hop, addr }' <<<"$hops")
            if [[ -n $reached ]]; then
                add_layer 'Route trace' Info TraceReached "Reached $destination in $reached hop(s)."
            elif [[ -n $last_answer ]]; then
                add_layer 'Route trace' Info TraceStopped \
                    "The trace stops after hop ${last_answer%% *} (${last_answer#* }); later hops did not answer within $hop_count hops."
            else
                add_layer 'Route trace' Info TraceSilent 'No hop answered. ICMP is probably blocked on this network, so the trace cannot show the path.'
            fi
        fi
    fi
fi

# Diagnosis: name the lowest failing layer and say what to do next.
FAILED_LAYER=''
diagnose() {
    local gateway_quiet=false tcp_code https_code
    if [[ $(code_of 'Default gateway') == GatewayNoReply ]]; then
        gateway_quiet=true
    fi
    case $(code_of 'IP configuration') in
        NoAdapter)
            FAILED_LAYER='IP configuration'
            printf 'No network interface is up. Check the cable or Wi-Fi connection, and that the interface is enabled (ip link set IFACE up, or nmcli device connect IFACE).'
            return ;;
        Apipa)
            FAILED_LAYER='IP configuration'
            printf 'The machine gave itself a 169.254.x.x address, which means no DHCP server answered. Reconnect and renew the lease (nmcli device reapply IFACE, or dhclient -r IFACE; dhclient IFACE). If it persists, check the switch port, the Wi-Fi network or the DHCP scope (it may be full).'
            return ;;
        NoAddress)
            FAILED_LAYER='IP configuration'
            printf 'The network interface is up but has no IPv4 address. Check the connection settings (DHCP or static) and reconnect.'
            return ;;
    esac
    if [[ $(code_of 'Default gateway') == NoGateway ]]; then
        FAILED_LAYER='Default gateway'
        printf 'No default gateway is configured, so traffic cannot leave the local network. Check the DHCP options or the static settings (address, prefix length and gateway).'
        return
    fi
    case $(code_of 'DNS resolution') in
        NameNotFound | DnsDown)
            FAILED_LAYER='DNS resolution'
            if [[ $(code_of 'DNS servers') == NoDnsServers ]]; then
                printf "No DNS servers are configured in %s, so '%s' cannot be turned into an address. Set the DNS servers (normally through DHCP) and try again." "$RESOLV_CONF" "$TARGET"
            elif [[ $(code_of 'DNS resolution') == NameNotFound ]]; then
                printf "DNS works, but the name '%s' does not resolve. Check the spelling. For an internal name, check that the record exists and that you are on the office network or VPN (split DNS)." "$TARGET"
            else
                printf 'Name resolution is failing: the DNS servers did not answer. Flush the cache (resolvectl flush-caches), check that the DNS servers are reachable, and check any VPN client.'
                if [[ $gateway_quiet == true ]]; then
                    printf ' The default gateway did not answer either, so the local network is the most likely cause.'
                fi
            fi
            return ;;
    esac
    tcp_code=$(code_of 'TCP port')
    if [[ $tcp_code == Tcp* && $tcp_code != Tcp ]]; then
        FAILED_LAYER='TCP port'
        if [[ $gateway_quiet == true ]]; then
            printf "The default gateway does not answer and port %s on '%s' cannot be reached. The fault is most likely on the local network: cable, Wi-Fi, switch or router." "$PORT" "$TARGET"
        elif [[ $tcp_code == TcpRefused ]]; then
            printf "'%s' answered but refused port %s. The service is not running or not listening on that port, or a firewall is actively rejecting the connection." "$TARGET" "$PORT"
        else
            printf "Port %s on '%s' did not answer. A firewall is probably dropping the traffic, or the server is down." "$PORT" "$TARGET"
            if [[ $(code_of 'Route trace') == TraceStopped ]]; then
                printf ' %s' "$(detail_of 'Route trace')"
            fi
        fi
        return
    fi
    https_code=$(code_of HTTPS)
    case $https_code in
        HttpsTls)
            FAILED_LAYER=HTTPS
            printf "Port %s on '%s' accepts connections, but the HTTPS handshake failed (%s). Check the system date and time (timedatectl), the proxy settings (https_proxy), and whether a TLS inspection certificate is missing from the trust store (update-ca-certificates)." "$PORT" "$TARGET" "$(detail_of HTTPS)"
            return ;;
        HttpsTimeout)
            FAILED_LAYER=HTTPS
            printf "Port %s on '%s' accepts connections, but the web server did not answer in time. The server may be overloaded, or a proxy or firewall is holding the request." "$PORT" "$TARGET"
            return ;;
        HttpsProxy)
            FAILED_LAYER=HTTPS
            printf 'The proxy server could not be found. Check the https_proxy and HTTPS_PROXY settings.'
            return ;;
        HttpsOther)
            FAILED_LAYER=HTTPS
            printf "Port %s on '%s' accepts connections, but the HTTPS request failed: %s" "$PORT" "$TARGET" "$(detail_of HTTPS)"
            return ;;
    esac
    if [[ $https_code == Ok ]]; then
        printf "No fault found: '%s' resolves, port %s accepts connections and HTTPS answers." "$TARGET" "$PORT"
    else
        printf "No fault found: '%s' resolves and port %s accepts connections." "$TARGET" "$PORT"
    fi
    if [[ $gateway_quiet == true ]]; then
        printf ' The default gateway does not answer ping, which many routers and firewalls do by design.'
    fi
    if [[ $(code_of 'DNS servers') == NoDnsServers ]]; then
        printf ' No DNS servers are listed in %s; this is normal with some VPN clients.' "$RESOLV_CONF"
    fi
}

# Run diagnose in the current shell (not a subshell) so FAILED_LAYER is kept.
diagnosis_file=$(mktemp)
diagnose >"$diagnosis_file"
DIAGNOSIS=$(<"$diagnosis_file")
rm -f -- "$diagnosis_file"
HEALTHY=true
if [[ -n $FAILED_LAYER ]]; then
    HEALTHY=false
fi

if [[ $JSON == true ]]; then
    printf '{\n'
    printf '  "Target": "%s",\n' "$(json_escape "$TARGET")"
    printf '  "Port": %s,\n' "$PORT"
    printf '  "Healthy": %s,\n' "$HEALTHY"
    if [[ -n $FAILED_LAYER ]]; then
        printf '  "FailedLayer": "%s",\n' "$FAILED_LAYER"
    else
        printf '  "FailedLayer": null,\n'
    fi
    printf '  "Diagnosis": "%s",\n' "$(json_escape "$DIAGNOSIS")"
    printf '  "CheckedAtUtc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "Layers": [\n'
    for i in "${!LAYERS[@]}"; do
        separator=','
        if ((i == ${#LAYERS[@]} - 1)); then
            separator=''
        fi
        printf '    { "Layer": "%s", "Status": "%s", "Code": "%s", "Detail": "%s" }%s\n' \
            "${LAYERS[i]}" "${STATUSES[i]}" "${CODES[i]}" "$(json_escape "${DETAILS[i]}")" "$separator"
    done
    printf '  ]\n}\n'
else
    printf 'Network check: %s port %s\n\n' "$TARGET" "$PORT"
    printf '%-18s %-6s %s\n' 'Layer' 'Status' 'Detail'
    for i in "${!LAYERS[@]}"; do
        printf '%-18s %-6s %s\n' "${LAYERS[i]}" "${STATUSES[i]}" "${DETAILS[i]}"
    done
    printf '\nDiagnosis: %s\n' "$DIAGNOSIS"
fi

if [[ $HEALTHY == true ]]; then
    exit 0
fi
exit 1
