#!/usr/bin/env bats
#
# Unit tests for linux/onboard-user.sh, against the fake Samba tools in helpers/fakes.

# Each @test runs in its own subshell, so changing CONFIG in one test is the intent (SC2030, SC2031).
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup_file() {
    export CERT_DIR="$BATS_FILE_TMPDIR/cert"
    mkdir -p "$CERT_DIR"
    load 'helpers/common'
    new_certificate "$CERT_DIR"
}

setup() {
    load 'helpers/common'
    common_setup
    export ITO_LDAP_URL=ldap://dc1.corp.itops.test
    export ITO_AUTH_FILE="$BATS_TEST_TMPDIR/admin.auth"
    printf 'username=Administrator\npassword=Test-Only-Admin-Pw1!\ndomain=CORP\n' >"$ITO_AUTH_FILE"
    chmod 600 "$ITO_AUTH_FILE"
    DELIVER="$BATS_TEST_TMPDIR/deliver"
    mkdir -p "$DELIVER"
    CONFIG="$REPO_ROOT/tests/bats/fixtures/onboarding.json"
    FEED="$BATS_TEST_TMPDIR/feed.csv"

    # A directory where the configured OUs and groups exist and nobody else does.
    ldb_object 'OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
    ldb_object 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    ldb_groups_exist All-Staff Finance-Users Sales-Users
}

feed() {
    printf 'EmployeeId,GivenName,Surname,Department,Title,Manager,StartDate\n' >"$FEED"
    printf '%s\n' "$@" >>"$FEED"
}

onboard() {
    "$REPO_ROOT/linux/onboard-user.sh" --csv "$FEED" --config "$CONFIG" --deliver-dir "$DELIVER" --deliver-cert "$CERT_DIR/delivery.pem" "$@"
}

# password_in_ldif N: the password the Nth ldbadd call set, decoded from unicodePwd.
password_in_ldif() {
    awk -v n="$1" 'BEGIN { RS = ""; } NR == n' "$FAKE_LDB/ldbadd.ldif" |
        sed -n 's/^unicodePwd:: //p' | base64 -d | iconv -f UTF-16LE -t UTF-8 | sed 's/^"//; s/"$//'
}

@test 'shows help' {
    run "$REPO_ROOT/linux/onboard-user.sh" --help
    assert_success
    assert_line --partial 'Usage: onboard-user.sh --csv FILE --config FILE [options]'
}

@test 'rejects bad arguments with exit code 64' {
    feed 'E1,Sara,Ali,Finance,,,'
    local cases=(
        "--config $CONFIG|Missing --csv."
        "--csv $FEED|Missing --config."
        "--csv $FEED --config $CONFIG --url http://dc|'http://dc' is not an ldap:// or ldaps:// URL."
        "--csv $FEED --config $CONFIG --password-length 12 --dry-run|--password-length must be a whole number from 14 to 128."
        "--csv $FEED --config $CONFIG|Real runs need --deliver-dir and --deliver-cert"
        "--csv $FEED --config $CONFIG --bogus|Unknown option '--bogus'."
    )
    local item arguments message
    for item in "${cases[@]}"; do
        arguments=${item%%|*}
        message=${item#*|}
        # shellcheck disable=SC2086 # the test arguments are split on purpose
        run "$REPO_ROOT/linux/onboard-user.sh" $arguments
        assert_failure 64
        assert_output --partial "$message"
    done
}

@test 'refuses an authentication file that other users can read' {
    feed 'E1,Sara,Ali,Finance,,,'
    chmod 644 "$ITO_AUTH_FILE"
    run onboard --dry-run
    assert_failure 77
    assert_output --partial 'can be read by other users (mode 644)'
}

@test 'lists every problem in an invalid configuration' {
    feed 'E1,Sara,Ali,Finance,,,'
    printf '{"upnSuffix":"bad","disabledOu":"x","departments":{}}' >"$BATS_TEST_TMPDIR/bad.json"
    CONFIG="$BATS_TEST_TMPDIR/bad.json"
    run onboard --dry-run
    assert_failure 65
    assert_output --partial "'upnSuffix' must be a DNS domain name"
    assert_output --partial "'departments' must be an object with at least one department."
}

@test 'reports a directory it cannot reach' {
    feed 'E1,Sara,Ali,Finance,,,'
    touch "$FAKE_LDB/fail-ldbsearch"
    run onboard --dry-run
    assert_failure 69
    assert_output --partial 'Could not read the directory at ldap://dc1.corp.itops.test: Failed to connect to ldap URL'
}

@test 'the dry run plans every row, reserves names within the batch and changes nothing' {
    feed 'E1,Sara,Ali,Finance,,,' 'E2,Sara,Ali,Sales,,,' 'E3,José,García-López,finance,,,'
    run "$REPO_ROOT/linux/onboard-user.sh" --csv "$FEED" --config "$CONFIG" --dry-run
    assert_success
    assert_line --regexp '^1 +sara\.ali +Planned +Would create sara\.ali@corp\.itops\.test in OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test and add it to 2 group\(s\)\.$'
    assert_line --regexp '^2 +sara\.ali2 +Planned +Would create sara\.ali2@corp\.itops\.test in OU=Sales'
    assert_line --regexp '^3 +jose\.garcialopez +Planned'
    assert_output --partial 'Onboarding summary: 3 planned.'
    assert_equal "$(calls_to ldbadd)" ''
    assert_equal "$(calls_to samba-tool)" ''
    run ls "$DELIVER"
    assert_output ''
}

@test 'creates an account with every attribute in one ldbadd call' {
    feed 'E77,Sara,Ali,finance,Accounts Assistant,,2026-10-05'
    run onboard
    assert_success
    assert_line --regexp '^1 +sara\.ali +Created +Created sara\.ali@corp\.itops\.test in OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\.$'
    assert_output --partial 'Onboarding summary: 1 created.'

    run cat "$FAKE_LDB/ldbadd.ldif"
    assert_line 'dn: CN=Sara Ali,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
    assert_line 'objectClass: user'
    assert_line 'sAMAccountName: sara.ali'
    assert_line 'userPrincipalName: sara.ali@corp.itops.test'
    assert_line 'givenName: Sara'
    assert_line 'sn: Ali'
    assert_line 'displayName: Sara Ali'
    assert_line 'mail: sara.ali@corp.itops.test'
    assert_line 'employeeID: E77'
    assert_line 'department: Finance'
    assert_line 'title: Accounts Assistant'
    assert_line --regexp '^description: Start date 2026-10-05\. Onboarded [0-9-]{10} by it-ops-toolkit$'
    assert_line 'userAccountControl: 512'
    assert_line 'pwdLastSet: 0'
    assert_line --regexp '^unicodePwd:: [A-Za-z0-9+/=]+$'
    assert_equal "$(calls_to ldbadd | wc -l)" 1
}

@test 'adds the account to the default and department groups, each once' {
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_success
    run calls_to samba-tool
    assert_line --index 0 'samba-tool group addmembers All-Staff sara.ali -H ldap://dc1.corp.itops.test -A '"$ITO_AUTH_FILE"
    assert_line --index 1 'samba-tool group addmembers Finance-Users sara.ali -H ldap://dc1.corp.itops.test -A '"$ITO_AUTH_FILE"
    assert_equal "${#lines[@]}" 2
}

@test 'delivers the same password it set, encrypted, readable only by the owner' {
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_success
    run stat -c '%a' "$DELIVER/sara.ali.cms"
    assert_output '600'
    run head -n 1 "$DELIVER/sara.ali.cms"
    assert_output '-----BEGIN CMS-----'
    run decrypt_delivery "$DELIVER/sara.ali.cms" "$CERT_DIR"
    assert_line --index 0 'Account: sara.ali'
    assert_line --index 1 'Sign-in name: sara.ali@corp.itops.test'
    assert_line --index 3 'The user must choose a new password at first sign-in.'
    delivered=$(decrypt_delivery "$DELIVER/sara.ali.cms" "$CERT_DIR" | sed -n 's/^Initial password: //p')
    assert_equal "$(password_in_ldif 1)" "$delivered"
    assert_equal "${#delivered}" 20
}

@test 'never shows the password in output, on a command line or in the summary' {
    feed 'E1,Sara,Ali,Finance,,,' 'E2,Omar,Haddad,Sales,,,'
    run onboard --summary "$BATS_TEST_TMPDIR/summary.csv"
    assert_success
    for n in 1 2; do
        password=$(password_in_ldif "$n")
        [[ -n $password ]]
        [[ $output != *"$password"* ]]
        run grep -cF -- "$password" "$FAKE_LDB/calls.log" "$BATS_TEST_TMPDIR/summary.csv"
        assert_output --partial 'calls.log:0'
        assert_output --partial 'summary.csv:0'
    done
}

@test 'writes strong passwords of the requested length without the name in them' {
    feed 'E1,Sara,Ali,Finance,,,' 'E2,Omar,Haddad,Sales,,,' 'E3,Lina,Khan,Sales,,,'
    run onboard --password-length 32
    assert_success
    for n in 1 2 3; do
        password=$(password_in_ldif "$n")
        assert_equal "${#password}" 32
        [[ $password =~ [A-Z] && $password =~ [a-z] && $password =~ [2-9] && $password =~ [^A-Za-z0-9] ]]
        [[ ! ${password,,} =~ (sara|omar|haddad|lina|khan) ]]
    done
}

@test 'skips a new starter who already has an account' {
    printf 'dn: CN=Sara Ali,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\nsAMAccountName: sara.ali\nmemberOf: CN=All-Staff,CN=Users,DC=corp,DC=itops,DC=test\nmemberOf: CN=Finance-Users,CN=Users,DC=corp,DC=itops,DC=test\n' |
        ldb_respond sub '(&(objectClass=user)(employeeID=E1))'
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_success
    assert_line --regexp '^1 +sara\.ali +Exists +An account with employee ID E1 already exists \(sara\.ali\)\. No changes were made\.$'
    refute_output --partial 'Warning:'
    assert_equal "$(calls_to ldbadd)" ''
}

@test 'warns, without changing anything, when an existing account lacks configured groups' {
    printf 'dn: CN=Sara Ali,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\nsAMAccountName: sara.ali\nmemberOf: CN=ALL-STAFF,CN=Users,DC=corp,DC=itops,DC=test\n' |
        ldb_respond sub '(&(objectClass=user)(employeeID=E1))'
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard --summary "$BATS_TEST_TMPDIR/summary.csv"
    assert_success
    assert_line --regexp '^1 +sara\.ali +Exists '
    assert_line --regexp "^ +Warning: The existing account is not in the configured group 'Finance-Users'\. Check that the person still needs it, then add it by hand\.$"
    refute_output --partial "group 'All-Staff'"
    assert_equal "$(calls_to samba-tool)" ''
    run grep -c "not in the configured group 'Finance-Users'" "$BATS_TEST_TMPDIR/summary.csv"
    assert_output 1
}

@test 'picks the next free account name when names are taken' {
    printf 'dn: CN=Sara Ali,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test\n' |
        ldb_respond sub '(|(sAMAccountName=sara.ali)(userPrincipalName=sara.ali@corp.itops.test))'
    printf 'dn: CN=Sara Ali (sara.ali2),OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test\n' |
        ldb_respond sub '(|(sAMAccountName=sara.ali2)(userPrincipalName=sara.ali2@corp.itops.test))'
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_success
    assert_line --regexp '^1 +sara\.ali3 +Created'
}

@test 'adds the account name to the CN when the OU already has an object with that name' {
    printf 'dn: CN=Sara Ali,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\n' |
        ldb_respond one '(cn=Sara Ali)'
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_success
    run grep '^dn: ' "$FAKE_LDB/ldbadd.ldif"
    assert_output 'dn: CN=Sara Ali (sara.ali),OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
}

@test 'uses the account name as the CN when the name plus the account name would pass 64 characters' {
    printf 'dn: CN=Anastasia-Konstantina Montgomery-Smithsonian,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\n' |
        ldb_respond one '(cn=Anastasia-Konstantina Montgomery-Smithsonian)'
    feed 'E1,Anastasia-Konstantina,Montgomery-Smithsonian,Finance,,,'
    run onboard
    assert_success
    run grep '^dn: ' "$FAKE_LDB/ldbadd.ldif"
    assert_output 'dn: CN=anastasiakonstantina,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
}

@test 'base64-encodes names with accents in the LDIF' {
    feed 'E1,José,García-López,Finance,,,'
    run onboard
    assert_success
    run cat "$FAKE_LDB/ldbadd.ldif"
    assert_line "dn:: $(printf '%s' 'CN=José García-López,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test' | base64 -w0)"
    assert_line "sn:: $(printf '%s' 'García-López' | base64 -w0)"
    assert_line 'sAMAccountName: jose.garcialopez'
}

@test 'sets the manager when found and warns when not' {
    printf 'dn: CN=Lina Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test\ndistinguishedName: CN=Lina Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test\n' |
        ldb_respond sub '(&(objectClass=user)(sAMAccountName=lina.haddad))'
    feed 'E1,Sara,Ali,Finance,,lina.haddad,' 'E2,Omar,Haddad,Sales,,no.such,'
    run onboard
    assert_success
    assert_line --regexp '^ +Warning: Manager .no\.such. was not found, so no manager was set\.$'
    run grep '^manager: ' "$FAKE_LDB/ldbadd.ldif"
    assert_output 'manager: CN=Lina Haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
}

@test 'reports invalid rows, carries on, and exits 1' {
    feed 'E1,Noor,Khan,Marketing,,,' 'E2,Sara,Ali,Finance,,,' 'E3,,Ali,Finance,,,'
    run onboard
    assert_failure 1
    assert_line --regexp "^1 +- +Invalid +Department 'Marketing' is not in the configuration\. Known departments: Finance, Sales\.$"
    assert_line --regexp '^2 +sara\.ali +Created'
    assert_line --regexp '^3 +- +Invalid +GivenName is required\.$'
    assert_output --partial 'Onboarding summary: 1 created, 2 invalid.'
}

@test 'fails rows whose OU or group is missing, before creating anything' {
    ldb_groups_exist All-Staff Finance-Users
    rm -f "$FAKE_LDB"/responses/"$(ldb_key sub '(&(objectClass=group)(sAMAccountName=Sales-Users))')".ldif
    printf '%s\n' 'ou=finance,ou=staff,dc=corp,dc=itops,dc=test' >"$FAKE_LDB/objects"
    feed 'E1,Omar,Haddad,Sales,,,'
    run onboard
    assert_failure 1
    assert_line --regexp "^1 +- +Failed +The OU 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test' from the configuration could not be found\.$"
    ldb_object 'OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    run onboard
    assert_failure 1
    assert_line --regexp "^1 +- +Failed +The group 'Sales-Users' from the configuration does not exist in the directory\.$"
    assert_equal "$(calls_to ldbadd)" ''
}

@test 'reports a refused account without leaking the password from the tool error' {
    touch "$FAKE_LDB/fail-ldbadd"
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard
    assert_failure 1
    assert_line --regexp '^1 +sara\.ali +Failed +The directory refused the new account: '
    [[ $output != *unicodePwd* ]]
    password=$(password_in_ldif 1)
    [[ $output != *"$password"* ]]
    run ls "$DELIVER"
    assert_output ''
}

@test 'records a failed group addition as a warning without failing the row' {
    touch "$FAKE_LDB/fail-samba-tool-group-addmembers"
    feed 'E1,Sara,Ali,Finance,,,'
    run onboard --summary "$BATS_TEST_TMPDIR/summary.csv"
    assert_success
    assert_line --regexp '^1 +sara\.ali +Created'
    assert_line --regexp "Warning: Could not add the account to group 'All-Staff': ERROR: Failed to addmembers"
    run cat "$BATS_TEST_TMPDIR/summary.csv"
    assert_line --index 0 '"Row","EmployeeId","DisplayName","SamAccountName","UserPrincipalName","Department","OrganizationalUnit","Groups","Status","Message","Warnings","DeliveryFile"'
    assert_line --index 1 --regexp "^\"1\",\"E1\",\"Sara Ali\",\"sara\.ali\",\"sara\.ali@corp\.itops\.test\",\"Finance\",\"OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test\",\"All-Staff;Finance-Users\",\"Created\",.*\"$DELIVER/sara\.ali\.cms\"$"
}

@test 'refuses a delivery certificate that cannot encrypt' {
    feed 'E1,Sara,Ali,Finance,,,'
    printf 'not a certificate\n' >"$BATS_TEST_TMPDIR/bad.pem"
    run "$REPO_ROOT/linux/onboard-user.sh" --csv "$FEED" --config "$CONFIG" --deliver-dir "$DELIVER" --deliver-cert "$BATS_TEST_TMPDIR/bad.pem"
    assert_failure 65
    assert_output --partial 'cannot be used for encryption'
    assert_equal "$(calls_to ldbsearch)" ''
}

@test 'warns about an empty feed' {
    feed
    run onboard
    assert_success
    assert_output --partial 'has no data rows'
}

@test 'reports a feed without the required columns' {
    printf 'EmployeeId,FirstName\nE1,Sara\n' >"$FEED"
    run onboard
    assert_failure 65
    assert_output --partial 'is missing required columns: GivenName, Surname, Department.'
}

@test 'explains a missing command' {
    isolate_path
    feed 'E1,Sara,Ali,Finance,,,'
    rm -f "$FAKE_BIN/samba-tool"
    run onboard --dry-run
    assert_failure 69
    assert_output --partial "Required command 'samba-tool' was not found."
}
