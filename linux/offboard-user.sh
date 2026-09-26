#!/usr/bin/env bash
#
# offboard-user.sh - offboard a leaver in Samba Active Directory.
#
# The Linux counterpart of Remove-ItoUser. See --help.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/directory.sh
source "$SCRIPT_DIR/lib/directory.sh"

usage() {
    cat <<'EOF'
Usage: offboard-user.sh --user ACCOUNT --ticket TICKET --audit-dir DIR (--config FILE | --disabled-ou DN) [options]

Offboards a leaver without deleting the account:
  1. exports the account's group memberships to a CSV file in --audit-dir (nothing else
     happens if this fails);
  2. disables the account;
  3. records the ticket number and date in the description, keeping the old description;
  4. removes the account from every group except its primary group (Domain Users);
  5. moves the account to the disabled users OU.

Each step checks the current state first, so running it again changes nothing.

Options:
  --user ACCOUNT        The leaver's sAMAccountName.
  --ticket TICKET       The ticket that authorised it, e.g. INC0012345 or REQ-2041.
  --audit-dir DIR       Folder for the group membership export.
  --config FILE         JSON configuration; its disabledOu setting is the target OU.
  --disabled-ou DN      Target OU, instead of --config.
  --url URL             Domain controller, e.g. ldap://dc1.corp.example.com (default: $ITO_LDAP_URL).
  --auth-file FILE      Samba authentication file, mode 600 (default: $ITO_AUTH_FILE).
  --dry-run             Show what would change; change nothing.
  -h, --help            Show this help.

Exit status: 0 offboarded, already offboarded or planned; 1 failed; 64 usage error;
66, 69 or 77 when a file, command or permission is missing.
EOF
}

ACCOUNT=''
TICKET=''
AUDIT_DIR=''
CONFIG_FILE=''
DISABLED_OU=''
LDAP_URL=${ITO_LDAP_URL:-}
AUTH_FILE=${ITO_AUTH_FILE:-}
DRY_RUN=false
DN_PATTERN='^((OU|CN)=[^,=]+,)+(DC=[A-Za-z0-9-]+,)*DC=[A-Za-z0-9-]+$'

while (($# > 0)); do
    case $1 in
        --user) ACCOUNT=${2:?}; shift 2 ;;
        --ticket) TICKET=${2:?}; shift 2 ;;
        --audit-dir) AUDIT_DIR=${2:?}; shift 2 ;;
        --config) CONFIG_FILE=${2:?}; shift 2 ;;
        --disabled-ou) DISABLED_OU=${2:?}; shift 2 ;;
        --url) LDAP_URL=${2:?}; shift 2 ;;
        --auth-file) AUTH_FILE=${2:?}; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_error "Unknown option '$1'." ;;
    esac
done

[[ -n $ACCOUNT ]] || usage_error 'Missing --user.'
[[ $ACCOUNT =~ ^[A-Za-z0-9._-]{1,20}$ ]] || usage_error "'$ACCOUNT' is not a valid account name (1-20 letters, digits, '.', '_' or '-')."
[[ -n $TICKET ]] || usage_error 'Missing --ticket.'
[[ $TICKET =~ ^[A-Za-z]{2,10}-?[0-9]{1,12}$ ]] || usage_error "'$TICKET' is not a ticket number such as INC0012345 or REQ-2041."
TICKET=${TICKET^^}
[[ -n $AUDIT_DIR ]] || usage_error 'Missing --audit-dir.'
[[ -n $CONFIG_FILE || -n $DISABLED_OU ]] || usage_error 'Give --config or --disabled-ou.'
[[ -z $CONFIG_FILE || -z $DISABLED_OU ]] || usage_error 'Give --config or --disabled-ou, not both.'
[[ -n $LDAP_URL ]] || usage_error 'Missing --url (or set ITO_LDAP_URL).'
[[ -n $AUTH_FILE ]] || usage_error 'Missing --auth-file (or set ITO_AUTH_FILE).'
[[ $LDAP_URL =~ ^ldaps?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || usage_error "'$LDAP_URL' is not an ldap:// or ldaps:// URL."

[[ -d $AUDIT_DIR && -w $AUDIT_DIR ]] || die "The audit folder '$AUDIT_DIR' does not exist or is not writable." 73
check_secret_file "$AUTH_FILE" 'authentication file'
require_cmd ldbsearch ldbmodify samba-tool base64

if [[ -n $CONFIG_FILE ]]; then
    require_cmd jq
    [[ -r $CONFIG_FILE ]] || die "The configuration file '$CONFIG_FILE' does not exist or cannot be read." 66
    problems=$(config_check "$CONFIG_FILE" 2>&1) || die "The configuration file '$CONFIG_FILE' could not be read: $problems" 65
    [[ -z $problems ]] || die "The configuration file '$CONFIG_FILE' is not valid:"$'\n'"$problems" 65
    DISABLED_OU=$(config_get "$CONFIG_FILE" disabledOu)
fi
[[ $DISABLED_OU =~ $DN_PATTERN ]] || usage_error "'$DISABLED_OU' is not a distinguished name such as OU=Disabled Users,DC=corp,DC=example,DC=com."

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
ERR_FILE="$WORK_DIR/stderr"

last_error() {
    local line
    line=$(grep -v '^[[:space:]]*$' "$ERR_FILE" 2>/dev/null | sed -n '1p') || true
    printf '%s' "${line:0:300}"
}

fail() {
    printf 'Offboarding %s failed: %s\n' "$ACCOUNT" "$1" >&2
    exit 1
}

if ! BASE_DN=$(directory_base_dn 2>"$ERR_FILE") || [[ -z $BASE_DN ]]; then
    die "Could not read the directory at $LDAP_URL: $(last_error)" 69
fi

entry=$(ldap_search "$BASE_DN" sub "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ldap_filter_escape "$ACCOUNT")))" \
    distinguishedName userAccountControl description memberOf 2>"$ERR_FILE") || fail "Directory search failed: $(last_error)"
dn=$(ldif_values distinguishedName <<<"$entry" | sed -n '1p')
[[ -n $dn ]] || fail "No user account named '$ACCOUNT' was found."
uac=$(ldif_values userAccountControl <<<"$entry" | sed -n '1p')
description=$(ldif_values description <<<"$entry" | sed -n '1p')
mapfile -t groups < <(ldif_values memberOf <<<"$entry")

actions=()
planned=false

# plan TEXT: with --dry-run, prints "Would TEXT" and returns 1 so the caller skips the step.
plan() {
    if [[ $DRY_RUN == true ]]; then
        printf 'Would %s\n' "$1"
        planned=true
        return 1
    fi
}

# 1. Audit export first: group removal must never happen without a record of what was removed.
audit_file=''
if ((${#groups[@]} > 0)); then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    audit_file="$AUDIT_DIR/${ACCOUNT}_${TICKET}_${stamp}_groups.csv"
    if plan "export ${#groups[@]} group membership(s) to $audit_file"; then
        exported_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        {
            printf '"SamAccountName","TicketNumber","GroupDistinguishedName","ExportedAtUtc"\n'
            for group in "${groups[@]}"; do
                printf '%s,%s,%s,%s\n' "$(csv_field "$ACCOUNT")" "$(csv_field "$TICKET")" "$(csv_field "$group")" "$(csv_field "$exported_at")"
            done
        } >"$audit_file" 2>"$ERR_FILE" || fail "Could not write the audit file '$audit_file': $(last_error)"
        printf 'Exported %s group membership(s) to %s\n' "${#groups[@]}" "$audit_file"
        actions+=('Exported group memberships')
    fi
fi

# 2. Disable (userAccountControl bit 2 is ACCOUNTDISABLE).
if [[ -n $uac ]] && ((uac & 2)); then
    :
elif plan "disable the account"; then
    samba_tool user disable "$ACCOUNT" >/dev/null 2>"$ERR_FILE" || fail "Could not disable the account: $(last_error)"
    printf 'Disabled the account\n'
    actions+=('Disabled account')
fi

# 3. Ticket in the description, once however often the script runs. The ticket must appear as a
# whole token: INC1 is not recorded just because INC12345 is. TICKET is [A-Z0-9-] only.
ticket_pattern="(^|[^A-Z0-9])${TICKET}([^A-Z0-9]|$)"
if [[ ! ${description^^} =~ $ticket_pattern ]]; then
    new_description="Offboarded $(date -u +%Y-%m-%d) ticket $TICKET"
    if [[ -n ${description// /} ]]; then
        new_description+=" | previous: $description"
    fi
    # Active Directory allows 1024 characters; cut at a character boundary.
    # cut reads all its input, so it cannot break the pipe; iconv -c drops a split last character.
    new_description=$(printf '%s' "$new_description" | cut -b 1-1024 | iconv -f UTF-8 -t UTF-8 -c) || true
    if plan "set the description to '$new_description'"; then
        {
            ldif_line dn "$dn"
            printf 'changetype: modify\nreplace: description\n'
            ldif_line description "$new_description"
        } | ldap_modify >/dev/null 2>"$ERR_FILE" || fail "Could not update the description: $(last_error)"
        printf "Set the description to '%s'\n" "$new_description"
        actions+=('Recorded ticket in description')
    fi
fi

# 4. Remove group memberships.
removed=0
for group in "${groups[@]}"; do
    if plan "remove the account from $group"; then
        {
            ldif_line dn "$group"
            printf 'changetype: modify\ndelete: member\n'
            ldif_line member "$dn"
        } | ldap_modify >/dev/null 2>"$ERR_FILE" || fail "Could not remove the account from '$group': $(last_error)"
        printf 'Removed the account from %s\n' "$group"
        removed=$((removed + 1))
    fi
done
if ((removed > 0)); then
    actions+=("Removed from $removed group(s)")
fi

# 5. Move to the disabled users OU.
parent=$(dn_parent "$dn") || fail "Could not read the parent of '$dn'."
if [[ ${parent,,} != "${DISABLED_OU,,}" ]]; then
    if plan "move the account to $DISABLED_OU"; then
        samba_tool user move "$ACCOUNT" "$DISABLED_OU" >/dev/null 2>"$ERR_FILE" || fail "Could not move the account: $(last_error)"
        printf 'Moved the account to %s\n' "$DISABLED_OU"
        actions+=('Moved to disabled users OU')
    fi
fi

if [[ $planned == true ]]; then
    printf 'Planned: no changes were made (--dry-run).\n'
elif ((${#actions[@]} == 0)); then
    printf 'Already offboarded: %s needed no changes.\n' "$ACCOUNT"
else
    printf 'Offboarded %s under %s: %s.\n' "$ACCOUNT" "$TICKET" "$(join_by ', ' "${actions[@]}")"
fi
