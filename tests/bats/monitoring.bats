#!/usr/bin/env bats
#
# Unit tests for linux/monitoring.sh with a fake /proc and /sys, chosen so every figure in the
# Born2beRoot summary can be checked exactly.

# The fakes are written in single quotes so their variables expand when they run (SC2016).
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    common_setup
    T=$BATS_TEST_TMPDIR
    export TZ=UTC
    mkdir -p "$T/proc/net" "$T/sys/class/net/enp0s3"

    # Two sockets with two logical CPUs each.
    for cpu in 0 1 2 3; do
        printf 'processor\t: %s\nmodel name\t: Test CPU\nphysical id\t: %s\n\n' "$cpu" $((cpu / 2))
    done >"$T/proc/cpuinfo"
    # 2000 MB of memory, 500 MB used.
    printf 'MemTotal:        2048000 kB\nMemFree:          900000 kB\nMemAvailable:    1536000 kB\n' >"$T/proc/meminfo"
    # Two samples of /proc/stat: between them the CPU was busy 100 of 200 ticks. btime is 2026-01-01 00:00 UTC.
    printf 'cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 50 0 50 350 50 0 0 0 0 0\nbtime 1767225600\n' >"$T/proc/stat"
    printf 'cpu  150 0 150 750 150 0 0 0 0 0\ncpu0 75 0 75 375 75 0 0 0 0 0\nbtime 1767225600\n' >"$T/stat.second"
    # Two established IPv4 connections, one listening socket, one established IPv6 connection.
    cat >"$T/proc/net/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1000
   1: 0F02000A:0016 0202000A:D2F4 01 00000000:00000000 02:0008A4B2 00000000     0        0 1001
   2: 0F02000A:0016 0202000A:D2F6 01 00000000:00000000 02:0008A4B2 00000000     0        0 1002
EOF
    cat >"$T/proc/net/tcp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue
   0: 00000000000000000000000001000000:0016 00000000000000000000000001000000:D300 01 00000000:00000000
EOF
    printf '08:00:27:51:9b:a5\n' >"$T/sys/class/net/enp0s3/address"
    export ITO_PROC_DIR="$T/proc" ITO_SYS_DIR="$T/sys" ITO_SUDO_LOG="$T/sudo.log" ITO_CPU_SAMPLE_SECONDS=1

    fake uname 'echo "Linux fsharif42 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01) x86_64 GNU/Linux"'
    # The fake sleep swaps in the second /proc/stat sample, so the CPU load is exact.
    fake sleep "cp '$T/stat.second' '$T/proc/stat'"
    fake df 'cat <<EOF
Filesystem                  1024-blocks    Used Available Capacity Mounted on
/dev/mapper/LVMGroup-root      11534336 2097152   9437184      19% /
tmpfs                            204800       0    204800       0% /run
/dev/sda1                       1048576  102400    946176      10% /boot
/dev/mapper/LVMGroup-root      11534336 2097152   9437184      19% /var/lib/bind-mount
EOF'
    fake lsblk 'printf "disk\npart\npart\ncrypt\nlvm\nlvm\n"'
    fake who 'printf "fsharif  tty1   2026-09-26 08:00\nfsharif  pts/0  2026-09-26 08:05 (10.0.2.2)\nroot     pts/1  2026-09-26 08:06 (10.0.2.2)\n"'
    fake ip 'case "$*" in
    "-o -4 route show default") echo "default via 10.0.2.2 dev enp0s3 proto dhcp src 10.0.2.15 metric 100" ;;
    "-o -4 addr show dev enp0s3 scope global") echo "2: enp0s3    inet 10.0.2.15/24 brd 10.0.2.255 scope global dynamic enp0s3" ;;
    "-o -4 addr show scope global") echo "2: enp0s3    inet 10.0.2.15/24 brd 10.0.2.255 scope global dynamic enp0s3" ;;
esac'
    fake journalctl 'for i in $(seq 1 42); do echo "Sep 26 08:1$((i % 10)) fsharif42 sudo[$i]: fsharif : TTY=pts/0 ; PWD=/home/fsharif ; USER=root ; COMMAND=/usr/bin/apt update"; done
echo "Sep 26 08:20 fsharif42 sudo[99]: pam_unix(sudo:session): session opened for user root"'
    fake wall "cat >'$T/wall.txt'"
}

@test 'prints the Born2beRoot summary with exact figures' {
    run "$REPO_ROOT/linux/monitoring.sh" --stdout
    assert_success
    assert_line --index 0 '#Architecture: Linux fsharif42 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01) x86_64 GNU/Linux'
    assert_line --index 1 '#CPU physical : 2'
    assert_line --index 2 '#vCPU : 4'
    assert_line --index 3 '#Memory Usage: 500/2000MB (25.00%)'
    assert_line --index 4 '#Disk Usage: 2148/12Gb (17%)'
    assert_line --index 5 '#CPU load: 50.0%'
    assert_line --index 6 '#Last boot: 2026-01-01 00:00'
    assert_line --index 7 '#LVM use: yes'
    assert_line --index 8 '#Connections TCP : 3 ESTABLISHED'
    assert_line --index 9 '#User log: 2'
    assert_line --index 10 '#Network: IP 10.0.2.15 (08:00:27:51:9b:a5)'
    assert_line --index 11 '#Sudo : 42 cmd'
    assert_equal "${#lines[@]}" 12
}

@test 'broadcasts the summary with wall by default' {
    run "$REPO_ROOT/linux/monitoring.sh"
    assert_success
    assert_output ''
    run cat "$T/wall.txt"
    assert_line --index 0 --partial '#Architecture: Linux fsharif42'
    assert_line --index 11 '#Sudo : 42 cmd'
}

@test 'counts one physical CPU when cpuinfo has no physical id' {
    printf 'processor\t: 0\nmodel name\t: ARM Cortex-A72\n\nprocessor\t: 1\nmodel name\t: ARM Cortex-A72\n\n' >"$T/proc/cpuinfo"
    run "$REPO_ROOT/linux/monitoring.sh" --stdout
    assert_line '#CPU physical : 1'
    assert_line '#vCPU : 2'
}

@test 'reads the sudo log file when there is no journal' {
    rm -f "$FAKE_BIN/journalctl"
    isolate_path uname df lsblk who ip sleep wall cp
    printf 'Sep 26 08:10:01 : fsharif : TTY=pts/0 ; PWD=/home/fsharif ; USER=root ;\n    COMMAND=/usr/bin/ls\n' >"$ITO_SUDO_LOG"
    printf 'Sep 26 08:11:01 : fsharif : TTY=pts/0 ; PWD=/home/fsharif ; USER=root ;\n    COMMAND=/usr/bin/id\n' >>"$ITO_SUDO_LOG"
    run "$REPO_ROOT/linux/monitoring.sh" --stdout
    assert_success
    assert_line '#Sudo : 2 cmd'
}

@test 'reports no LVM, no disks and no network plainly' {
    fake lsblk 'printf "disk\npart\n"'
    fake df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 1000 10 990 1%% /\n"'
    fake ip 'exit 0'
    run "$REPO_ROOT/linux/monitoring.sh" --stdout
    assert_success
    assert_line '#LVM use: no'
    assert_line '#Disk Usage: 0/0Gb (0%)'
    assert_line '#Network: IP none (no network interface with an IPv4 address)'
}

@test 'rejects unknown options' {
    run "$REPO_ROOT/linux/monitoring.sh" --bogus
    assert_failure 64
}
