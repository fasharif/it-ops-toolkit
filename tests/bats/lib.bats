#!/usr/bin/env bats
#
# Unit tests for linux/lib: common.sh, directory.sh, config-check.jq and hrfeed.py.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    common_setup
    # shellcheck source=../../linux/lib/common.sh
    source "$REPO_ROOT/linux/lib/common.sh"
    # shellcheck source=../../linux/lib/directory.sh
    source "$REPO_ROOT/linux/lib/directory.sh"
}

@test 'json_escape escapes quotes, backslashes and control characters' {
    run json_escape $'say "hi" \x5c tab\there\nnext\x02'
    assert_output --regexp '^say ."hi." .. tab.there.nnext.u0002$'
    run json_escape $'say "hi" \x5c tab\there\nnext'
    assert_output 'say \"hi\" \\ tab\there\nnext'
}

@test 'json_escape leaves non-ASCII text alone' {
    run json_escape 'José García-López'
    assert_output 'José García-López'
}

@test 'html_escape escapes the five special characters' {
    run html_escape "<script>alert('x & \"y\"')</script>"
    assert_output '&lt;script&gt;alert(&#39;x &amp; &quot;y&quot;&#39;)&lt;/script&gt;'
}

@test 'csv_field quotes and doubles embedded quotes' {
    run csv_field 'CN=Smith\, John "JJ",OU=Staff'
    assert_output '"CN=Smith\, John ""JJ"",OU=Staff"'
}

@test 'join_by joins with a separator' {
    run join_by ', ' a b c
    assert_output 'a, b, c'
    run join_by ', '
    assert_output ''
}

@test 'is_integer accepts whole numbers only' {
    is_integer 0
    is_integer 42
    run is_integer -1
    assert_failure
    run is_integer 1.5
    assert_failure
    run is_integer ''
    assert_failure
}

@test 'check_secret_file accepts mode 600 and refuses files other users can read' {
    printf 'username=x\n' >"$BATS_TEST_TMPDIR/ok.auth"
    chmod 600 "$BATS_TEST_TMPDIR/ok.auth"
    check_secret_file "$BATS_TEST_TMPDIR/ok.auth" 'authentication file'
    cp "$BATS_TEST_TMPDIR/ok.auth" "$BATS_TEST_TMPDIR/open.auth"
    chmod 644 "$BATS_TEST_TMPDIR/open.auth"
    run check_secret_file "$BATS_TEST_TMPDIR/open.auth" 'authentication file'
    assert_failure 77
    assert_output --partial "can be read by other users (mode 644). Run: chmod 600"
    run check_secret_file "$BATS_TEST_TMPDIR/missing.auth" 'authentication file'
    assert_failure 66
}

@test 'ldif_values unfolds continuation lines and decodes base64 values' {
    ldif=$'# record 1\ndn: CN=Test,DC=corp\nmemberOf: CN=Short,DC=corp\nmemberOf: CN=A-Very-Long-Group-Name-That-The\n -Directory-Folded,DC=corp\ndescription:: Q2Fmw6kgc3RhZmYg4oCTIGxlYXZlcg==\nref: ldap://elsewhere\n'
    run ldif_values memberOf <<<"$ldif"
    assert_line --index 0 'CN=Short,DC=corp'
    assert_line --index 1 'CN=A-Very-Long-Group-Name-That-The-Directory-Folded,DC=corp'
    assert_equal "${#lines[@]}" 2
    run ldif_values DESCRIPTION <<<"$ldif"
    assert_output 'Café staff – leaver'
    run ldif_values title <<<"$ldif"
    assert_output ''
}

@test 'ldif_has_entry is true only when there is an entry' {
    ldif_has_entry <<<$'# record 1\ndn: CN=x,DC=corp\n'
    run ldif_has_entry <<<$'# returned 0 records\n'
    assert_failure
}

@test 'ldif_line writes plain ASCII as text and anything else as base64' {
    run ldif_line sn 'Smith'
    assert_output 'sn: Smith'
    run ldif_line sn 'García'
    assert_output "sn:: $(printf '%s' 'García' | base64 -w0)"
    run ldif_line description ' leading space'
    assert_output --regexp '^description:: '
    run ldif_line description 'trailing space '
    assert_output --regexp '^description:: '
    run ldif_line description ':colon first'
    assert_output --regexp '^description:: '
    run ldif_line description '<angle first'
    assert_output --regexp '^description:: '
}

@test 'ldap_filter_escape escapes the RFC 4515 special characters' {
    run ldap_filter_escape 'a*b(c)d\e'
    assert_output 'a\2ab\28c\29d\5ce'
}

@test 'dn_parent and dn_rdn respect escaped commas' {
    run dn_parent 'CN=Smith\, John,OU=Staff,DC=corp,DC=example'
    assert_output 'OU=Staff,DC=corp,DC=example'
    run dn_rdn 'CN=Smith\, John,OU=Staff,DC=corp,DC=example'
    assert_output 'CN=Smith\, John'
    run dn_parent 'DC=example'
    assert_failure
}

@test 'account names match the shared test vectors used by the PowerShell tests' {
    local rows=0
    while IFS=$'\t' read -r given surname format attempt expected; do
        rows=$((rows + 1))
        actual=$(sam_candidate "$given" "$surname" "$format" "$attempt")
        assert_equal "$actual" "$expected"
        ((${#actual} <= 20))
    done < <(python3 - "$REPO_ROOT/tests/fixtures/account-names.csv" <<'PY'
import csv, sys
sys.path.insert(0, sys.argv[1].rsplit('/tests/', 1)[0] + '/linux/lib')
from hrfeed import ascii_name
with open(sys.argv[1], encoding='utf-8', newline='') as handle:
    for row in csv.DictReader(handle):
        print('\t'.join([ascii_name(row['GivenName']), ascii_name(row['Surname']), row['Format'], row['Attempt'], row['Expected']]))
PY
    )
    ((rows > 10))
}

@test 'config_check accepts the example configuration and the test fixture' {
    run config_check "$REPO_ROOT/config/onboarding.example.json"
    assert_success
    assert_output ''
    run config_check "$REPO_ROOT/tests/bats/fixtures/onboarding.json"
    assert_output ''
}

@test 'config_check lists every problem in a bad configuration' {
    cat >"$BATS_TEST_TMPDIR/bad.json" <<'EOF'
{
  "upnSuffix": "not a domain",
  "samAccountNameFormat": "last.first",
  "disabledOu": "Disabled",
  "defaultGroups": ["Bad,Group"],
  "departmens": {},
  "departments": { "X": { "ou": "Finance", "groups": ["Ok", "Bad:Group"] } }
}
EOF
    run config_check "$BATS_TEST_TMPDIR/bad.json"
    assert_line "Unknown setting 'departmens'."
    assert_line "'upnSuffix' must be a DNS domain name such as corp.example.com."
    assert_line "'samAccountNameFormat' must be 'first.last' or 'flast'."
    assert_line --partial "'disabledOu' must be a distinguished name"
    assert_line "Default group name 'Bad,Group' is not a valid group name."
    assert_line "Department 'X' has an invalid 'ou' distinguished name."
    assert_line "Department 'X' lists an invalid group name ('Bad:Group')."
    assert_equal "${#lines[@]}" 7
}

@test 'config_check reports an empty departments object and a non-object file' {
    printf '{"upnSuffix":"a.test","disabledOu":"OU=D,DC=a,DC=test","departments":{}}' >"$BATS_TEST_TMPDIR/empty.json"
    run config_check "$BATS_TEST_TMPDIR/empty.json"
    assert_output "'departments' must be an object with at least one department."
    printf '[1, 2]' >"$BATS_TEST_TMPDIR/array.json"
    run config_check "$BATS_TEST_TMPDIR/array.json"
    assert_output 'The configuration must be a JSON object.'
}

@test 'config_check rejects every shared invalid configuration (the Pester suite tests the same file)' {
    local count=0 case json message
    while IFS=$'\t' read -r case json _ message; do
        [[ -n $case && $case != '#'* ]] || continue
        printf '%s' "$json" >"$BATS_TEST_TMPDIR/case.json"
        run config_check "$BATS_TEST_TMPDIR/case.json"
        assert_success
        assert_line "$message"
        count=$((count + 1))
    done <"$REPO_ROOT/tests/fixtures/invalid-configs.tsv"
    ((count > 5))
}

@test 'config_department matches without regard to case and config_groups removes duplicates' {
    run config_department "$REPO_ROOT/tests/bats/fixtures/onboarding.json" 'finance'
    assert_output "Finance${ITO_US}OU=Finance,OU=Staff,DC=corp,DC=itops,DC=test"
    run config_department "$REPO_ROOT/tests/bats/fixtures/onboarding.json" 'Marketing'
    assert_output ''
    run config_groups "$REPO_ROOT/tests/bats/fixtures/onboarding.json" 'FINANCE'
    assert_output $'All-Staff\nFinance-Users'
}

@test 'directory_base_dn reads the rootDSE' {
    LDAP_URL=ldap://dc AUTH_FILE=/dev/null run directory_base_dn
    assert_output 'DC=corp,DC=itops,DC=test'
}

# hrfeed.py

hrfeed() {
    python3 "$REPO_ROOT/linux/lib/hrfeed.py" "$@"
}

@test 'hrfeed reads BOM-prefixed, quoted CSV and normalises names' {
    printf '\xef\xbb\xbfEmployeeId,GivenName,Surname,Department,Title,Manager,StartDate\r\nE1,José,"García-López",IT,"Analyst, Service Desk",lina.haddad,2026-10-12\r\n' >"$BATS_TEST_TMPDIR/feed.csv"
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_success
    IFS=$'\x1f' read -r -a fields <<<"$output"
    assert_equal "${fields[0]}" 1
    assert_equal "${fields[1]}" E1
    assert_equal "${fields[3]}" 'García-López'
    assert_equal "${fields[5]}" 'Analyst, Service Desk'
    assert_equal "${fields[6]}" lina.haddad
    assert_equal "${fields[8]}" jose
    assert_equal "${fields[9]}" garcialopez
    assert_equal "${#fields[@]}" 10
}

@test 'hrfeed keeps empty fields in place' {
    printf 'EmployeeId,GivenName,Surname,Department,Title,Manager,StartDate\nE1,Sara,Ali,Finance,,,\n' >"$BATS_TEST_TMPDIR/feed.csv"
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    IFS=$'\x1f' read -r _ _ _ _ department title _ _ given_ascii surname_ascii problems <<<"$output"
    assert_equal "$department" Finance
    assert_equal "$title" ''
    assert_equal "$given_ascii" sara
    assert_equal "$surname_ascii" ali
    assert_equal "$problems" ''
}

@test 'hrfeed explains each invalid row' {
    cat >"$BATS_TEST_TMPDIR/feed.csv" <<'EOF'
EmployeeId,GivenName,Surname,Department,Title,Manager,StartDate
E 1,Sara,Ali,Finance,,,
E2,,Ali,Finance,,,
E3,"Smith, John",Doe,Finance,,,
E4,سارة,Ali,Finance,,,
E5,Sara,Ali,,,,
E6,Sara,Ali,Finance,,Lina Haddad,
E7,Sara,Ali,Finance,,,05/10/2026
E8,Sara,Ali,Finance,,,
E8,Sara,Ali,Finance,,,
E9,Anastasia-Konstantina,Montgomery-Smithson-Fitzwilliam-Worthington,Finance,,,
EOF
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_success
    assert_line --index 0 --partial "EmployeeId 'E 1' must be 1-16 letters, digits or hyphens."
    assert_line --index 1 --partial 'GivenName is required.'
    assert_line --index 2 --partial "GivenName 'Smith, John' contains characters that are not allowed in a name."
    assert_line --index 3 --partial 'has no letters that can be used in an account name. Add a Latin-script spelling to the HR record.'
    assert_line --index 4 --partial 'Department is required.'
    assert_line --index 5 --partial "Manager 'Lina Haddad' must be the manager's account name (sAMAccountName)."
    assert_line --index 6 --partial "StartDate '05/10/2026' must use the format yyyy-MM-dd."
    [[ ${lines[7]} != *"appears more than once"* ]]
    assert_line --index 8 --partial "EmployeeId 'E8' appears more than once in this feed."
    assert_line --index 9 --partial "The full name 'Anastasia-Konstantina Montgomery-Smithson-Fitzwilliam-Worthington' is 65 characters long. Active Directory limits the common name (CN) to 64 characters, so shorten the name in the HR record."
}

@test 'hrfeed applies the shared row rules that the Pester suite also tests' {
    # tests/fixtures/feed-rows.csv holds rows and the exact problems both toolkits must report.
    python3 - "$REPO_ROOT/tests/fixtures/feed-rows.csv" "$BATS_TEST_TMPDIR/feed.csv" "$BATS_TEST_TMPDIR/expected.txt" <<'PY'
import csv, sys
with open(sys.argv[1], encoding='utf-8', newline='') as source, \
        open(sys.argv[2], 'w', encoding='utf-8', newline='') as feed, \
        open(sys.argv[3], 'w', encoding='utf-8') as expected:
    writer = csv.writer(feed)
    writer.writerow(['EmployeeId', 'GivenName', 'Surname', 'Department', 'Title', 'Manager', 'StartDate'])
    for case in csv.DictReader(source):
        writer.writerow([case['EmployeeId'], case['GivenName'], case['Surname'], 'Finance', case['Title'], case['Manager'], case['StartDate']])
        print(case['Case'] + '\t' + case['Problem'], file=expected)
PY
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_success
    local -a cases
    mapfile -t cases <"$BATS_TEST_TMPDIR/expected.txt"
    assert_equal "${#lines[@]}" "${#cases[@]}"
    local i name problem
    for i in "${!cases[@]}"; do
        name=${cases[i]%%$'\t'*}
        problem=${cases[i]#*$'\t'}
        # The problems are the last field of each output line.
        if [[ ${lines[i]##*$'\x1f'} != "$problem" ]]; then
            fail "Case '$name': expected problems '$problem', got '${lines[i]##*$'\x1f'}'"
        fi
    done
    ((${#cases[@]} > 10))
}

@test 'hrfeed reads column headers without regard to case, as New-ItoUser does' {
    printf 'employeeid,GIVENNAME,surname,Department\nE1,Sara,Ali,Finance\n' >"$BATS_TEST_TMPDIR/feed.csv"
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_success
    IFS=$'\x1f' read -r -a fields <<<"$output"
    assert_equal "${fields[1]}" E1
    assert_equal "${fields[2]}" Sara
    assert_equal "${fields[8]}" sara
    assert_equal "${fields[9]}" ali
}

@test 'hrfeed rejects a feed without the required columns' {
    printf 'EmployeeId,FirstName,LastName,Department\nE1,Sara,Ali,Finance\n' >"$BATS_TEST_TMPDIR/feed.csv"
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_failure 2
    assert_output --partial 'is missing required columns: GivenName, Surname.'
}

@test 'hrfeed reports a file it cannot read' {
    run hrfeed "$BATS_TEST_TMPDIR/missing.csv"
    assert_failure 2
    assert_output --partial "Could not read the HR feed '$BATS_TEST_TMPDIR/missing.csv'"
    printf 'EmployeeId,GivenName\n\xff\xfe\n' >"$BATS_TEST_TMPDIR/latin1.csv"
    run hrfeed "$BATS_TEST_TMPDIR/latin1.csv"
    assert_failure 2
}

@test 'hrfeed replaces control characters so a row cannot break the output format' {
    printf 'EmployeeId,GivenName,Surname,Department,Title,Manager,StartDate\nE1,Sara,Ali,"Fin\x1fance","Line one\nline two",,\n' >"$BATS_TEST_TMPDIR/feed.csv"
    run hrfeed "$BATS_TEST_TMPDIR/feed.csv"
    assert_equal "${#lines[@]}" 1
    IFS=$'\x1f' read -r -a fields <<<"$output"
    assert_equal "${#fields[@]}" 11
    assert_equal "${fields[4]}" 'Fin ance'
    assert_line --partial 'Department must not contain control characters.'
}
