#!/usr/bin/env bash
#
# Runs PSScriptAnalyzer and the Pester suite in the mcr.microsoft.com/powershell container,
# exactly as CI does. Extra arguments go to scripts/Invoke-Tests.ps1 (for example -Stage Test).
# Results and coverage go to ./out.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

image=mcr.microsoft.com/powershell:7.5-ubuntu-24.04

if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    root=$(pwd -W)
else
    root=$(pwd)
fi

docker run --rm --memory 1536m -v "$root:/work" -w /work "$image" \
    pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -MinimumCoverage 80 "$@"
