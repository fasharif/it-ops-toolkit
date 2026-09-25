# shellcheck shell=bash
#
# Shared helpers for the it-ops-toolkit Bash scripts. Source this file; do not run it.

ITO_PROG=${ITO_PROG:-${0##*/}}

# Messages go to stderr, so stdout stays clean for reports and summaries.
log() {
    printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ITO_PROG" "$*" >&2
}

warn() {
    log "WARNING: $*"
}

# die MESSAGE [EXIT_CODE]
die() {
    log "ERROR: $1"
    exit "${2:-1}"
}

# usage_error MESSAGE: exit 64 (EX_USAGE from sysexits.h) with a hint.
usage_error() {
    printf '%s: %s\nRun %s --help for usage.\n' "$ITO_PROG" "$1" "$ITO_PROG" >&2
    exit 64
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' was not found. Install it and try again." 69
    done
}

# join_by SEPARATOR ITEM...: prints the items joined by SEPARATOR.
join_by() {
    local separator=$1 result='' item
    shift
    for item in "$@"; do
        result+="${result:+$separator}$item"
    done
    printf '%s' "$result"
}

# is_integer VALUE: true for a non-negative whole number.
is_integer() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# json_escape STRING: prints STRING escaped for use inside a JSON string literal.
json_escape() {
    local input=$1 output='' char code i
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        case $char in
            '"') output+='\"' ;;
            $'\x5c') output+=$'\x5c\x5c' ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            *)
                printf -v code '%d' "'$char"
                if ((code >= 0 && code < 32)); then
                    printf -v char '\\u%04x' "$code"
                fi
                output+=$char
                ;;
        esac
    done
    printf '%s' "$output"
}

# html_escape STRING: prints STRING safe for HTML text and attribute values.
# The replacements are quoted because bash 5.2 expands an unquoted & to the matched text.
html_escape() {
    local s=$1
    s=${s//'&'/'&amp;'}
    s=${s//'<'/'&lt;'}
    s=${s//'>'/'&gt;'}
    s=${s//'"'/'&quot;'}
    s=${s//"'"/'&#39;'}
    printf '%s' "$s"
}

# csv_field STRING: prints STRING as a quoted CSV field (RFC 4180).
csv_field() {
    local s=$1
    printf '"%s"' "${s//'"'/'""'}"
}

# check_secret_file PATH DESCRIPTION: refuse files that other users can read, as ssh does for keys.
check_secret_file() {
    local path=$1 what=$2 mode
    [[ -r $path ]] || die "The $what '$path' does not exist or cannot be read." 66
    mode=$(stat -c '%a' -- "$path")
    if ((8#$mode & 8#077)); then
        die "The $what '$path' can be read by other users (mode $mode). Run: chmod 600 '$path'" 77
    fi
}
