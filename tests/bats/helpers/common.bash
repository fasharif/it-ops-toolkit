# shellcheck shell=bash
#
# Shared helpers for the bats unit tests. Load with:  load 'helpers/common'
#
# Every test gets its own directory of fake commands at the front of PATH. The fake Samba
# tools in helpers/fakes answer from fixtures that a test registers, and record their
# arguments and standard input in $FAKE_LDB so the test can check exactly what was sent.

REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
export REPO_ROOT

common_setup() {
    bats_load_library bats-support
    bats_load_library bats-assert

    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    export FAKE_LDB="$BATS_TEST_TMPDIR/ldb"
    export FAKE_BASE_DN='DC=corp,DC=itops,DC=test'
    mkdir -p "$FAKE_BIN" "$FAKE_LDB/responses"
    : >"$FAKE_LDB/calls.log"
    cp "$REPO_ROOT"/tests/bats/helpers/fakes/* "$FAKE_BIN/"
    chmod +x "$FAKE_BIN"/*
    export PATH="$FAKE_BIN:$PATH"
}

# fake NAME BODY: creates a fake command for this test only.
fake() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" >"$FAKE_BIN/$1"
    chmod +x "$FAKE_BIN/$1"
}

# isolate_path [COMMAND...]: limits PATH to the fakes plus basic tools and the named commands,
# so a test can check what a script does when a tool is not installed.
isolate_path() {
    local dir="$BATS_TEST_TMPDIR/realbin" cmd target
    mkdir -p "$dir"
    for cmd in bash env awk sed grep sort cat date mktemp rm mkdir tr cut wc head tail stat base64 \
        iconv jq python3 openssl od uniq ls chmod dirname basename id tee sha1sum hostname "$@"; do
        target=$(command -v "$cmd" 2>/dev/null) || continue
        ln -sf "$target" "$dir/$cmd"
    done
    export PATH="$FAKE_BIN:$dir"
}

# ldb_key SCOPE FILTER: the fixture name the fake ldbsearch looks up.
ldb_key() {
    printf '%s|%s' "$1" "$2" | sha1sum | cut -c 1-16
}

# ldb_respond SCOPE FILTER: registers the LDIF on stdin as the answer to that search.
ldb_respond() {
    cat >"$FAKE_LDB/responses/$(ldb_key "$1" "$2").ldif"
}

# ldb_object DN: makes a base-scope search of DN succeed (for example an OU that exists).
ldb_object() {
    printf '%s\n' "${1,,}" >>"$FAKE_LDB/objects"
}

# ldb_groups_exist NAME...: registers groups as existing, with DNs under CN=Users.
ldb_groups_exist() {
    local name
    for name in "$@"; do
        printf 'dn: CN=%s,CN=Users,%s\n' "$name" "$FAKE_BASE_DN" | ldb_respond sub "(&(objectClass=group)(sAMAccountName=$name))"
    done
}

# calls_to COMMAND: the recorded argument lists for one fake command.
calls_to() {
    grep "^$1 " "$FAKE_LDB/calls.log" || true
}

# new_certificate DIR: creates DIR/delivery.pem and DIR/delivery.key.
new_certificate() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Test Delivery' \
        -keyout "$1/delivery.key" -out "$1/delivery.pem" 2>/dev/null
}

# decrypt_delivery FILE DIR: the plain text of a delivery file, using DIR's key.
decrypt_delivery() {
    openssl cms -decrypt -binary -inform PEM -in "$1" -inkey "$2/delivery.key" -recip "$2/delivery.pem"
}
