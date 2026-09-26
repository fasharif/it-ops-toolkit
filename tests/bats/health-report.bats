#!/usr/bin/env bats
#
# Unit tests for linux/health-report.sh with fake system commands and a fake /proc.

# The fakes are written in single quotes so their variables expand when they run (SC2016).
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    common_setup
    T=$BATS_TEST_TMPDIR

    # A healthy machine: 40% of / used, half the memory used, up two days, updated three days ago.
    mkdir -p "$T/proc" "$T/systemd"
    printf 'MemTotal:        8000000 kB\nMemFree:          500000 kB\nMemAvailable:    4000000 kB\n' >"$T/proc/meminfo"
    printf '172800.00 300000.00\n' >"$T/proc/uptime"
    printf '%s 06:25:01 upgrade openssl:amd64 3.5.1-1 3.5.4-1\n' "$(date -u -d '3 days ago' +%Y-%m-%d)" >"$T/dpkg.log"
    touch "$T/debian_version"
    export ITO_PROC_DIR="$T/proc" ITO_REBOOT_FLAG="$T/reboot-required" ITO_SYSTEMD_DIR="$T/systemd" \
        ITO_DPKG_LOG="$T/dpkg.log" ITO_DEBIAN_MARKER="$T/debian_version"

    fake hostname 'echo pc-test01'
    fake df 'cat <<EOF
Filesystem           Type     1024-blocks     Used Available Capacity Mounted on
/dev/mapper/vg-root  ext4        20000000  8000000  12000000      40% /
tmpfs                tmpfs        4000000        0   4000000       0% /run
/dev/sda1            ext4          500000   100000    400000      20% /usr
overlay              overlay     10000000  1000000   9000000      10% /var/lib/docker/overlay2/abc/merged
/dev/mapper/vg-root  ext4        20000000  8000000  12000000      40% /etc/hostname
EOF'
    fake systemctl 'exit 0'
    fake journalctl 'exit 0'
    fake findmnt 'echo /dev/mapper/vg-root'
    fake lsblk 'printf "lvm\ncrypt\npart\ndisk\n"'
}

report() {
    "$REPO_ROOT/linux/health-report.sh" "$@"
}

@test 'reports a healthy machine as OK and exits 0' {
    run report
    assert_success
    assert_line 'Health report for pc-test01'
    assert_line 'Overall status: OK'
    assert_line --regexp '^Disk space / +OK +60\.0% free \(11\.4 GB of 19\.1 GB\)$'
    assert_line --regexp '^Disk space /usr +OK +80\.0% free'
    assert_line --regexp '^Memory +OK +50\.0% used \(3\.8 GB free of 7\.6 GB\)$'
    assert_line --regexp '^Uptime +OK +2\.0 days$'
    assert_line --regexp '^Pending reboot +OK +No reboot-required flag is set$'
    assert_line --regexp '^Failed systemd units +OK +No failed systemd units$'
    assert_line --regexp '^Critical journal entries +OK +No critical entries in the last 24 hours$'
    assert_line --regexp '^Last package update +OK +[0-9-]{10} \(3 days ago, from the dpkg log\)$'
    assert_line --regexp '^Disk encryption +OK +Root filesystem is on an encrypted \(LUKS/dm-crypt\) device$'
}

@test 'skips pseudo filesystems, overlay layers and single-file bind mounts' {
    run report
    refute_line --partial '/run'
    refute_line --partial 'overlay2'
    refute_line --partial '/etc/hostname'
}

@test 'grades free disk space against the thresholds' {
    # Not "status": bats sets that variable after every run.
    local free expected
    for pair in '25:OK' '19:Warning' '9:Critical'; do
        free=${pair%%:*}
        expected=${pair#*:}
        fake df "printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 ext4 100 $((100 - free)) $free 1%% /\n'"
        run report
        assert_line --regexp "^Disk space / +$expected +$free\.0% free"
    done
}

@test 'includes an overlay root filesystem, as inside a container' {
    fake df "printf 'Filesystem Type 1024-blocks Used Available Capacity Mounted on\noverlay overlay 1000 950 50 95%% /\n'"
    run report
    assert_failure 2
    assert_line --regexp '^Disk space / +Critical +5\.0% free'
}

@test 'grades memory use and uptime against the thresholds' {
    printf 'MemTotal: 1000 kB\nMemAvailable: 100 kB\n' >"$T/proc/meminfo"
    printf '%s 0\n' $((40 * 86400)) >"$T/proc/uptime"
    run report
    assert_failure 2
    assert_line --regexp '^Memory +Warning +90\.0% used'
    assert_line --regexp '^Uptime +Critical +40\.0 days$'
    assert_line --partial '- Uptime: Plan a reboot'
}

@test 'lists the packages that need a reboot' {
    touch "$ITO_REBOOT_FLAG"
    printf 'linux-image-6.12.48+deb13-amd64\nlibc6\nlibc6\n' >"$ITO_REBOOT_FLAG.pkgs"
    run report
    assert_failure 1
    assert_line --regexp '^Pending reboot +Warning +Reboot required by: libc6, linux-image-6\.12\.48\+deb13-amd64$'
}

@test 'asks needs-restarting on RPM systems and is Unknown when there is no way to tell' {
    rm -f "$ITO_DEBIAN_MARKER"
    fake needs-restarting 'exit 1'
    run report
    assert_line --regexp '^Pending reboot +Warning +Reboot required \(needs-restarting -r\)$'
    rm -f "$FAKE_BIN/needs-restarting"
    isolate_path df systemctl journalctl findmnt lsblk hostname
    run report
    assert_line --regexp '^Pending reboot +Unknown +-$'
    assert_line --partial "- Pending reboot: Neither $ITO_REBOOT_FLAG nor needs-restarting is available"
}

@test 'counts failed systemd units' {
    fake systemctl 'printf "nginx.service loaded failed failed A high performance web server\ncups.service loaded failed failed CUPS Scheduler\n"'
    run report
    assert_failure 1
    assert_line --regexp '^Failed systemd units +Warning +2 failed unit\(s\): nginx\.service, cups\.service$'
    fake systemctl 'for i in 1 2 3 4 5; do echo "unit$i.service loaded failed failed Unit"; done'
    run report
    assert_line --regexp '^Failed systemd units +Critical +5 failed unit'
}

@test 'reports systemd checks as Unknown where systemd is not running' {
    rmdir "$ITO_SYSTEMD_DIR"
    run report
    assert_line --regexp '^Failed systemd units +Unknown +-$'
    assert_line --regexp '^Critical journal entries +Unknown +-$'
    assert_line --partial 'systemd is not running here (for example inside a container)'
}

@test 'counts critical journal entries and shows the most recent' {
    fake journalctl 'printf "2026-09-25T08:15:01+0000 pc kernel: EXT4-fs error (device sda1)\n2026-09-25T09:00:00+0000 pc kernel: Out of memory: Killed process 4242 (java)\n"'
    run report --hours 48
    assert_failure 1
    assert_line --regexp '^Critical journal entries +Warning +2 critical entries in the last 48 hours$'
    assert_line --partial 'Most recent: 2026-09-25T09:00:00+0000 pc kernel: Out of memory: Killed process 4242 (java)'
}

@test 'grades the last package update by age, from dpkg or rpm' {
    printf '%s 06:25:01 upgrade libc6:amd64 2.41-11 2.41-12\n' "$(date -u -d '50 days ago' +%Y-%m-%d)" >"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +Warning +[0-9-]{10} \(50 days ago'
    printf '%s 06:25:01 status installed vim:amd64 2:9.1\n' "$(date -u -d '1 day ago' +%Y-%m-%d)" >>"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +Warning +[0-9-]{10} \(50 days ago'
    rm -f "$ITO_DPKG_LOG"
    fake rpm "printf '%s\n%s\n' $(date -u -d '70 days ago' +%s) $(date -u -d '90 days ago' +%s)"
    run report
    assert_line --regexp '^Last package update +Critical +[0-9-]{10} \(70 days ago, from the rpm database\)$'
}

@test 'writes the update age as "today", "1 day ago" or "N days ago"' {
    printf '%s 06:25:01 upgrade libc6:amd64 2.41-11 2.41-12\n' "$(date -u +%Y-%m-%d)" >"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +OK +[0-9-]{10} \(today, from the dpkg log\)$'
    printf '%s 06:25:01 upgrade libc6:amd64 2.41-11 2.41-12\n' "$(date -u -d '1 day ago' +%Y-%m-%d)" >"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +OK +[0-9-]{10} \(1 day ago, from the dpkg log\)$'
}

@test 'does not count installing a new package as an update' {
    {
        printf '%s 06:25:01 upgrade libc6:amd64 2.41-11 2.41-12\n' "$(date -u -d '50 days ago' +%Y-%m-%d)"
        printf '%s 09:00:00 install htop:amd64 <none> 3.4.1-5\n' "$(date -u -d '1 day ago' +%Y-%m-%d)"
    } >"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +Warning +[0-9-]{10} \(50 days ago, from the dpkg log\)$'
}

@test 'reads upgrades from rotated and compressed dpkg logs' {
    printf '%s 09:00:00 install htop:amd64 <none> 3.4.1-5\n' "$(date -u -d '1 day ago' +%Y-%m-%d)" >"$ITO_DPKG_LOG"
    printf '%s 06:25:01 upgrade libc6:amd64 2.41-11 2.41-12\n' "$(date -u -d '40 days ago' +%Y-%m-%d)" >"$ITO_DPKG_LOG.1"
    printf '%s 06:25:01 upgrade openssl:amd64 3.5.1-1 3.5.4-1\n' "$(date -u -d '80 days ago' +%Y-%m-%d)" | gzip >"$ITO_DPKG_LOG.2.gz"
    run report
    assert_line --regexp '^Last package update +Warning +[0-9-]{10} \(40 days ago, from the dpkg log\)$'
    rm -f "$ITO_DPKG_LOG.1"
    run report
    assert_line --regexp '^Last package update +Critical +[0-9-]{10} \(80 days ago, from the dpkg log\)$'
}

@test 'counts from the start of the dpkg logs when they hold no upgrade' {
    {
        printf '%s 10:00:00 install base-files:amd64 <none> 13.8\n' "$(date -u -d '70 days ago' +%Y-%m-%d)"
        printf '%s 09:00:00 install htop:amd64 <none> 3.4.1-5\n' "$(date -u -d '1 day ago' +%Y-%m-%d)"
    } >"$ITO_DPKG_LOG"
    run report
    assert_line --regexp '^Last package update +Critical +No upgrade since the dpkg logs began on [0-9-]{10} \(70 days ago\)$'
}

@test 'is Unknown about updates when there is no package history' {
    rm -f "$ITO_DPKG_LOG"
    isolate_path df systemctl journalctl findmnt lsblk hostname
    run report
    assert_line --regexp '^Last package update +Unknown +-$'
}

@test 'flags an unencrypted root filesystem, with a configurable status' {
    fake lsblk 'printf "part\ndisk\n"'
    run report
    assert_failure 1
    assert_line --regexp '^Disk encryption +Warning +Root filesystem is not encrypted$'
    ITO_UNENCRYPTED_STATUS=Critical run report
    assert_failure 2
    assert_line --regexp '^Disk encryption +Critical +'
}

@test 'cannot check encryption when root is not a block device, and exits 3 when only that is unknown' {
    fake findmnt 'echo overlay'
    run report
    assert_failure 3
    assert_line 'Overall status: Unknown'
    assert_line --partial 'The root filesystem is not a block device (overlay)'
}

@test 'writes valid JSON with escaped values' {
    fake hostname "echo 'pc\"quoted'"
    fake systemctl 'echo "weird\\name.service loaded failed failed Unit"'
    run report --format json
    assert_failure 1
    printf '%s\n' "$output" >"$T/report.json"
    run python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["ComputerName"])
print(data["OverallStatus"])
units = [c for c in data["Checks"] if c["Name"] == "Failed systemd units"][0]
print(units["Value"])
print(len(data["Checks"]))
' "$T/report.json"
    assert_line --index 0 'pc"quoted'
    assert_line --index 1 'Warning'
    assert_line --index 2 '1 failed unit(s): weird\name.service'
    assert_line --index 3 '9'
}

@test 'writes an HTML report that escapes values' {
    fake systemctl 'echo "<script>.service loaded failed failed Unit"'
    run report --format html --output "$T/report.html"
    assert_failure 1
    assert_output ''
    run cat "$T/report.html"
    assert_line --partial '<title>Health report: pc-test01</title>'
    assert_output --partial '1 failed unit(s): &lt;script&gt;.service'
    refute_output --partial '<script>'
}

@test 'honours threshold environment variables and rejects bad ones' {
    ITO_DISK_FREE_WARN=70 ITO_DISK_FREE_CRIT=50 run report
    assert_line --regexp '^Disk space / +Warning +60\.0% free'
    ITO_DISK_FREE_WARN=5 ITO_DISK_FREE_CRIT=10 run report
    assert_failure 64
    assert_output --partial 'ITO_DISK_FREE_CRIT must not be greater than ITO_DISK_FREE_WARN'
    ITO_MEMORY_USED_WARN=abc run report
    assert_failure 64
    assert_output --partial 'Thresholds must be whole numbers (MEMORY_WARN=abc'
    ITO_UPTIME_DAYS_WARN=40 run report
    assert_failure 64
    ITO_UNENCRYPTED_STATUS=Maybe run report
    assert_failure 64
}

@test 'rejects bad options' {
    run report --format xml
    assert_failure 64
    run report --hours 0
    assert_failure 64
    run report --verbose
    assert_failure 64
    assert_output --partial "Unknown option '--verbose'."
}
