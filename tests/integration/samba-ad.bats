#!/usr/bin/env bats
#
# Integration tests: onboard-user.sh and offboard-user.sh against a real Samba Active Directory
# domain controller. Run them with tests/integration/run.sh, which starts the DC in Docker and
# removes it afterwards. The tests run in file order and build on each other.

bats_require_minimum_version 1.5.0

setup_file() {
    export ITO_LDAP_URL=${ITO_LDAP_URL:-ldap://dc}
    export WORK=$BATS_FILE_TMPDIR
    export BASE_DN='DC=corp,DC=itops,DC=test'
    printf 'username=Administrator\npassword=%s\ndomain=CORP\n' "$SAMBA_ADMIN_PASSWORD" >"$WORK/admin.auth"
    chmod 600 "$WORK/admin.auth"
    export ITO_AUTH_FILE=$WORK/admin.auth

    # The OUs and groups that config/onboarding.example.json refers to.
    local ou group
    for ou in 'OU=Staff' 'OU=Finance,OU=Staff' 'OU=Sales,OU=Staff' 'OU=IT,OU=Staff' 'OU=Human Resources,OU=Staff' 'OU=Disabled Users'; do
        samba-tool ou create "$ou" -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" >/dev/null
    done
    for group in All-Staff Finance-Users Finance-Share-RW Sales-Users CRM-Users IT-Users IT-Helpdesk HR-Users HR-Share-RW; do
        samba-tool group add "$group" -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" >/dev/null
    done
    # A manager for the edge-case feed. A test-only password on the command line is acceptable here.
    samba-tool user create lina.haddad 'Manager-Test-Passw0rd!' --userou='OU=Sales,OU=Staff' \
        -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" >/dev/null

    # The service desk's delivery certificate and private key.
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Service Desk Delivery' \
        -keyout "$WORK/delivery.key" -out "$WORK/delivery.pem" 2>/dev/null
    mkdir -p "$WORK/deliver" "$WORK/audit"
}

setup() {
    bats_load_library bats-support
    bats_load_library bats-assert
}

# attribute ACCOUNT ATTRIBUTE: prints the attribute values of an account, decoded.
attribute() {
    ldbsearch -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" -b "$BASE_DN" -s sub "(sAMAccountName=$1)" "$2" |
        bash -c 'source linux/lib/common.sh; source linux/lib/directory.sh; ldif_values "$1"' _ "$2"
}

# initial_password ACCOUNT: decrypts the delivery file, as the service desk would.
initial_password() {
    openssl cms -decrypt -binary -inform PEM -in "$WORK/deliver/$1.cms" -inkey "$WORK/delivery.key" -recip "$WORK/delivery.pem" |
        sed -n 's/^Initial password: //p'
}

onboard() {
    linux/onboard-user.sh --config config/onboarding.example.json \
        --deliver-dir "$WORK/deliver" --deliver-cert "$WORK/delivery.pem" "$@"
}

@test 'the dry run plans every row and creates nothing' {
    run linux/onboard-user.sh --csv examples/new-starters.csv --config config/onboarding.example.json --dry-run
    assert_success
    assert_output --partial 'Onboarding summary: 5 planned.'
    assert_line --regexp '^2 +sara\.ali2 +Planned +Would create sara\.ali2@corp\.itops\.test in OU=Sales'
    run attribute sara.ali sAMAccountName
    assert_output ''
    run ls "$WORK/deliver"
    assert_output ''
}

@test 'onboarding creates the example feed with unique account names in the mapped OUs' {
    run onboard --csv examples/new-starters.csv --summary "$WORK/summary.csv"
    printf '%s\n' "$output" >"$WORK/onboard-output.txt"
    assert_success
    assert_output --partial 'Onboarding summary: 5 created.'
    run attribute sara.ali distinguishedName
    assert_output 'CN=Sara Ali,OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test'
    run attribute sara.ali2 distinguishedName
    assert_output 'CN=Sara Ali,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    run attribute jose.garcialopez distinguishedName
    assert_output "CN=José García-López,OU=IT,OU=Staff,DC=corp,DC=itops,DC=test"
    run attribute liam.obrien distinguishedName
    assert_output "CN=Liam O'Brien,OU=Human Resources,OU=Staff,DC=corp,DC=itops,DC=test"
}

@test 'new accounts are enabled, must change their password and carry the HR data' {
    run attribute jose.garcialopez userAccountControl
    assert_output '512'
    run attribute jose.garcialopez pwdLastSet
    assert_output '0'
    run attribute jose.garcialopez employeeID
    assert_output 'E10423'
    run attribute jose.garcialopez title
    assert_output 'Service Desk Analyst'
    run attribute jose.garcialopez department
    assert_output 'IT'
    run attribute jose.garcialopez mail
    assert_output 'jose.garcialopez@corp.itops.test'
    run attribute jose.garcialopez userPrincipalName
    assert_output 'jose.garcialopez@corp.itops.test'
    run attribute jose.garcialopez displayName
    assert_output 'José García-López'
    run attribute aisha.almansoori title
    assert_output 'Analyst, Financial Planning'
    run attribute jose.garcialopez description
    assert_output --regexp '^Start date 2026-10-12\. Onboarded [0-9-]{10} by it-ops-toolkit$'
}

@test 'new accounts are in the default and department groups' {
    run attribute sara.ali memberOf
    assert_line 'CN=All-Staff,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line 'CN=Finance-Users,CN=Users,DC=corp,DC=itops,DC=test'
    assert_line 'CN=Finance-Share-RW,CN=Users,DC=corp,DC=itops,DC=test'
    assert_equal "${#lines[@]}" 3
}

@test 'the delivered password is the real initial password, and it must be changed at first sign-in' {
    run stat -c '%a' "$WORK/deliver/sara.ali.cms"
    assert_output '600'
    local password
    password=$(initial_password sara.ali)
    assert_equal "${#password}" 20
    run smbclient -L //dc -U "CORP/sara.ali%$password"
    assert_failure
    assert_output --partial 'NT_STATUS_PASSWORD_MUST_CHANGE'
    run smbclient -L //dc -U 'CORP/sara.ali%Wrong-Passw0rd!'
    assert_output --partial 'NT_STATUS_LOGON_FAILURE'
}

@test 'the initial passwords never appear in the output or the summary' {
    local account password
    for account in sara.ali sara.ali2 jose.garcialopez liam.obrien aisha.almansoori; do
        password=$(initial_password "$account")
        [[ -n $password ]]
        run grep -F -c -- "$password" "$WORK/onboard-output.txt" "$WORK/summary.csv"
        assert_output --partial 'onboard-output.txt:0'
        assert_output --partial 'summary.csv:0'
    done
}

@test 'running the same feed again changes nothing' {
    run onboard --csv examples/new-starters.csv
    assert_success
    assert_output --partial 'Onboarding summary: 5 exists.'
    run ldbsearch -H "$ITO_LDAP_URL" -A "$ITO_AUTH_FILE" -b "$BASE_DN" -s sub '(employeeID=E10421)' dn
    assert_output --partial '# 1 entries'
}

@test 'an edge-case feed reports its bad rows and still creates the good ones' {
    run onboard --csv tests/integration/fixtures/edge-cases.csv
    assert_failure 1
    assert_line --regexp '^1 +omar\.haddad +Created'
    assert_line --regexp "^2 +- +Invalid +Department 'Marketing' is not in the configuration"
    assert_line --regexp '^3 +priya\.nair +Created'
    assert_line --regexp "Warning: Manager 'no\.such\.manager' was not found"
    assert_line --regexp "^4 +- +Invalid +EmployeeId 'E20003' appears more than once"
    assert_line --regexp '^5 +- +Invalid +GivenName .* has no letters that can be used in an account name'
    assert_line --regexp '^6 +christopher\.montgome +Created'
    assert_output --partial 'Onboarding summary: 3 created, 3 invalid.'

    run attribute omar.haddad manager
    assert_output 'CN=lina.haddad,OU=Sales,OU=Staff,DC=corp,DC=itops,DC=test'
    run attribute omar.haddad department
    assert_output 'Sales'
}

@test 'offboarding dry run changes nothing' {
    run linux/offboard-user.sh --user sara.ali --ticket inc0012345 --audit-dir "$WORK/audit" --config config/onboarding.example.json --dry-run
    assert_success
    assert_line 'Would disable the account'
    assert_line 'Would move the account to OU=Disabled Users,DC=corp,DC=itops,DC=test'
    assert_output --partial 'Planned: no changes were made'
    run attribute sara.ali userAccountControl
    assert_output '512'
    run ls "$WORK/audit"
    assert_output ''
}

@test 'offboarding disables the account, records the ticket, exports and removes groups, and moves it' {
    run linux/offboard-user.sh --user sara.ali --ticket inc0012345 --audit-dir "$WORK/audit" --config config/onboarding.example.json
    assert_success
    assert_output --partial 'Offboarded sara.ali under INC0012345: Exported group memberships, Disabled account, Recorded ticket in description, Removed from 3 group(s), Moved to disabled users OU.'

    run attribute sara.ali userAccountControl
    assert_output '514'
    run attribute sara.ali description
    assert_output --regexp '^Offboarded [0-9-]{10} ticket INC0012345 \| previous: Start date 2026-10-05\. Onboarded'
    run attribute sara.ali memberOf
    assert_output ''
    run attribute sara.ali distinguishedName
    assert_output 'CN=Sara Ali,OU=Disabled Users,DC=corp,DC=itops,DC=test'

    run bash -c "cat '$WORK'/audit/sara.ali_INC0012345_*_groups.csv"
    assert_line --index 0 '"SamAccountName","TicketNumber","GroupDistinguishedName","ExportedAtUtc"'
    assert_line --regexp '^"sara\.ali","INC0012345","CN=Finance-Share-RW,CN=Users,DC=corp,DC=itops,DC=test","[0-9T:Z-]+"$'
    assert_equal "${#lines[@]}" 4
}

@test 'the offboarded account can no longer sign in' {
    run smbclient -L //dc -U "CORP/sara.ali%$(initial_password sara.ali)"
    assert_failure
    assert_output --partial 'NT_STATUS_ACCOUNT_DISABLED'
}

@test 'offboarding the same account again changes nothing' {
    run linux/offboard-user.sh --user sara.ali --ticket INC0012345 --audit-dir "$WORK/audit" --config config/onboarding.example.json
    assert_success
    assert_output 'Already offboarded: sara.ali needed no changes.'
    run bash -c "ls '$WORK'/audit | wc -l"
    assert_output '1'
}

@test 'offboarding an unknown account fails with a clear message' {
    run linux/offboard-user.sh --user no.such --ticket INC0012345 --audit-dir "$WORK/audit" --config config/onboarding.example.json
    assert_failure 1
    assert_output "Offboarding no.such failed: No user account named 'no.such' was found."
}
