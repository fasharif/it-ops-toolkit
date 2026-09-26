#!/usr/bin/env bash
#
# health-report.sh - health report for a Linux server or workstation, as text, JSON or HTML.
#
# The Linux counterpart of Get-ItoHealthReport, with the same default thresholds. See --help.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PROC_DIR=${ITO_PROC_DIR:-/proc}
REBOOT_FLAG=${ITO_REBOOT_FLAG:-/var/run/reboot-required}
SYSTEMD_DIR=${ITO_SYSTEMD_DIR:-/run/systemd/system}
DPKG_LOG=${ITO_DPKG_LOG:-/var/log/dpkg.log}
DEBIAN_MARKER=${ITO_DEBIAN_MARKER:-/etc/debian_version}

DISK_WARN=${ITO_DISK_FREE_WARN:-20}
DISK_CRIT=${ITO_DISK_FREE_CRIT:-10}
MEMORY_WARN=${ITO_MEMORY_USED_WARN:-85}
MEMORY_CRIT=${ITO_MEMORY_USED_CRIT:-95}
UPTIME_WARN=${ITO_UPTIME_DAYS_WARN:-14}
UPTIME_CRIT=${ITO_UPTIME_DAYS_CRIT:-30}
UNITS_WARN=${ITO_FAILED_UNITS_WARN:-1}
UNITS_CRIT=${ITO_FAILED_UNITS_CRIT:-5}
LOG_WARN=${ITO_CRITICAL_LOG_WARN:-1}
LOG_CRIT=${ITO_CRITICAL_LOG_CRIT:-5}
UPDATE_WARN=${ITO_UPDATE_AGE_WARN:-35}
UPDATE_CRIT=${ITO_UPDATE_AGE_CRIT:-60}
UNENCRYPTED_STATUS=${ITO_UNENCRYPTED_STATUS:-Warning}

usage() {
    cat <<'EOF'
Usage: health-report.sh [--format text|json|html] [--output FILE] [--hours N]

Checks disk space, memory, uptime, pending reboot, failed systemd units, critical journal
entries, the last package update and root filesystem encryption, and grades each one
OK, Warning, Critical or Unknown. Unknown means the data could not be read here; the
report says why. Run it as root to read the whole system journal.

Options:
  --format FORMAT  text (default), json or html.
  --output FILE    Write the report to FILE instead of standard output.
  --hours N        Hours of journal history to search for critical entries (default 24).
  -h, --help       Show this help.

Thresholds (environment variables, whole numbers; defaults match Get-ItoHealthReport):
  ITO_DISK_FREE_WARN=20     ITO_DISK_FREE_CRIT=10      (% free, lower is worse)
  ITO_MEMORY_USED_WARN=85   ITO_MEMORY_USED_CRIT=95    (% used)
  ITO_UPTIME_DAYS_WARN=14   ITO_UPTIME_DAYS_CRIT=30
  ITO_FAILED_UNITS_WARN=1   ITO_FAILED_UNITS_CRIT=5
  ITO_CRITICAL_LOG_WARN=1   ITO_CRITICAL_LOG_CRIT=5    (journal entries at priority crit or worse)
  ITO_UPDATE_AGE_WARN=35    ITO_UPDATE_AGE_CRIT=60     (days since the last package upgrade)
  ITO_UNENCRYPTED_STATUS=Warning                        (OK, Warning or Critical)

Last package update: on Debian and Ubuntu, the newest "upgrade" in /var/log/dpkg.log and its
rotated copies (dpkg.log.1, dpkg.log.2.gz and so on). Installing a new package does not count,
because it says nothing about patches. When the logs hold no upgrade at all, the age is counted
from the oldest log entry. On RPM systems it is the newest package installation or upgrade in
the rpm database, which cannot tell the two apart.

Exit status follows the Nagios plugin convention: 0 OK, 1 Warning, 2 Critical, 3 Unknown;
64 for a usage error.
EOF
}

FORMAT=text
OUTPUT=''
HOURS=24
while (($# > 0)); do
    case $1 in
        --format) FORMAT=${2:?}; shift 2 ;;
        --output) OUTPUT=${2:?}; shift 2 ;;
        --hours) HOURS=${2:?}; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage_error "Unknown option '$1'." ;;
    esac
done
[[ $FORMAT =~ ^(text|json|html)$ ]] || usage_error "--format must be text, json or html."
if ! is_integer "$HOURS" || ((HOURS < 1 || HOURS > 720)); then
    usage_error '--hours must be a whole number from 1 to 720.'
fi
for pair in DISK MEMORY UPTIME UNITS LOG UPDATE; do
    warn_var="${pair}_WARN"
    crit_var="${pair}_CRIT"
    if ! is_integer "${!warn_var}" || ! is_integer "${!crit_var}"; then
        usage_error "Thresholds must be whole numbers ($warn_var=${!warn_var}, $crit_var=${!crit_var})."
    fi
done
((DISK_CRIT <= DISK_WARN)) || usage_error 'ITO_DISK_FREE_CRIT must not be greater than ITO_DISK_FREE_WARN (less free space is worse).'
for pair in MEMORY UPTIME UNITS LOG UPDATE; do
    warn_var="${pair}_WARN"
    crit_var="${pair}_CRIT"
    ((${!crit_var} >= ${!warn_var})) || usage_error "The $pair critical threshold must not be lower than the warning threshold."
done
[[ $UNENCRYPTED_STATUS =~ ^(OK|Warning|Critical)$ ]] || usage_error 'ITO_UNENCRYPTED_STATUS must be OK, Warning or Critical.'

NAMES=()
STATUSES=()
VALUES=()
THRESHOLDS=()
DETAILS=()

# add_check NAME STATUS VALUE THRESHOLD DETAIL
add_check() {
    NAMES+=("$1")
    STATUSES+=("$2")
    VALUES+=("$3")
    THRESHOLDS+=("$4")
    DETAILS+=("$5")
}

# grade VALUE WARNING CRITICAL [lower]: OK, Warning or Critical. With "lower", lower values are worse.
grade() {
    awk -v v="$1" -v w="$2" -v c="$3" -v lower="${4:-}" 'BEGIN {
        if (lower != "") status = (v < c) ? "Critical" : (v < w) ? "Warning" : "OK"
        else status = (v >= c) ? "Critical" : (v >= w) ? "Warning" : "OK"
        print status
    }'
}

check_disks() {
    local threshold mount size used avail free_pct status value detail found=0
    threshold="Warning below ${DISK_WARN}% free, critical below ${DISK_CRIT}% free"
    # Real filesystems only, plus / even when it is an overlay (containers). Each mount once.
    while IFS=$'\t' read -r mount size used avail; do
        # Containers bind-mount single files such as /etc/hosts; they are not filesystems to report.
        if [[ ! -d $mount ]]; then
            continue
        fi
        found=1
        free_pct=$(awk -v u="$used" -v a="$avail" 'BEGIN { printf "%.1f", (u + a > 0 ? a * 100 / (u + a) : 0) }')
        status=$(grade "$free_pct" "$DISK_WARN" "$DISK_CRIT" lower)
        value=$(awk -v p="$free_pct" -v a="$avail" -v s="$size" 'BEGIN { printf "%s%% free (%.1f GB of %.1f GB)", p, a / 1048576, s / 1048576 }')
        detail=''
        if [[ $status != OK ]]; then
            detail='Free up space: clear old logs (journalctl --vacuum-size=200M), package caches (apt-get clean or dnf clean all) and large files (du -xh --max-depth=2 / | sort -h | tail).'
        fi
        add_check "Disk space $mount" "$status" "$value" "$threshold" "$detail"
    done < <(df -P -k -T 2>/dev/null | awk '
        BEGIN {
            n = split("tmpfs devtmpfs squashfs overlay efivarfs proc sysfs cgroup cgroup2 ramfs nsfs tracefs autofs fuse.lxcfs fuse.snapfuse", s, " ")
            for (i = 1; i <= n; i++) pseudo[s[i]] = 1
        }
        NR > 1 {
            mount = $7
            for (i = 8; i <= NF; i++) mount = mount " " $i
            if ((!($2 in pseudo) || mount == "/") && !seen[mount]++) print mount "\t" $3 "\t" $4 "\t" $5
        }')
    if ((found == 0)); then
        add_check 'Disk space' Unknown '' "$threshold" 'df reported no filesystems.'
    fi
}

check_memory() {
    local threshold used_pct status value detail=''
    threshold="Warning at ${MEMORY_WARN}% used, critical at ${MEMORY_CRIT}% used"
    if ! used_pct=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
            END { if (t > 0) printf "%.1f", (t - a) * 100 / t; else exit 1 }' "$PROC_DIR/meminfo" 2>/dev/null); then
        add_check Memory Unknown '' "$threshold" "Could not read $PROC_DIR/meminfo."
        return
    fi
    status=$(grade "$used_pct" "$MEMORY_WARN" "$MEMORY_CRIT")
    value=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        END { printf "%.1f%% used (%.1f GB free of %.1f GB)", (t - a) * 100 / t, a / 1048576, t / 1048576 }' "$PROC_DIR/meminfo")
    if [[ $status != OK ]]; then
        detail='Find the largest processes with: ps aux --sort=-%mem | head. Repeated high use points to a memory upgrade or a leak.'
    fi
    add_check Memory "$status" "$value" "$threshold" "$detail"
}

check_uptime() {
    local threshold days status detail=''
    threshold="Warning at ${UPTIME_WARN} days, critical at ${UPTIME_CRIT} days"
    if ! days=$(awk '{ printf "%.1f", $1 / 86400 }' "$PROC_DIR/uptime" 2>/dev/null); then
        add_check Uptime Unknown '' "$threshold" "Could not read $PROC_DIR/uptime."
        return
    fi
    status=$(grade "$days" "$UPTIME_WARN" "$UPTIME_CRIT")
    if [[ $status != OK ]]; then
        detail='Plan a reboot: kernel and library updates only take effect after one.'
    fi
    add_check Uptime "$status" "$days days" "$threshold" "$detail"
}

check_reboot() {
    local threshold='Warning when a reboot is pending' packages=()
    if [[ -f $REBOOT_FLAG ]]; then
        if [[ -r $REBOOT_FLAG.pkgs ]]; then
            mapfile -t packages < <(sort -u "$REBOOT_FLAG.pkgs")
        fi
        add_check 'Pending reboot' Warning "Reboot required${packages[*]:+ by: $(join_by ', ' "${packages[@]}")}" "$threshold" \
            'Reboot in the next maintenance window to finish applying updates.'
    elif command -v needs-restarting >/dev/null 2>&1; then
        if needs-restarting -r >/dev/null 2>&1; then
            add_check 'Pending reboot' OK 'No reboot required (needs-restarting -r)' "$threshold" ''
        else
            add_check 'Pending reboot' Warning 'Reboot required (needs-restarting -r)' "$threshold" \
                'Reboot in the next maintenance window to finish applying updates.'
        fi
    elif [[ -f $DEBIAN_MARKER ]]; then
        add_check 'Pending reboot' OK 'No reboot-required flag is set' "$threshold" ''
    else
        add_check 'Pending reboot' Unknown '' "$threshold" \
            "Neither $REBOOT_FLAG nor needs-restarting is available on this system."
    fi
}

check_units() {
    local threshold units=() status value detail=''
    threshold="Warning at ${UNITS_WARN} failed, critical at ${UNITS_CRIT} failed"
    if [[ ! -d $SYSTEMD_DIR ]] || ! command -v systemctl >/dev/null 2>&1; then
        add_check 'Failed systemd units' Unknown '' "$threshold" 'systemd is not running here (for example inside a container).'
        return
    fi
    mapfile -t units < <(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk 'NF { print $1 }')
    status=$(grade "${#units[@]}" "$UNITS_WARN" "$UNITS_CRIT")
    value='No failed systemd units'
    if ((${#units[@]} > 0)); then
        value="${#units[@]} failed unit(s): $(join_by ', ' "${units[@]}")"
        detail='See why with: systemctl status UNIT and journalctl -u UNIT -b. Restart it with systemctl restart UNIT once fixed.'
    fi
    add_check 'Failed systemd units' "$status" "$value" "$threshold" "$detail"
}

check_journal() {
    local threshold entries=() status value detail='' noun=entries
    threshold="Warning at ${LOG_WARN} entries, critical at ${LOG_CRIT} (priority crit, alert or emerg, last ${HOURS} hours)"
    if [[ ! -d $SYSTEMD_DIR ]] || ! command -v journalctl >/dev/null 2>&1; then
        add_check 'Critical journal entries' Unknown '' "$threshold" 'The systemd journal is not available here (for example inside a container).'
        return
    fi
    mapfile -t entries < <(journalctl -q --no-pager -p crit --since "-${HOURS}h" -o short-iso 2>/dev/null)
    status=$(grade "${#entries[@]}" "$LOG_WARN" "$LOG_CRIT")
    value="No critical entries in the last $HOURS hours"
    if ((${#entries[@]} > 0)); then
        if ((${#entries[@]} == 1)); then
            noun=entry
        fi
        value="${#entries[@]} critical $noun in the last $HOURS hours"
        detail="Most recent: ${entries[${#entries[@]} - 1]}"
    fi
    if (($(id -u) != 0)); then
        detail+="${detail:+ }Run as root to include the whole system journal."
    fi
    add_check 'Critical journal entries' "$status" "$value" "$threshold" "$detail"
}

# dpkg_log_lines: prints every line of the dpkg log and its rotated copies, compressed or not.
dpkg_log_lines() {
    local log
    for log in "$DPKG_LOG" "$DPKG_LOG".[0-9]*; do
        [[ -r $log ]] || continue
        if [[ $log == *.gz ]]; then
            gzip -dc -- "$log" 2>/dev/null || true
        else
            cat -- "$log"
        fi
    done
}

# days_ago N: "today", "1 day ago" or "N days ago".
days_ago() {
    case $1 in
        0) printf 'today' ;;
        1) printf '1 day ago' ;;
        *) printf '%s days ago' "$1" ;;
    esac
}

check_updates() {
    local threshold last='' oldest='' source='' value epoch age status detail=''
    threshold="Warning after ${UPDATE_WARN} days, critical after ${UPDATE_CRIT} days (days since the last package upgrade)"
    if [[ -r $DPKG_LOG ]]; then
        # Only upgrades count: installing a new package says nothing about patches.
        last=$(dpkg_log_lines | awk '$3 == "upgrade" && $1 > d { d = $1 } END { print d }')
        source='dpkg log'
        if [[ -z $last ]]; then
            oldest=$(dpkg_log_lines | awk '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && (o == "" || $1 < o) { o = $1 } END { print o }')
        fi
    elif command -v rpm >/dev/null 2>&1; then
        epoch=$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -n 1)
        [[ -n $epoch ]] && last=$(date -u -d "@$epoch" +%Y-%m-%d)
        source='rpm database'
    fi
    if [[ -n $last ]]; then
        age=$((($(date -u +%s) - $(date -u -d "$last" +%s)) / 86400))
        value="$last ($(days_ago "$age"), from the $source)"
    elif [[ -n $oldest ]]; then
        age=$((($(date -u +%s) - $(date -u -d "$oldest" +%s)) / 86400))
        value="No upgrade since the dpkg logs began on $oldest ($(days_ago "$age"))"
    else
        add_check 'Last package update' Unknown '' "$threshold" 'No package history was found (dpkg log or rpm database).'
        return
    fi
    status=$(grade "$age" "$UPDATE_WARN" "$UPDATE_CRIT")
    if [[ $status != OK ]]; then
        detail='Install updates: apt-get update && apt-get upgrade, or dnf upgrade. Check unattended-upgrades or dnf-automatic is enabled.'
    fi
    add_check 'Last package update' "$status" "$value" "$threshold" "$detail"
}

check_encryption() {
    local threshold root_source types
    threshold="Root filesystem should be on an encrypted device (status when not: $UNENCRYPTED_STATUS)"
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ $root_source != /dev/* ]]; then
        add_check 'Disk encryption' Unknown '' "$threshold" \
            "The root filesystem is not a block device (${root_source:-unknown}), so encryption cannot be checked here."
        return
    fi
    types=$(lsblk -s -r -n -o TYPE "$root_source" 2>/dev/null || true)
    if grep -qx crypt <<<"$types"; then
        add_check 'Disk encryption' OK 'Root filesystem is on an encrypted (LUKS/dm-crypt) device' "$threshold" ''
    elif [[ -n $types ]]; then
        add_check 'Disk encryption' "$UNENCRYPTED_STATUS" 'Root filesystem is not encrypted' "$threshold" \
            'Encryption has to be set up at installation or by migrating to a new LUKS volume; escalate to the platform team if policy requires it.'
    else
        add_check 'Disk encryption' Unknown '' "$threshold" "lsblk could not describe $root_source."
    fi
}

check_disks
check_memory
check_uptime
check_reboot
check_units
check_journal
check_updates
check_encryption

OVERALL=OK
declare -A RANK=([OK]=0 [Unknown]=1 [Warning]=2 [Critical]=3)
for status in "${STATUSES[@]}"; do
    if ((RANK[$status] > RANK[$OVERALL])); then
        OVERALL=$status
    fi
done
HOST=$(hostname 2>/dev/null || cat "$PROC_DIR/sys/kernel/hostname")
GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

render_text() {
    local i
    printf 'Health report for %s\n' "$HOST"
    printf 'Generated %s by it-ops-toolkit health-report.sh\n' "$GENERATED"
    printf 'Overall status: %s\n\n' "$OVERALL"
    printf '%-26s %-9s %s\n' 'Check' 'Status' 'Value'
    for i in "${!NAMES[@]}"; do
        printf '%-26s %-9s %s\n' "${NAMES[i]}" "${STATUSES[i]}" "${VALUES[i]:--}"
    done
    printf '\nNotes:\n'
    for i in "${!NAMES[@]}"; do
        if [[ -n ${DETAILS[i]} ]]; then
            printf -- '- %s: %s\n' "${NAMES[i]}" "${DETAILS[i]}"
        fi
    done
}

render_json() {
    local i separator
    printf '{\n'
    printf '  "ComputerName": "%s",\n' "$(json_escape "$HOST")"
    printf '  "GeneratedAtUtc": "%s",\n' "$GENERATED"
    printf '  "Tool": "health-report.sh",\n'
    printf '  "EventWindowHours": %s,\n' "$HOURS"
    printf '  "OverallStatus": "%s",\n' "$OVERALL"
    printf '  "Checks": [\n'
    for i in "${!NAMES[@]}"; do
        separator=','
        if ((i == ${#NAMES[@]} - 1)); then
            separator=''
        fi
        printf '    { "Name": "%s", "Status": "%s", "Value": "%s", "Threshold": "%s", "Detail": "%s" }%s\n' \
            "$(json_escape "${NAMES[i]}")" "${STATUSES[i]}" "$(json_escape "${VALUES[i]}")" \
            "$(json_escape "${THRESHOLDS[i]}")" "$(json_escape "${DETAILS[i]}")" "$separator"
    done
    printf '  ]\n}\n'
}

render_html() {
    local i
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Health report: $(html_escape "$HOST")</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2328; background: #ffffff; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #d0d7de; padding: 0.45rem 0.6rem; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
.status { display: inline-block; min-width: 5.5rem; padding: 0.1rem 0.5rem; border-radius: 0.3rem; font-weight: 600; text-align: center; }
.status-OK { background: #dafbe1; color: #116329; }
.status-Warning { background: #fff8c5; color: #7d4e00; }
.status-Critical { background: #ffebe9; color: #a40e26; }
.status-Unknown { background: #eaeef2; color: #424a53; }
</style>
</head>
<body>
<h1>Health report: $(html_escape "$HOST")</h1>
<p>Generated $GENERATED (UTC) by it-ops-toolkit health-report.sh. Overall status: <span class="status status-$OVERALL">$OVERALL</span></p>
<table>
<thead><tr><th scope="col">Check</th><th scope="col">Status</th><th scope="col">Value</th><th scope="col">Threshold</th><th scope="col">What to do</th></tr></thead>
<tbody>
EOF
    for i in "${!NAMES[@]}"; do
        printf '<tr><td>%s</td><td><span class="status status-%s">%s</span></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(html_escape "${NAMES[i]}")" "${STATUSES[i]}" "${STATUSES[i]}" "$(html_escape "${VALUES[i]}")" \
            "$(html_escape "${THRESHOLDS[i]}")" "$(html_escape "${DETAILS[i]}")"
    done
    printf '</tbody>\n</table>\n</body>\n</html>\n'
}

render() {
    case $FORMAT in
        text) render_text ;;
        json) render_json ;;
        html) render_html ;;
    esac
}

if [[ -n $OUTPUT ]]; then
    render >"$OUTPUT"
else
    render
fi

case $OVERALL in
    OK) exit 0 ;;
    Warning) exit 1 ;;
    Critical) exit 2 ;;
    *) exit 3 ;;
esac
