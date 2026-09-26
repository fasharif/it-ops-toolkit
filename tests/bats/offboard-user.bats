#!/usr/bin/env bats
#
# Unit tests for linux/offboard-user.sh, against the fake Samba tools in helpers/fakes.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    common_setup
    export ITO_LDAP_URL=ldap://dc1.corp.itops.test
    export ITO_AUTH_FILE="$BATS_TEST_TMPDIR/admin.auth"
    printf 'username=Administrator\npassword=Test-Only-Admin-Pw1!\ndomain=CORP\n' >"$ITO_AUTH_FILE"
    chmod 600 "$ITO_AUTH_FILE"
    AUDIT="$BATS_TEST_TMPDIR/audit"
    mkdir -p "$AUDIT"
    CONFIG="$REPO_ROOT/tests/bats/fixtures/onboarding.json"
    USER_FILTER='(&(objectCategory=person)(objectClass=user)(sAMAccountName=omar.haddad))'
}

# account LDIF: registers the search result for omar.haddad.
account() {
    printf '%s\n' "$1" | ldb_respond sub "$USER_FILTER"
}

active_account() {
    account 'dn: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test
userAccountControl: 512
description: Account manager
memberOf: CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test
memberOf: CN=SG-Shared-Drive-Sales-With-A-Name-Long-Enough-To-Be-Folded-By-The-Serv
 er,CN=Users,DC=corp,DC=itops,DC=test
distinguishedName: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
}

offboard() {
    "$REPO_ROOT/linux/offboard-user.sh" --user omar.haddad --ticket inc0012345 --audit-dir "$AUDIT" --config "$CONFIG" "$@"
}

@test 'shows help' {
    run "$REPO_ROOT/linux/offboard-user.sh" --help
    assert_success
    assert_line --partial 'Usage: offboard-user.sh --user ACCOUNT --ticket TICKET --audit-dir DIR'
}

@test 'rejects bad arguments with exit code 64' {
    local cases=(
        "--ticket INC1 --audit-dir $AUDIT --config $CONFIG|Missing --user."
        "--user omar*)(cn=* --ticket INC1 --audit-dir $AUDIT --config $CONFIG|is not a valid account name"
        "--user omar.haddad --ticket 12345 --audit-dir $AUDIT --config $CONFIG|'12345' is not a ticket number"
        "--user omar.haddad --ticket INC1 --config $CONFIG|Missing --audit-dir."
        "--user omar.haddad --ticket INC1 --audit-dir $AUDIT|Give --config or --disabled-ou."
        "--user omar.haddad --ticket INC1 --audit-dir $AUDIT --config $CONFIG --disabled-ou OU=X,DC=a|not both"
        "--user omar.haddad --ticket INC1 --audit-dir $AUDIT --disabled-ou Leavers|'Leavers' is not a distinguished name"
    )
    local item arguments message
    for item in "${cases[@]}"; do
        arguments=${item%%|*}
        message=${item#*|}
        # shellcheck disable=SC2086 # the test arguments are split on purpose
        run "$REPO_ROOT/linux/offboard-user.sh" $arguments
        assert_failure 64
        assert_output --partial "$message"
    done
}

@test 'offboards an active account in the documented order' {
    active_account
    run offboard
    assert_success
    assert_line --index 0 --regexp "^Exported 2 group membership\(s\) to $AUDIT/omar\.haddad_INC0012345_[0-9]{8}T[0-9]{6}Z_groups\.csv$"
    assert_line --index 1 'Disabled the account'
    assert_line --index 2 --regexp "^Set the description to 'Offboarded [0-9-]{10} ticket INC0012345 \| previous: Account manager'$"
    assert_line --index 3 'Removed the account from CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line --index 4 'Removed the account from CN=SG-Shared-Drive-Sales-With-A-Name-Long-Enough-To-Be-Folded-By-The-Server,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line --index 5 'Moved the account to OU=Disabled Users,DC=corp,DC=itops,DC=test'
    assert_line --index 6 'Offboarded omar.haddad under INC0012345: Exported group memberships, Disabled account, Recorded ticket in description, Removed from 2 group(s), Moved to disabled users OU.'

    run calls_to samba-tool
    assert_line --index 0 "samba-tool user disable omar.haddad -H ldap://dc1.corp.itops.test -A $ITO_AUTH_FILE"
    assert_line --index 1 "samba-tool user move omar.haddad OU=Disabled Users,DC=corp,DC=itops,DC=test -H ldap://dc1.corp.itops.test -A $ITO_AUTH_FILE"
}

@test 'sends well-formed LDIF for the description and each group removal' {
    active_account
    run offboard
    assert_success
    run cat "$FAKE_LDB/ldbmodify.ldif"
    assert_line --index 0 'dn: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    assert_line --index 1 'changetype: modify'
    assert_line --index 2 'replace: description'
    assert_line --index 3 --regexp '^description: Offboarded [0-9-]{10} ticket INC0012345 \| previous: Account manager$'
    assert_line --index 4 'dn: CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line --index 5 'changetype: modify'
    assert_line --index 6 'delete: member'
    assert_line --index 7 'member: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
}

@test 'writes the audit file before any change' {
    active_account
    run offboard
    assert_success
    audit_file=$(ls "$AUDIT"/omar.haddad_INC0012345_*_groups.csv)
    run cat "$audit_file"
    assert_line --index 0 '"SamAccountName","TicketNumber","GroupDistinguishedName","ExportedAtUtc"'
    assert_line --index 1 --regexp '^"omar\.haddad","INC0012345","CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test","[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"$'
    assert_equal "${#lines[@]}" 3
}

@test 'changes nothing for an account that is already offboarded' {
    account 'dn: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test
userAccountControl: 514
description: Offboarded 2026-09-01 ticket INC0012345 | previous: Account manager
distinguishedName: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test'
    run offboard
    assert_success
    assert_output 'Already offboarded: omar.haddad needed no changes.'
    assert_equal "$(calls_to samba-tool)" ''
    assert_equal "$(calls_to ldbmodify)" ''
    run ls "$AUDIT"
    assert_output ''
}

@test 'records a ticket whose number is only a prefix of a ticket already in the description' {
    account 'dn: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test
userAccountControl: 514
description: Offboarded 2026-09-01 ticket INC12345
distinguishedName: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test'
    run "$REPO_ROOT/linux/offboard-user.sh" --user omar.haddad --ticket INC1 --audit-dir "$AUDIT" --config "$CONFIG"
    assert_success
    assert_line --regexp "^Set the description to 'Offboarded [0-9-]{10} ticket INC1 \| previous: Offboarded 2026-09-01 ticket INC12345'$"
}

@test 'treats the ticket as recorded when it appears as a whole token, in any case' {
    account 'dn: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test
userAccountControl: 514
description: Leaver, see req-2041.
distinguishedName: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test'
    run "$REPO_ROOT/linux/offboard-user.sh" --user omar.haddad --ticket REQ-2041 --audit-dir "$AUDIT" --config "$CONFIG"
    assert_success
    assert_output 'Already offboarded: omar.haddad needed no changes.'
}

@test 'finishes a partly completed offboarding' {
    account 'dn: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test
userAccountControl: 66050
description: Offboarded 2026-09-01 ticket INC0012345
memberOf: CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test
distinguishedName: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    run offboard
    assert_success
    refute_line 'Disabled the account'
    refute_line --partial 'Set the description'
    assert_line 'Removed the account from CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line 'Moved the account to OU=Disabled Users,DC=corp,DC=itops,DC=test'
}

@test 'the dry run lists every change and makes none' {
    active_account
    run offboard --dry-run
    assert_success
    assert_line --regexp '^Would export 2 group membership\(s\) to '
    assert_line 'Would disable the account'
    assert_line 'Would remove the account from CN=Sales-Users,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line 'Would move the account to OU=Disabled Users,DC=corp,DC=itops,DC=test'
    assert_line 'Planned: no changes were made (--dry-run).'
    assert_equal "$(calls_to samba-tool)" ''
    assert_equal "$(calls_to ldbmodify)" ''
    run ls "$AUDIT"
    assert_output ''
}

@test 'uses --disabled-ou instead of the configuration' {
    active_account
    run "$REPO_ROOT/linux/offboard-user.sh" --user omar.haddad --ticket REQ-2041 --audit-dir "$AUDIT" --disabled-ou 'OU=Leavers,DC=corp,DC=itops,DC=test'
    assert_success
    assert_line 'Moved the account to OU=Leavers,DC=corp,DC=itops,DC=test'
}

@test 'keeps escaped commas when working out the parent OU' {
    account 'dn: CN=Haddad\, Omar,OU=Disabled Users,DC=corp,DC=itops,DC=test
userAccountControl: 514
description: Offboarded 2026-09-01 ticket INC0012345
distinguishedName: CN=Haddad\, Omar,OU=Disabled Users,DC=corp,DC=itops,DC=test'
    run offboard
    assert_success
    assert_output 'Already offboarded: omar.haddad needed no changes.'
}

@test 'keeps a non-ASCII description intact and base64-encodes it' {
    account "dn: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test
userAccountControl: 514
description:: $(printf '%s' 'Équipe ventes – Dubaï' | base64 -w0)
distinguishedName: CN=Omar Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test"
    run offboard
    assert_success
    encoded=$(sed -n 's/^description:: //p' "$FAKE_LDB/ldbmodify.ldif")
    run bash -c "printf '%s' '$encoded' | base64 -d"
    assert_output --regexp '^Offboarded [0-9-]{10} ticket INC0012345 \| previous: Équipe ventes – Dubaï$'
}

@test 'limits the description to 1024 bytes without splitting a character' {
    long=$(printf 'é%.0s' {1..600})
    account "dn: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test
userAccountControl: 514
description:: $(printf '%s' "$long" | base64 -w0)
distinguishedName: CN=Omar Haddad,OU=Disabled Users,DC=corp,DC=itops,DC=test"
    run offboard
    assert_success
    encoded=$(sed -n 's/^description:: //p' "$FAKE_LDB/ldbmodify.ldif")
    bytes=$(printf '%s' "$encoded" | base64 -d | wc -c)
    ((bytes <= 1024 && bytes >= 1022))
    printf '%s' "$encoded" | base64 -d | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test 'fails cleanly for an unknown account' {
    run offboard
    assert_failure 1
    assert_output "Offboarding omar.haddad failed: No user account named 'omar.haddad' was found."
}

@test 'stops before removing groups when a change fails' {
    active_account
    touch "$FAKE_LDB/fail-samba-tool-user-disable"
    run offboard
    assert_failure 1
    assert_output --partial 'Offboarding omar.haddad failed: Could not disable the account: ERROR: Failed to disable'
    assert_equal "$(calls_to ldbmodify)" ''
}

@test 'refuses an audit folder it cannot write to before changing anything' {
    active_account
    run "$REPO_ROOT/linux/offboard-user.sh" --user omar.haddad --ticket INC1 --audit-dir "$BATS_TEST_TMPDIR/missing" --config "$CONFIG"
    assert_failure 73
    assert_output --partial "The audit folder '$BATS_TEST_TMPDIR/missing' does not exist or is not writable."
    assert_equal "$(calls_to ldbsearch)" ''
}
