#!/usr/bin/env bash
#
# Runs the integration tests: builds the test images, starts a throwaway Samba AD domain
# controller, runs tests/integration/*.bats in a client container against it, and removes the
# containers, network and volumes afterwards, whatever the result.
#
# Needs Docker with Compose v2. Nothing is published on host ports.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

# A new random administrator password for every run of the throwaway domain.
SAMBA_ADMIN_PASSWORD="It-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')-Aa1!"
export SAMBA_ADMIN_PASSWORD

compose=(docker compose -f tests/integration/compose.yaml)

cleanup() {
    "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" build
"${compose[@]}" up --detach --wait dc
"${compose[@]}" run --rm client
