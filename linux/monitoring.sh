#!/usr/bin/env bash
#
# monitoring.sh - the Born2beRoot system summary, broadcast to every terminal with wall.
#
# Born2beRoot (42 school) asks for a script that shows, every ten minutes, the architecture and
# kernel, physical and virtual CPUs, memory and disk use, CPU load, last boot, whether LVM is
# in use, established TCP connections, logged-in users, the IPv4 and MAC address, and the
# number of commands run with sudo. Run it from root's crontab:
#
#   */10 * * * * /usr/local/sbin/monitoring.sh
#
# It reads /proc and /sys directly instead of parsing top, free or ss, so the numbers do not
# depend on those tools' output formats. It only reads; it changes nothing.

set -euo pipefail

PROC_DIR=${ITO_PROC_DIR:-/proc}
SYS_DIR=${ITO_SYS_DIR:-/sys}
SUDO_LOG=${ITO_SUDO_LOG:-/var/log/sudo/sudo.log}
CPU_SAMPLE_SECONDS=${ITO_CPU_SAMPLE_SECONDS:-1}

usage() {
    cat <<'EOF'
Usage: monitoring.sh [--stdout]

Prints the Born2beRoot system summary and broadcasts it to all terminals with wall.

  --stdout    Print the summary only; do not call wall.
  -h, --help  Show this help.
EOF
}

TO_WALL=true
while (($# > 0)); do
    case $1 in
        --stdout) TO_WALL=false; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'monitoring.sh: unknown option %s\n' "$1" >&2; exit 64 ;;
    esac
done

# Distinct "physical id" values are sockets. Some virtual machines and ARM boards report none; that is one CPU.
physical_cpus() {
    awk -F': *' '/^physical id/ { ids[$2] = 1 }
        END { n = 0; for (id in ids) n++; print (n > 0 ? n : 1) }' "$PROC_DIR/cpuinfo"
}

virtual_cpus() {
    awk '/^processor[[:space:]]*:/ { n++ } END { print n + 0 }' "$PROC_DIR/cpuinfo"
}

# Used memory is MemTotal minus MemAvailable, the figure free(1) has shown as "used" since procps-ng 3.3.10.
memory_usage() {
    awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 }
        END {
            used = total - available
            printf "%d/%dMB (%.2f%%)", used / 1024, total / 1024, (total > 0 ? used * 100 / total : 0)
        }' "$PROC_DIR/meminfo"
}

# Sum over real block-device filesystems (the LVM volumes on a Born2beRoot VM), each device once.
disk_usage() {
    df -P -k 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/dev\// && !seen[$1]++ { total += $2; used += $3 }
        END {
            if (total == 0) { print "0/0Gb (0%)"; exit }
            printf "%d/%.0fGb (%.0f%%)", used / 1024, total / 1048576, used * 100 / total
        }'
}

# Busy share of CPU time between two samples of /proc/stat. Idle and iowait count as not busy.
cpu_times() {
    awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print idle, total; exit }' "$PROC_DIR/stat"
}

cpu_load() {
    local idle1 total1 idle2 total2
    read -r idle1 total1 < <(cpu_times)
    sleep "$CPU_SAMPLE_SECONDS"
    read -r idle2 total2 < <(cpu_times)
    awk -v idle="$((idle2 - idle1))" -v total="$((total2 - total1))" \
        'BEGIN { printf "%.1f%%", (total > 0 ? (total - idle) * 100 / total : 0) }'
}

# btime in /proc/stat is the boot time in seconds since the epoch.
last_boot() {
    local boot
    boot=$(awk '/^btime/ { print $2; exit }' "$PROC_DIR/stat")
    date -d "@$boot" '+%Y-%m-%d %H:%M'
}

lvm_in_use() {
    local types
    # Read the whole list first: grep -q in a pipe could stop lsblk early and fail under pipefail.
    types=$(lsblk -r -n -o TYPE 2>/dev/null || true)
    if grep -qx lvm <<<"$types"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# State 01 in /proc/net/tcp and tcp6 is ESTABLISHED.
tcp_established() {
    cat "$PROC_DIR/net/tcp" "$PROC_DIR/net/tcp6" 2>/dev/null | awk '$4 == "01" { n++ } END { print n + 0 }'
}

logged_in_users() {
    who | awk '{ print $1 }' | sort -u | awk 'END { print NR }'
}

# The IPv4 address and MAC of the interface that holds the default route (or the first global address).
network() {
    local interface address mac
    # The awk programs read all their input (no early exit), so ip never writes to a closed pipe.
    interface=$(ip -o -4 route show default 2>/dev/null |
        awk '!found { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); found = 1; break } }') || true
    if [[ -z $interface ]]; then
        interface=$(ip -o -4 addr show scope global 2>/dev/null | awk '!found { print $2; found = 1 }') || true
    fi
    if [[ -z $interface ]]; then
        printf 'IP none (no network interface with an IPv4 address)'
        return
    fi
    address=$(ip -o -4 addr show dev "$interface" scope global 2>/dev/null |
        awk '!found { split($4, a, "/"); print a[1]; found = 1 }') || true
    mac=$(cat "$SYS_DIR/class/net/$interface/address" 2>/dev/null || true)
    printf 'IP %s (%s)' "${address:-none}" "${mac:-unknown MAC}"
}

# Commands run through sudo: from the journal when there is one, otherwise from the sudo log
# file that the Born2beRoot sudo policy sets up (Defaults logfile="/var/log/sudo/sudo.log").
sudo_commands() {
    local count
    if command -v journalctl >/dev/null 2>&1; then
        count=$(journalctl _COMM=sudo -q --no-pager 2>/dev/null | grep -c 'COMMAND=' || true)
        if ((count > 0)); then
            printf '%s' "$count"
            return
        fi
    fi
    if [[ -r $SUDO_LOG ]]; then
        grep -c 'COMMAND=' "$SUDO_LOG" || true
        return
    fi
    printf '0'
}

summary=$(
    printf '#Architecture: %s\n' "$(uname -a)"
    printf '#CPU physical : %s\n' "$(physical_cpus)"
    printf '#vCPU : %s\n' "$(virtual_cpus)"
    printf '#Memory Usage: %s\n' "$(memory_usage)"
    printf '#Disk Usage: %s\n' "$(disk_usage)"
    printf '#CPU load: %s\n' "$(cpu_load)"
    printf '#Last boot: %s\n' "$(last_boot)"
    printf '#LVM use: %s\n' "$(lvm_in_use)"
    printf '#Connections TCP : %s ESTABLISHED\n' "$(tcp_established)"
    printf '#User log: %s\n' "$(logged_in_users)"
    printf '#Network: %s\n' "$(network)"
    printf '#Sudo : %s cmd\n' "$(sudo_commands)"
)

if [[ $TO_WALL == true ]]; then
    printf '%s\n' "$summary" | wall
else
    printf '%s\n' "$summary"
fi
