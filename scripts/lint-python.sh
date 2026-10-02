#!/usr/bin/env bash
#
# Lints and type-checks linux/lib/hrfeed.py in a python:3.13-slim container, as CI does:
# ruff (lint and format check) and mypy --strict, with the hash-pinned tools from
# requirements-dev.txt.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    root=$(pwd -W)
else
    root=$(pwd)
fi

docker run --rm --memory 768m -v "$root:/work:ro" -w /work python:3.13-slim bash -c '
    set -euo pipefail
    pip install --quiet --root-user-action=ignore --require-hashes -r requirements-dev.txt
    ruff check --no-cache
    ruff format --check --no-cache
    mypy --cache-dir=/tmp/mypy-cache
'
