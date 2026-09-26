# shellcheck shell=bash
#
# Directory helpers shared by onboard-user.sh and offboard-user.sh. Source after common.sh.
#
# Callers set LDAP_URL (for example ldap://dc1.corp.example.com) and AUTH_FILE (a Samba
# authentication file). Credentials are always read from AUTH_FILE, never passed on the
# command line, so they do not appear in the process list.

ITO_LIB_DIR=${ITO_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
ITO_US=$'\x1f'
# ldbsearch exits with the LDAP result code when a search fails; 32 (noSuchObject) means the base
# DN does not exist. A connection or bind failure exits with 1.
# shellcheck disable=SC2034 # used by the scripts that source this file
LDAP_NO_SUCH_OBJECT=32

# ldap_search BASE SCOPE FILTER [ATTRIBUTE...]: prints matching entries as LDIF. Errors go to
# standard error, except "search error - LDAP error NN ...", which ldbsearch prints on standard
# output.
ldap_search() {
    ldbsearch -H "$LDAP_URL" -A "$AUTH_FILE" -b "$1" -s "$2" "$3" "${@:4}"
}

# ldap_modify: applies LDIF from stdin.
ldap_modify() {
    ldbmodify -H "$LDAP_URL" -A "$AUTH_FILE"
}

# ldap_add: adds entries from LDIF on stdin.
ldap_add() {
    ldbadd -H "$LDAP_URL" -A "$AUTH_FILE"
}

# samba_tool SUBCOMMAND...: runs samba-tool against the same server and credentials.
samba_tool() {
    samba-tool "$@" -H "$LDAP_URL" -A "$AUTH_FILE"
}

# ldif_values ATTRIBUTE: reads LDIF on stdin and prints each value of ATTRIBUTE on its own line.
# Handles folded lines (a continuation line starts with one space) and base64 values (attr:: ...).
# Attribute names are matched without regard to case, as LDAP does.
ldif_values() {
    local wanted=${1,,} line lowered value
    awk 'NR > 1 && /^ / { buffer = buffer substr($0, 2); next }
         { if (NR > 1) print buffer; buffer = $0 }
         END { if (NR > 0) print buffer }' |
        while IFS= read -r line; do
            lowered=${line,,}
            if [[ $lowered == "$wanted:: "* ]]; then
                value=$(printf '%s' "${line:${#wanted}+3}" | base64 -d 2>/dev/null) || continue
                printf '%s\n' "${value//$'\n'/ }"
            elif [[ $lowered == "$wanted: "* ]]; then
                printf '%s\n' "${line:${#wanted}+2}"
            fi
        done
}

# ldif_has_entry: reads LDIF on stdin and is true when it holds at least one entry. It reads all
# of its input, so an early exit cannot turn a match into a pipe error under pipefail.
ldif_has_entry() {
    local dns
    dns=$(ldif_values dn)
    [[ -n $dns ]]
}

# ldif_line NAME VALUE: prints one LDIF attribute line, base64-encoding values that are not
# plain printable ASCII (RFC 2849 SAFE-STRING) such as names with accents.
ldif_line() {
    local name=$1 value=$2 rest
    # Delete every printable ASCII byte; anything left means the value needs base64.
    rest=$(printf '%s' "$value" | LC_ALL=C tr -d ' -~')
    if [[ -z $rest && $value != [\ :\<]* && $value != *' ' ]]; then
        printf '%s: %s\n' "$name" "$value"
    else
        printf '%s:: %s\n' "$name" "$(printf '%s' "$value" | base64 -w0)"
    fi
}

# ldap_filter_escape VALUE: escapes a value for an LDAP search filter (RFC 4515).
ldap_filter_escape() {
    local s=$1 backslash=$'\x5c'
    # Quoted replacements are literal, whatever the shell's patsub_replacement setting.
    s=${s//"$backslash"/"${backslash}5c"}
    s=${s//'*'/"${backslash}2a"}
    s=${s//'('/"${backslash}28"}
    s=${s//')'/"${backslash}29"}
    printf '%s' "$s"
}

# dn_parent DN: prints the parent of DN, respecting escaped commas (CN=Smith\, John,OU=...).
dn_parent() {
    local pattern='^((\\.|[^,\\])+),(.+)$'
    [[ $1 =~ $pattern ]] || return 1
    printf '%s' "${BASH_REMATCH[3]}"
}

# dn_rdn DN: prints the first RDN of DN.
dn_rdn() {
    local pattern='^((\\.|[^,\\])+),(.+)$'
    [[ $1 =~ $pattern ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# sam_candidate GIVEN SURNAME FORMAT ATTEMPT: the account name rules shared with the PowerShell
# module. GIVEN and SURNAME are already lower-case ASCII. The result is at most 20 characters,
# never ends with a full stop, and has the attempt number appended from attempt 2 onwards.
sam_candidate() {
    local given=$1 surname=$2 format=$3 attempt=$4 base suffix=''
    if [[ $format == flast ]]; then
        base="${given:0:1}${surname}"
    else
        base="${given}.${surname}"
    fi
    if ((attempt > 1)); then
        suffix=$attempt
    fi
    base=${base:0:20-${#suffix}}
    while [[ $base == *. ]]; do
        base=${base%.}
    done
    printf '%s%s' "$base" "$suffix"
}

# directory_base_dn: prints the domain's base DN, read from the rootDSE.
directory_base_dn() {
    ldap_search '' base '(objectClass=*)' defaultNamingContext | ldif_values defaultNamingContext
}

# config_check FILE: prints one line per problem in the JSON configuration (nothing when valid).
config_check() {
    jq -r -f "$ITO_LIB_DIR/config-check.jq" "$1"
}

# config_get FILE KEY: prints a top-level string setting.
config_get() {
    jq -r --arg key "$2" '.[$key] // empty' "$1"
}

# config_department FILE NAME: prints "<name as configured><US><ou>" for a department (US is the
# ASCII unit separator), matched without regard to (ASCII) case, or nothing when there is none.
config_department() {
    jq -r --arg name "$2" --arg sep "$ITO_US" '
        first(.departments | to_entries[]
              | select((.key | ascii_downcase) == ($name | ascii_downcase))
              | .key + $sep + .value.ou) // empty' "$1"
}

# config_groups FILE DEPARTMENT: prints the default groups then the department's groups, once each.
config_groups() {
    jq -r --arg name "$2" '
        [(.defaultGroups // [])[],
         (.departments | to_entries[] | select((.key | ascii_downcase) == ($name | ascii_downcase)) | (.value.groups // [])[])]
        | reduce .[] as $g ([]; if index([$g]) then . else . + [$g] end) | .[]' "$1"
}
