#!/usr/bin/env bash
#
# Lints and tests the Bash toolkit in containers, exactly as CI does:
#   1. shellcheck over every script, library, test and fake;
#   2. the bats unit tests in the Debian test image (tests/docker/Dockerfile, target "test").
# The Samba AD integration tests are separate: tests/integration/run.sh.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# Git Bash on Windows rewrites /paths in arguments and needs a Windows path for bind mounts.
if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    root=$(pwd -W)
else
    root=$(pwd)
fi

shell_files=(linux/*.sh linux/lib/*.sh scripts/*.sh tests/integration/*.sh tests/integration/*.bats
    tests/bats/*.bats tests/bats/helpers/*.bash tests/bats/helpers/fakes/*)

echo '==> shellcheck'
docker run --rm --memory 256m -v "$root:/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0 --severity=style "${shell_files[@]}"

echo '==> bats unit tests'
docker build --quiet -f tests/docker/Dockerfile --target test -t it-ops-toolkit-test:test . >/dev/null
# The tests read the scripts, fakes and fixtures hundreds of times. They run on a copy inside the
# container, because Docker Desktop bind mounts can fail a read now and then under load.
docker run --rm --memory 512m -v "$root:/src:ro" --entrypoint bash it-ops-toolkit-test:test -c '
    set -euo pipefail
    tar -C /src --exclude=./.git --exclude=./out -cf - . | tar -C /work -xf -
    cd /work
    exec bats --print-output-on-failure tests/bats
'
