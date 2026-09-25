# Prints one line per problem in the onboarding configuration, nothing when it is valid.
# The rules match Read-ItoOnboardingConfig in the PowerShell module.

def dn: type == "string" and test("^(?:(?:OU|CN)=[^,=]+,)+(?:DC=[A-Za-z0-9-]+,)*DC=[A-Za-z0-9-]+$");
def group: type == "string" and test("^[^\"/\\\\\\[\\]:;|=,+*?<>]{1,64}$");
def dns: type == "string" and test("^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}$");

if type != "object" then "The configuration must be a JSON object." else
    (keys[] | select(startswith("$") | not)
        | select(IN("upnSuffix", "samAccountNameFormat", "disabledOu", "defaultGroups", "departments") | not)
        | "Unknown setting '\(.)'."),
    (if (.upnSuffix | dns) then empty
     else "'upnSuffix' must be a DNS domain name such as corp.example.com." end),
    (if has("samAccountNameFormat") and ((.samAccountNameFormat | IN("first.last", "flast")) | not)
     then "'samAccountNameFormat' must be 'first.last' or 'flast'." else empty end),
    (if (.disabledOu | dn) then empty
     else "'disabledOu' must be a distinguished name such as OU=Disabled Users,DC=corp,DC=example,DC=com." end),
    ((.defaultGroups // [])[] | select(group | not) | "Default group name '\(.)' is not a valid group name."),
    (if (.departments | type) != "object" or (.departments | length) == 0
     then "'departments' must be an object with at least one department."
     else (.departments | to_entries[]
        | (if (.value.ou | dn) then empty else "Department '\(.key)' has an invalid 'ou' distinguished name." end),
          (.key as $department | (.value.groups // [])[] | select(group | not)
            | "Department '\($department)' lists an invalid group name ('\(.)')."))
     end)
end
