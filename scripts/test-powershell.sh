#!/usr/bin/env bash
#
# Runs PSScriptAnalyzer and the Pester suite in a container, exactly as CI does. The image is the
# "powershell" target of tests/docker/Dockerfile: Ubuntu 24.04 with PowerShell 7.6 LTS, pinned by
# version and SHA-256. Extra arguments go to scripts/Invoke-Tests.ps1 (for example -Stage Test).
# -Install downloads the pinned Pester and PSScriptAnalyzer into ./out/modules (hash-checked).
# Results and coverage go to ./out. Set ITO_TEST_IMAGE to change the image name.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

image=${ITO_TEST_IMAGE:-it-ops-toolkit-test}:powershell

if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    root=$(pwd -W)
else
    root=$(pwd)
fi

echo "==> Building $image (tests/docker/Dockerfile, target powershell)"
docker build --quiet -f tests/docker/Dockerfile --target powershell -t "$image" . >/dev/null

docker run --rm --memory 1536m -v "$root:/work" -w /work "$image" \
    -File scripts/Invoke-Tests.ps1 -Install -MinimumCoverage 80 "$@"
