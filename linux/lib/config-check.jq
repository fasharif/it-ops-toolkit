# Prints one line per problem in the onboarding configuration, nothing when it is valid.
# The rules match Read-ItoOnboardingConfig in the PowerShell module and
# config/onboarding.schema.json. Like the schema, they are case-sensitive: setting names,
# samAccountNameFormat and the OU=, CN= and DC= parts of distinguished names must be written
# exactly as shown.

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
     else "'disabledOu' must be a distinguished name such as OU=Disabled Users,DC=corp,DC=example,DC=com, with OU=, CN= and DC= in capitals." end),
    (.defaultGroups
        | if . == null then empty
          elif type != "array" then "'defaultGroups' must be a list of group names."
          else .[] | select(group | not) | "Default group name '\(.)' is not a valid group name." end),
    (if (.departments | type) != "object" or (.departments | length) == 0
     then "'departments' must be an object with at least one department."
     else (.departments | to_entries[] | .key as $department | .value
        | if type != "object" then "Department '\($department)' must be an object with 'ou' and 'groups'."
          else
            (keys[] | select(IN("ou", "groups") | not)
                | "Department '\($department)' has an unknown setting '\(.)'. Known settings: ou, groups."),
            (if (.ou | dn) then empty else "Department '\($department)' has an invalid 'ou' distinguished name." end),
            (.groups
                | if . == null then empty
                  elif type != "array" then "Department '\($department)' has a 'groups' setting that is not a list of group names."
                  else .[] | select(group | not) | "Department '\($department)' lists an invalid group name ('\(.)')." end)
          end)
     end)
end
