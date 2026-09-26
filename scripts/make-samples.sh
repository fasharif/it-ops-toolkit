#!/usr/bin/env bash
#
# Regenerates the sample output in docs/samples that comes from Linux, in containers only:
#   samba-onboarding.txt, samba-offboarding.txt  the Bash scripts against the Samba AD test DC
#   linux-health-and-monitoring.txt              health-report.sh and monitoring.sh
#   net-check.txt                                net-check.sh
#   test-itonetwork-linux.txt                    Test-ItoNetwork in PowerShell 7 on Linux
# Each file starts with a line that says how and where it was produced. The Windows samples
# are recorded by hand; docs/samples/README.md gives their commands.
#
# Needs Docker with Compose v2 and internet access (the network checks use www.microsoft.com).
# The domain is the throwaway integration test domain, removed again at the end.

# The scripts in single quotes run inside the containers, where their variables expand (SC2016).
# shellcheck disable=SC2016

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    root=$(pwd -W)
else
    root=$(pwd)
fi

samples=docs/samples
today=$(date -u +%Y-%m-%d)
image=${ITO_TEST_IMAGE:-it-ops-toolkit-test}
powershell_image=mcr.microsoft.com/powershell:7.5-ubuntu-24.04

SAMBA_ADMIN_PASSWORD="It-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')-Aa1!"
export SAMBA_ADMIN_PASSWORD
project=${COMPOSE_PROJECT_NAME:-it-ops-toolkit-samples-$$}
compose=(docker compose -f tests/integration/compose.yaml -p "$project")
work=$(mktemp -d)

cleanup() {
    "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT

# section NAME FILE: prints the lines of FILE between "=== NAME ===" and the next marker.
section() {
    awk -v start="=== $1 ===" '$0 == start { on = 1; next } /^=== .* ===$/ { on = 0 } on' "$2"
}

echo '==> Samba AD samples'
"${compose[@]}" build --quiet
"${compose[@]}" up --detach --wait dc >/dev/null 2>&1
samba_version=$("${compose[@]}" exec -T dc samba --version)
# The same set-up as tests/integration/samba-ad.bats, then the commands shown in the samples.
"${compose[@]}" run --rm -T --entrypoint bash client -c '
    set -uo pipefail
    mkdir -p /srv/it-ops/deliver /srv/it-ops/audit
    printf "username=Administrator\npassword=%s\ndomain=CORP\n" "$SAMBA_ADMIN_PASSWORD" >/srv/it-ops/admin.auth
    chmod 600 /srv/it-ops/admin.auth
    export ITO_AUTH_FILE=/srv/it-ops/admin.auth
    for ou in "OU=Staff" "OU=Finance,OU=Staff" "OU=Sales,OU=Staff" "OU=IT,OU=Staff" "OU=Human Resources,OU=Staff" "OU=Disabled Users"; do
        samba-tool ou create "$ou" -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" >/dev/null
    done
    for group in All-Staff Finance-Users Finance-Share-RW Sales-Users CRM-Users IT-Users IT-Helpdesk HR-Users HR-Share-RW; do
        samba-tool group add "$group" -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" >/dev/null
    done
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Service Desk Delivery" \
        -keyout /srv/it-ops/delivery.key -out /srv/it-ops/delivery.pem 2>/dev/null
    run() {
        printf "$ %s\n" "$*"
        "$@" 2>&1
        printf "\n"
    }
    echo "=== onboarding ==="
    run linux/onboard-user.sh --csv examples/new-starters.csv --config config/onboarding.example.json --deliver-dir /srv/it-ops/deliver --deliver-cert /srv/it-ops/delivery.pem
    run linux/onboard-user.sh --csv examples/new-starters.csv --config config/onboarding.example.json --deliver-dir /srv/it-ops/deliver --deliver-cert /srv/it-ops/delivery.pem
    echo "=== offboarding ==="
    run linux/offboard-user.sh --user sara.ali --ticket INC0012345 --audit-dir /srv/it-ops/audit --config config/onboarding.example.json
    run linux/offboard-user.sh --user sara.ali --ticket INC0012345 --audit-dir /srv/it-ops/audit --config config/onboarding.example.json
    echo "=== end ==="
' >"$work/samba.txt"
"${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1

samba_note="# Recorded by scripts/make-samples.sh on $today in the Samba AD integration environment (tests/integration): a throwaway test domain on Samba ${samba_version#Version }, with the scripts run in the Debian 13 client container; ITO_LDAP_URL and ITO_AUTH_FILE are set there."
{
    printf '%s\n' "$samba_note"
    section onboarding "$work/samba.txt"
} | sed -e '$ { /^$/d }' >"$samples/samba-onboarding.txt"
{
    printf '%s\n' "$samba_note"
    section offboarding "$work/samba.txt"
} | sed -e '$ { /^$/d }' >"$samples/samba-offboarding.txt"

echo '==> Linux health report, Born2beRoot summary and network checks'
docker run --rm --memory 256m --hostname it-ops-test -v "$root:/work:ro" -w /work --entrypoint bash "$image:test" -c '
    run() {
        printf "$ %s\n" "$*"
        "$@" 2>&1
        printf "(exit status %s)\n\n" "$?"
    }
    echo "=== health ==="
    run linux/health-report.sh
    printf "$ linux/monitoring.sh --stdout\n"
    linux/monitoring.sh --stdout 2>&1
    echo "=== net ==="
    run linux/net-check.sh --max-hops 8 www.microsoft.com
    run linux/net-check.sh --no-trace intranet.corp.itops.test
    echo "=== end ==="
' >"$work/linux.txt"
container_note="# Recorded by scripts/make-samples.sh on $today in the Debian 13 test container (tests/docker/Dockerfile, target test) on $(docker info --format "{{.OperatingSystem}}"), hostname it-ops-test. It is a container, not a server: there is no systemd, LVM or LUKS, which is why some checks are Unknown."
{
    printf '%s\n' "$container_note"
    section health "$work/linux.txt"
} | sed -e '$ { /^$/d }' >"$samples/linux-health-and-monitoring.txt"
{
    printf '%s\n' "${container_note%%, hostname*}. Docker's network layer answers ICMP itself, so the route trace is not meaningful."
    section net "$work/linux.txt"
} | sed -e '$ { /^$/d }' >"$samples/net-check.txt"

echo '==> Test-ItoNetwork in PowerShell 7 on Linux'
{
    printf '# Recorded by scripts/make-samples.sh on %s in PowerShell 7.5 (%s container) on Linux.\n' "$today" "$powershell_image"
    docker run --rm --memory 512m -v "$root:/work:ro" -w /work "$powershell_image" pwsh -NoProfile -Command '
        Import-Module ./src/ItOpsToolkit/ItOpsToolkit.psd1
        "PS> Test-ItoNetwork -SkipTrace | Select-Object -ExpandProperty Layers"
        Test-ItoNetwork -SkipTrace | Select-Object -ExpandProperty Layers | Format-Table -AutoSize | Out-String -Width 200
        "PS> (Test-ItoNetwork -ComputerName fileserver.corp.itops.test -Port 445 -SkipTrace).Diagnosis"
        (Test-ItoNetwork -ComputerName fileserver.corp.itops.test -Port 445 -SkipTrace).Diagnosis
    '
} | sed -e '/^$/N;/^\n$/D' >"$samples/test-itonetwork-linux.txt"

echo "Samples written to $samples."
