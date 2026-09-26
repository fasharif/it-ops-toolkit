#!/usr/bin/env bash
#
# onboard-user.sh - create Samba Active Directory accounts for new starters from an HR feed.
#
# The Linux counterpart of New-ItoUser: same CSV columns, same JSON configuration, same
# account name rules. See --help.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/directory.sh
source "$SCRIPT_DIR/lib/directory.sh"

usage() {
    cat <<'EOF'
Usage: onboard-user.sh --csv FILE --config FILE [options]

Creates a Samba Active Directory account for each valid row of an HR feed:
  - skips rows whose employee ID already has an account, so the feed can be run again, and
    warns when that account is not in all the configured groups (it does not add them);
  - checks that the department's OU and groups exist before creating anything;
  - generates a unique account name (first.last or flast, at most 20 characters);
  - creates the account enabled, in the department's OU, with a random initial password
    that must be changed at first sign-in;
  - adds it to the default and department groups;
  - writes the initial password only to a file encrypted to the service desk certificate.

The password is never printed, logged or passed on a command line.

Options:
  --csv FILE            HR feed: UTF-8 CSV with EmployeeId, GivenName, Surname, Department
                        and optional Title, Manager (sAMAccountName), StartDate (yyyy-MM-dd),
                        GivenNameLatin and SurnameLatin (a Latin-script spelling of a name in
                        another script, such as Arabic, used for the account name only).
  --config FILE         JSON configuration, see config/onboarding.example.json.
  --url URL             Domain controller, e.g. ldap://dc1.corp.example.com
                        (default: $ITO_LDAP_URL).
  --auth-file FILE      Samba authentication file (username=, password=, domain= lines),
                        mode 600 (default: $ITO_AUTH_FILE).
  --deliver-dir DIR     Folder for the encrypted password files, <account>.cms.
  --deliver-cert FILE   PEM certificate the password files are encrypted to. Decrypt with:
                        openssl cms -decrypt -binary -inform PEM -in FILE.cms -inkey KEY -recip CERT
  --summary FILE        Also write the summary as CSV (it never contains passwords).
  --password-length N   Initial password length, 14-128 (default 20).
  --dry-run             Show what would be created; change nothing. No delivery options needed.
  -h, --help            Show this help.

Exit status: 0 when every row was created or already existed (or planned, with --dry-run);
1 when any row was invalid or failed; 64 for a usage error; 66, 69 or 77 when a file,
command or permission is missing.
EOF
}

CSV_FILE=''
CONFIG_FILE=''
LDAP_URL=${ITO_LDAP_URL:-}
AUTH_FILE=${ITO_AUTH_FILE:-}
DELIVER_DIR=''
DELIVER_CERT=''
SUMMARY_FILE=''
PASSWORD_LENGTH=20
DRY_RUN=false

while (($# > 0)); do
    case $1 in
        --csv) CSV_FILE=${2:?}; shift 2 ;;
        --config) CONFIG_FILE=${2:?}; shift 2 ;;
        --url) LDAP_URL=${2:?}; shift 2 ;;
        --auth-file) AUTH_FILE=${2:?}; shift 2 ;;
        --deliver-dir) DELIVER_DIR=${2:?}; shift 2 ;;
        --deliver-cert) DELIVER_CERT=${2:?}; shift 2 ;;
        --summary) SUMMARY_FILE=${2:?}; shift 2 ;;
        --password-length) PASSWORD_LENGTH=${2:?}; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage_error "Unknown option '$1'." ;;
    esac
done

[[ -n $CSV_FILE ]] || usage_error 'Missing --csv.'
[[ -n $CONFIG_FILE ]] || usage_error 'Missing --config.'
[[ -n $LDAP_URL ]] || usage_error 'Missing --url (or set ITO_LDAP_URL).'
[[ -n $AUTH_FILE ]] || usage_error 'Missing --auth-file (or set ITO_AUTH_FILE).'
[[ $LDAP_URL =~ ^ldaps?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || usage_error "'$LDAP_URL' is not an ldap:// or ldaps:// URL."
if ! is_integer "$PASSWORD_LENGTH" || ((PASSWORD_LENGTH < 14 || PASSWORD_LENGTH > 128)); then
    usage_error '--password-length must be a whole number from 14 to 128.'
fi
if [[ $DRY_RUN == false ]]; then
    [[ -n $DELIVER_DIR && -n $DELIVER_CERT ]] ||
        usage_error 'Real runs need --deliver-dir and --deliver-cert: the initial passwords are only ever written encrypted.'
fi

[[ -r $CSV_FILE ]] || die "The HR feed '$CSV_FILE' does not exist or cannot be read." 66
[[ -r $CONFIG_FILE ]] || die "The configuration file '$CONFIG_FILE' does not exist or cannot be read." 66
check_secret_file "$AUTH_FILE" 'authentication file'
require_cmd jq python3 ldbsearch ldbadd samba-tool base64 iconv

if ! config_problems=$(config_check "$CONFIG_FILE" 2>&1); then
    die "The configuration file '$CONFIG_FILE' could not be read: $config_problems" 65
fi
if [[ -n $config_problems ]]; then
    die "The configuration file '$CONFIG_FILE' is not valid:"$'\n'"$config_problems" 65
fi
UPN_SUFFIX=$(config_get "$CONFIG_FILE" upnSuffix)
UPN_SUFFIX=${UPN_SUFFIX,,}
NAME_FORMAT=$(config_get "$CONFIG_FILE" samAccountNameFormat)
NAME_FORMAT=${NAME_FORMAT:-first.last}

if [[ $DRY_RUN == false ]]; then
    require_cmd openssl
    [[ -d $DELIVER_DIR && -w $DELIVER_DIR ]] || die "The delivery folder '$DELIVER_DIR' does not exist or is not writable." 73
    [[ -r $DELIVER_CERT ]] || die "The delivery certificate '$DELIVER_CERT' does not exist or cannot be read." 66
    if ! printf 'check' | openssl cms -encrypt -binary -aes256 -outform PEM -out /dev/null "$DELIVER_CERT" 2>/dev/null; then
        die "The delivery certificate '$DELIVER_CERT' cannot be used for encryption. It must be a PEM certificate with an RSA key." 65
    fi
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
ERR_FILE="$WORK_DIR/stderr"
FEED_FILE="$WORK_DIR/feed"
umask 077

# First line of the last tool error, without anything that could contain a password.
last_error() {
    local line
    line=$(grep -v -i 'unicodePwd' "$ERR_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | sed -n '1p') || true
    printf '%s' "${line:0:300}"
}

# -I (isolated mode): ignore PYTHON* variables and user site-packages, and do not put the
# script's folder first on the import path, so no file next to hrfeed.py can shadow a
# standard library module.
if ! python3 -I "$ITO_LIB_DIR/hrfeed.py" "$CSV_FILE" >"$FEED_FILE" 2>"$ERR_FILE"; then
    # hrfeed.py never handles passwords, so all of its error output is safe to show. Expected
    # problems are one line; anything else is a Python traceback that needs every line.
    die "$(<"$ERR_FILE")" 65
fi
if [[ ! -s $FEED_FILE ]]; then
    warn "The HR feed '$CSV_FILE' has no data rows."
    exit 0
fi

if ! BASE_DN=$(directory_base_dn 2>"$ERR_FILE") || [[ -z $BASE_DN ]]; then
    die "Could not read the directory at $LDAP_URL: $(last_error)" 69
fi

# generate_password LENGTH [EXCLUDED...]: a random password with upper case, lower case, digits
# and symbols, no look-alike characters, and none of the excluded strings (case-insensitive).
generate_password() {
    local length=$1 attempt candidate token clash
    shift
    local alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#$%&*+=?@^_-'
    for ((attempt = 1; attempt <= 100; attempt++)); do
        candidate=$(LC_ALL=C tr -dc "$alphabet" </dev/urandom 2>/dev/null | head -c "$length") || true
        [[ ${#candidate} -eq $length ]] || continue
        [[ $candidate == *[ABCDEFGHJKLMNPQRSTUVWXYZ]* && $candidate == *[abcdefghijkmnopqrstuvwxyz]* ]] || continue
        [[ $candidate == *[23456789]* && $candidate == *[#\$%\&*+=?@^_!-]* ]] || continue
        clash=false
        for token in "$@"; do
            if ((${#token} >= 3)) && [[ ${candidate,,} == *"${token,,}"* ]]; then
                clash=true
                break
            fi
        done
        if [[ $clash == false ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# unicode_pwd PASSWORD: the base64 value Active Directory expects in unicodePwd
# (the password in double quotes, encoded as UTF-16LE).
unicode_pwd() {
    printf '"%s"' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

# directory_search BASE SCOPE FILTER [ATTRIBUTE...]: runs ldap_search and sets SEARCH_OUTPUT and
# SEARCH_STATUS (ldbsearch's exit status: 0, the LDAP result code such as 32, or 1 for a
# connection or bind failure) instead of failing. ldbsearch prints some errors ("search error -
# LDAP error 32 ...") on standard output, so after a failure that output is added to ERR_FILE,
# where last_error finds it. It sets variables rather than printing, so callers that must keep
# their caches can run it in this shell.
SEARCH_OUTPUT=''
SEARCH_STATUS=0
directory_search() {
    SEARCH_STATUS=0
    SEARCH_OUTPUT=$(ldap_search "$@" 2>"$ERR_FILE") || SEARCH_STATUS=$?
    if ((SEARCH_STATUS != 0)); then
        printf '%s\n' "$SEARCH_OUTPUT" >>"$ERR_FILE"
    fi
}

# The lookups below return 0 or 1 for a directory answer and 2 when the search itself failed
# (network, bind or permission errors, with the reason in ERR_FILE). Only answers are cached: a
# passing network error must not turn every later row for the same department into "not found".

# ou_exists DN: 0 when the OU exists, 1 when it does not, 2 when the search failed.
declare -A OU_CACHE=()
ou_exists() {
    local key=${1,,}
    if [[ -z ${OU_CACHE[$key]+set} ]]; then
        directory_search "$1" base '(objectClass=organizationalUnit)' dn
        if ((SEARCH_STATUS == 0)) && ldif_has_entry <<<"$SEARCH_OUTPUT"; then
            OU_CACHE[$key]=yes
        elif ((SEARCH_STATUS == 0 || SEARCH_STATUS == LDAP_NO_SUCH_OBJECT)); then
            OU_CACHE[$key]=no
        else
            return 2
        fi
    fi
    [[ ${OU_CACHE[$key]} == yes ]]
}

# lookup_group NAME: sets GROUP_DN to the DN of the group with that sAMAccountName, or to ''
# when there is none, and returns 0; returns 2 when the search failed. Results are cached. It
# sets a variable rather than printing, because a $(...) subshell would lose the cache.
declare -A GROUP_CACHE=()
GROUP_DN=''
lookup_group() {
    local key=${1,,}
    GROUP_DN=''
    if [[ -z ${GROUP_CACHE[$key]+set} ]]; then
        directory_search "$BASE_DN" sub "(&(objectClass=group)(sAMAccountName=$(ldap_filter_escape "$1")))" dn
        ((SEARCH_STATUS == 0)) || return 2
        GROUP_CACHE[$key]=$(ldif_values dn <<<"$SEARCH_OUTPUT" | sed -n '1p')
    fi
    GROUP_DN=${GROUP_CACHE[$key]}
}

# group_exists NAME: 0 when a group with that sAMAccountName exists, 1 when it does not, 2 when
# the search failed.
group_exists() {
    lookup_group "$1" || return 2
    [[ -n $GROUP_DN ]]
}

# missing_groups_warning MEMBER_OF_DN...: sets MISSING_GROUPS to a warning about each configured
# group (in $groups) that an existing account is not a member of, or to ''. Like lookup_group,
# it must run in this shell, not in $(...), so the group cache is kept.
MISSING_GROUPS=''
missing_groups_warning() {
    local group member found text=''
    for group in "${groups[@]}"; do
        if ! lookup_group "$group"; then
            text+="${text:+ }Could not check the configured group '$group': $(last_error)"
            continue
        fi
        [[ -n $GROUP_DN ]] || continue
        found=false
        for member in "$@"; do
            if [[ ${member,,} == "${GROUP_DN,,}" ]]; then
                found=true
                break
            fi
        done
        if [[ $found == false ]]; then
            text+="${text:+ }The existing account is not in the configured group '$group'. Check that the person still needs it, then add it by hand."
        fi
    done
    MISSING_GROUPS=$text
}

# name_taken NAME: 0 when any object already uses NAME as sAMAccountName or UPN prefix, 1 when
# the name is free, 2 when the search failed.
name_taken() {
    local escaped
    escaped=$(ldap_filter_escape "$1")
    directory_search "$BASE_DN" sub "(|(sAMAccountName=$escaped)(userPrincipalName=$escaped@$(ldap_filter_escape "$UPN_SUFFIX")))" dn
    ((SEARCH_STATUS == 0)) || return 2
    ldif_has_entry <<<"$SEARCH_OUTPUT"
}

declare -A RESERVED=()
RESOLVED_NAME=''
# resolve_account_name GIVEN_ASCII SURNAME_ASCII: sets RESOLVED_NAME to the first free account
# name and reserves it for the rest of the batch. Returns 1 when all 99 are taken and 2 when a
# search failed. It sets a variable rather than printing, because a $(...) subshell would lose
# the reservation.
resolve_account_name() {
    local attempt candidate taken
    RESOLVED_NAME=''
    for ((attempt = 1; attempt <= 99; attempt++)); do
        candidate=$(sam_candidate "$1" "$2" "$NAME_FORMAT" "$attempt")
        [[ -z ${RESERVED[$candidate]+set} ]] || continue
        taken=0
        name_taken "$candidate" || taken=$?
        if ((taken == 2)); then
            return 2
        elif ((taken == 1)); then
            RESERVED[$candidate]=1
            RESOLVED_NAME=$candidate
            return 0
        fi
    done
    return 1
}

# deliver_password ACCOUNT UPN PASSWORD: writes <account>.cms, readable only with the
# delivery certificate's private key. Prints the file path.
deliver_password() {
    local file="$DELIVER_DIR/$1.cms"
    printf 'Account: %s\nSign-in name: %s\nInitial password: %s\nThe user must choose a new password at first sign-in.\n' "$1" "$2" "$3" |
        openssl cms -encrypt -binary -aes256 -outform PEM -out "$file" "$DELIVER_CERT" 2>"$ERR_FILE" || return 1
    printf '%s' "$file"
}

SUMMARY_HEADER='"Row","EmployeeId","DisplayName","SamAccountName","UserPrincipalName","Department","OrganizationalUnit","Groups","Status","Message","Warnings","DeliveryFile"'
SUMMARY_LINES=()
declare -A COUNTS=()
TODAY=$(date -u +%Y-%m-%d)

# report ROW EMPLOYEE_ID DISPLAY SAM UPN DEPARTMENT OU GROUPS STATUS MESSAGE WARNINGS DELIVERY
report() {
    local line='' field
    printf '%-4s %-21s %-8s %s\n' "$1" "${4:--}" "$9" "${10}"
    if [[ -n ${11} ]]; then
        printf '%-4s %-21s %-8s %s\n' '' '' '' "Warning: ${11}"
    fi
    for field in "$@"; do
        line+="${line:+,}$(csv_field "$field")"
    done
    SUMMARY_LINES+=("$line")
    COUNTS[$9]=$((${COUNTS[$9]:-0} + 1))
}

printf '%-4s %-21s %-8s %s\n' 'Row' 'Account' 'Status' 'Message'

while IFS="$ITO_US" read -r -u 3 row employee_id given surname department title manager start_date given_ascii surname_ascii problems; do
    display="$given $surname"
    display=${display# }
    display=${display% }

    if [[ -n $problems ]]; then
        report "$row" "$employee_id" "$display" '' '' "$department" '' '' Invalid "$problems" '' ''
        continue
    fi

    department_entry=$(config_department "$CONFIG_FILE" "$department")
    if [[ -z $department_entry ]]; then
        known=$(jq -r '.departments | keys | join(", ")' "$CONFIG_FILE")
        report "$row" "$employee_id" "$display" '' '' "$department" '' '' Invalid \
            "Department '$department' is not in the configuration. Known departments: $known." '' ''
        continue
    fi
    department=${department_entry%%"$ITO_US"*}
    ou=${department_entry#*"$ITO_US"}
    mapfile -t groups < <(config_groups "$CONFIG_FILE" "$department")
    group_list=$(IFS=';'; printf '%s' "${groups[*]}")

    directory_search "$BASE_DN" sub "(&(objectClass=user)(employeeID=$(ldap_filter_escape "$employee_id")))" sAMAccountName memberOf
    if ((SEARCH_STATUS != 0)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed "Directory search failed: $(last_error)" '' ''
        continue
    fi
    existing_entry=$SEARCH_OUTPUT
    existing=$(ldif_values sAMAccountName <<<"$existing_entry" | sed -n '1p')
    if [[ -n $existing ]]; then
        # Report, but do not add, configured groups the account lacks: an earlier group add may
        # have failed, or the person may have moved department since.
        mapfile -t member_of < <(ldif_values memberOf <<<"$existing_entry")
        missing_groups_warning "${member_of[@]}"
        report "$row" "$employee_id" "$display" "$existing" "$existing@$UPN_SUFFIX" "$department" "$ou" "$group_list" Exists \
            "An account with employee ID $employee_id already exists ($existing). No changes were made." "$MISSING_GROUPS" ''
        continue
    fi

    lookup_status=0
    ou_exists "$ou" || lookup_status=$?
    if ((lookup_status == 2)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "Directory search failed while checking the OU '$ou': $(last_error)" '' ''
        continue
    elif ((lookup_status != 0)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "The OU '$ou' from the configuration could not be found." '' ''
        continue
    fi
    missing_group=''
    for group in "${groups[@]}"; do
        group_exists "$group" || lookup_status=$?
        if ((lookup_status != 0)); then
            missing_group=$group
            break
        fi
    done
    if ((lookup_status == 2)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "Directory search failed while checking the group '$missing_group': $(last_error)" '' ''
        continue
    elif [[ -n $missing_group ]]; then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "The group '$missing_group' from the configuration does not exist in the directory." '' ''
        continue
    fi

    resolve_account_name "$given_ascii" "$surname_ascii" || lookup_status=$?
    if ((lookup_status == 2)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "Directory search failed while choosing an account name: $(last_error)" '' ''
        continue
    elif ((lookup_status != 0)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "No free account name was found for '$display' after 99 attempts." '' ''
        continue
    fi
    sam=$RESOLVED_NAME
    upn="$sam@$UPN_SUFFIX"

    # The CN must be unique in the OU, across every object class. When the name is taken, add
    # the account name, or use the account name alone if that would pass the 64-character limit.
    cn=$display
    directory_search "$ou" one "(cn=$(ldap_filter_escape "$display"))" dn
    if ((SEARCH_STATUS != 0)); then
        report "$row" "$employee_id" "$display" '' '' "$department" "$ou" "$group_list" Failed \
            "Directory search failed while checking the name '$display' in '$ou': $(last_error)" '' ''
        continue
    fi
    if ldif_has_entry <<<"$SEARCH_OUTPUT"; then
        cn="$display ($sam)"
        if ((${#cn} > 64)); then
            cn=$sam
        fi
    fi

    warnings=''
    manager_dn=''
    if [[ -n $manager ]]; then
        directory_search "$BASE_DN" sub "(&(objectClass=user)(sAMAccountName=$(ldap_filter_escape "$manager")))" distinguishedName
        if ((SEARCH_STATUS != 0)); then
            warnings="Manager '$manager' could not be looked up, so no manager was set: $(last_error)"
        else
            manager_dn=$(ldif_values distinguishedName <<<"$SEARCH_OUTPUT" | sed -n '1p')
            if [[ -z $manager_dn ]]; then
                warnings="Manager '$manager' was not found, so no manager was set."
            fi
        fi
    fi

    description="Onboarded $TODAY by it-ops-toolkit"
    if [[ -n $start_date ]]; then
        description="Start date $start_date. $description"
    fi

    if [[ $DRY_RUN == true ]]; then
        report "$row" "$employee_id" "$display" "$sam" "$upn" "$department" "$ou" "$group_list" Planned \
            "Would create $upn in $ou and add it to ${#groups[@]} group(s)." "$warnings" ''
        continue
    fi

    name_parts=()
    read -r -a name_parts <<<"${display//[-,._#]/ }"
    if ! password=$(generate_password "$PASSWORD_LENGTH" "$sam" "$given_ascii" "$surname_ascii" "${name_parts[@]}"); then
        report "$row" "$employee_id" "$display" "$sam" "$upn" "$department" "$ou" "$group_list" Failed \
            'Could not generate a password without the account or display name.' "$warnings" ''
        continue
    fi

    # One ldbadd call creates the account with its password and "must change" flag together,
    # so a failure never leaves a half-created account. The LDIF goes through a pipe, never argv.
    if ! {
        ldif_line dn "CN=$cn,$ou"
        printf 'objectClass: user\n'
        ldif_line sAMAccountName "$sam"
        ldif_line userPrincipalName "$upn"
        ldif_line givenName "$given"
        ldif_line sn "$surname"
        ldif_line displayName "$display"
        ldif_line mail "$upn"
        ldif_line employeeID "$employee_id"
        ldif_line department "$department"
        ldif_line description "$description"
        if [[ -n $title ]]; then ldif_line title "$title"; fi
        if [[ -n $manager_dn ]]; then ldif_line manager "$manager_dn"; fi
        printf 'userAccountControl: 512\n'
        printf 'unicodePwd:: %s\n' "$(unicode_pwd "$password")"
        printf 'pwdLastSet: 0\n'
    } | ldap_add >/dev/null 2>"$ERR_FILE"; then
        password=''
        report "$row" "$employee_id" "$display" "$sam" "$upn" "$department" "$ou" "$group_list" Failed \
            "The directory refused the new account: $(last_error)" "$warnings" ''
        continue
    fi

    for group in "${groups[@]}"; do
        if ! samba_tool group addmembers "$group" "$sam" >/dev/null 2>"$ERR_FILE"; then
            warnings+="${warnings:+ }Could not add the account to group '$group': $(last_error)"
        fi
    done

    delivery_file=''
    if ! delivery_file=$(deliver_password "$sam" "$upn" "$password"); then
        delivery_file=''
        warnings+="${warnings:+ }The password delivery file could not be written: $(last_error). Reset the password to hand the account over."
    fi
    password=''

    report "$row" "$employee_id" "$display" "$sam" "$upn" "$department" "$ou" "$group_list" Created \
        "Created $upn in $ou." "$warnings" "$delivery_file"
done 3<"$FEED_FILE"

summary=''
for status in Created Exists Planned Invalid Failed; do
    if [[ -n ${COUNTS[$status]:-} ]]; then
        summary+="${summary:+, }${COUNTS[$status]} ${status,,}"
    fi
done
printf '\nOnboarding summary: %s.\n' "$summary"

if [[ -n $SUMMARY_FILE ]]; then
    {
        printf '%s\n' "$SUMMARY_HEADER"
        printf '%s\n' "${SUMMARY_LINES[@]}"
    } >"$SUMMARY_FILE"
fi

if [[ -n ${COUNTS[Invalid]:-} || -n ${COUNTS[Failed]:-} ]]; then
    exit 1
fi
exit 0
