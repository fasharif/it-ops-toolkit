#!/usr/bin/env python3
"""Read an HR feed CSV and print one line per row for onboard-user.sh.

Bash has no reliable CSV parser, and samba-tool already needs Python 3, so this helper does
the parsing, the field checks and the ASCII name normalisation. The rules match the
PowerShell module (Test-ItoOnboardingRecord and ConvertTo-ItoAsciiName), and both are tested
against tests/fixtures/account-names.csv and tests/fixtures/feed-rows.csv.

Fields are separated by the ASCII unit separator (0x1F). A tab would not work: bash's read
treats runs of tabs as one separator, so empty fields would disappear.

Output columns, in input order:

    row, EmployeeId, GivenName, Surname, Department, Title, Manager, StartDate,
    given_ascii, surname_ascii, problems

The optional GivenNameLatin and SurnameLatin columns hold a Latin-script spelling of a name
written in another script, such as Arabic. When present, given_ascii and surname_ascii (and so
the account name) come from them; GivenName and Surname keep the original spelling.

`problems` is empty for a valid row, otherwise the problems joined with a space. Department
names are checked by onboard-user.sh, which reads the JSON configuration.

Exit status: 0 when the file was read (even if some rows have problems), 2 when the file
cannot be read or required columns are missing.
"""

from __future__ import annotations

import argparse
import csv
import datetime
import re
import sys
import unicodedata
from collections.abc import Iterable, Sequence

REQUIRED_COLUMNS = ("EmployeeId", "GivenName", "Surname", "Department")
OPTIONAL_COLUMNS = ("Title", "Manager", "StartDate")
LATIN_COLUMNS = ("GivenNameLatin", "SurnameLatin")
ALL_COLUMNS = REQUIRED_COLUMNS + OPTIONAL_COLUMNS + LATIN_COLUMNS
EMPLOYEE_ID = re.compile(r"^[A-Za-z0-9-]{1,16}$")
ACCOUNT_NAME = re.compile(r"^[A-Za-z0-9._-]{1,20}$")
# Exactly yyyy-MM-dd in ASCII digits, as .NET's TryParseExact in the PowerShell module requires.
# strptime alone would also accept 2026-1-5.
START_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
NAME_PUNCTUATION = frozenset(" .'-\u2019")  # \u2019 is the typographic apostrophe
SEPARATOR = "\x1f"
# Latin letters that have no Unicode decomposition, with their usual ASCII spelling: sharp s
# (both cases), ae, oe, o with stroke, l with stroke, d with stroke, eth, thorn and dotless i.
# ConvertTo-ItoAsciiName in the PowerShell module has the same table.
TRANSLITERATION = str.maketrans(
    {
        "\u00df": "ss",
        "\u1e9e": "ss",
        "\u00e6": "ae",
        "\u00c6": "ae",
        "\u0153": "oe",
        "\u0152": "oe",
        "\u00f8": "o",
        "\u00d8": "o",
        "\u0142": "l",
        "\u0141": "l",
        "\u0111": "d",
        "\u0110": "d",
        "\u00f0": "d",
        "\u00d0": "d",
        "\u00fe": "th",
        "\u00de": "th",
        "\u0131": "i",
    }
)
MAX_NAME_LENGTH = 64
MAX_TITLE_LENGTH = 64
MAX_CN_LENGTH = 64  # the account's CN is "GivenName Surname"; Active Directory allows 64 characters


def ascii_name(name: str) -> str:
    """Lower-case ASCII letters and digits of a name.

    Letters without a Unicode decomposition are spelled first (TRANSLITERATION), then the name
    is decomposed (NFKD) and everything but ASCII letters and digits is dropped.
    """
    decomposed = unicodedata.normalize("NFKD", name.translate(TRANSLITERATION))
    return "".join(ch.lower() for ch in decomposed if ch.isascii() and ch.isalnum())


def is_person_name(name: str) -> bool:
    """Letters, combining marks, spaces, full stops, hyphens and apostrophes; 1-64 characters."""
    if not 1 <= len(name) <= MAX_NAME_LENGTH:
        return False
    if not unicodedata.category(name[0]).startswith("L"):
        return False
    for ch in name[1:]:
        category = unicodedata.category(ch)
        if not (category[0] in "LM" or ch in NAME_PUNCTUATION):
            return False
    last = name[-1]
    return unicodedata.category(last)[0] in "LM" or last == "."


def is_start_date(value: str) -> bool:
    """True for a real calendar date written exactly as yyyy-MM-dd."""
    if not START_DATE.fullmatch(value):
        return False
    try:
        datetime.datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return False
    return True


def has_control_characters(value: str) -> bool:
    return any(unicodedata.category(ch) == "Cc" for ch in value)


def employee_id_problems(employee_id: str) -> list[str]:
    if not employee_id:
        return ["EmployeeId is required."]
    if not EMPLOYEE_ID.match(employee_id):
        return [f"EmployeeId '{employee_id}' must be 1-16 letters, digits or hyphens."]
    return []


def latin_problems(latin_field: str, latin: str) -> list[str]:
    """Problems with an optional Latin-script spelling (GivenNameLatin or SurnameLatin)."""
    if not is_person_name(latin):
        return [f"{latin_field} '{latin}' contains characters that are not allowed in a name."]
    if not ascii_name(latin):
        return [f"{latin_field} '{latin}' has no Latin letters that can be used in an account name."]
    return []


def name_problems(field: str, row: dict[str, str]) -> list[str]:
    """Problems with GivenName or Surname, and with its optional Latin-script spelling."""
    value = row[field]
    latin_field = field + "Latin"
    if not value:
        return [f"{field} is required."]
    if not is_person_name(value):
        return [f"{field} '{value}' contains characters that are not allowed in a name."]
    if row[latin_field]:
        return latin_problems(latin_field, row[latin_field])
    if not ascii_name(value):
        return [
            f"{field} '{value}' has no letters that can be used in an account name. "
            f"Add a Latin-script spelling in the {latin_field} column."
        ]
    return []


def account_name_part(field: str, row: dict[str, str]) -> str:
    """The ASCII name the account name is built from: the Latin spelling when there is one."""
    return ascii_name(row[field + "Latin"] or row[field])


def other_field_problems(row: dict[str, str]) -> list[str]:
    problems: list[str] = []
    if not row["Department"]:
        problems.append("Department is required.")
    elif has_control_characters(row["Department"]):
        problems.append("Department must not contain control characters.")

    title = row["Title"]
    if len(title) > MAX_TITLE_LENGTH or has_control_characters(title):
        problems.append(f"Title must be at most {MAX_TITLE_LENGTH} characters with no control characters.")

    manager = row["Manager"]
    if manager and not ACCOUNT_NAME.match(manager):
        problems.append(f"Manager '{manager}' must be the manager's account name (sAMAccountName).")

    start_date = row["StartDate"]
    if start_date and not is_start_date(start_date):
        problems.append(f"StartDate '{start_date}' must use the format yyyy-MM-dd.")
    return problems


def row_problems(row: dict[str, str], seen_ids: set[str]) -> list[str]:
    """Return the problems with one row. An empty list means the row is valid.

    A duplicate employee ID is only reported for a row that is otherwise valid, as in the
    PowerShell module, so the first valid occurrence is kept.
    """
    problems = employee_id_problems(row["EmployeeId"])
    given_problems = name_problems("GivenName", row)
    surname_problems = name_problems("Surname", row)
    problems += given_problems + surname_problems
    full_name = f"{row['GivenName']} {row['Surname']}"
    if not given_problems and not surname_problems and len(full_name) > MAX_CN_LENGTH:
        problems.append(
            f"The full name '{full_name}' is {len(full_name)} characters long. Active Directory limits "
            f"the common name (CN) to {MAX_CN_LENGTH} characters, so shorten the name in the HR record."
        )
    problems += other_field_problems(row)
    if not problems:
        key = row["EmployeeId"].lower()
        if key in seen_ids:
            problems.append(f"EmployeeId '{row['EmployeeId']}' appears more than once in this feed.")
        seen_ids.add(key)
    return problems


def header_map(fieldnames: Sequence[str]) -> dict[str, str]:
    """Map each known column to the header used in the file, matched without regard to case.

    New-ItoUser reads CSV columns the same way (PowerShell property names ignore case). When two
    headers differ only in case, the first one wins.
    """
    by_lower: dict[str, str] = {}
    for name in fieldnames:
        by_lower.setdefault(name.lower(), name)
    return {column: by_lower[column.lower()] for column in ALL_COLUMNS if column.lower() in by_lower}


def convert(rows: Iterable[dict[str, str | None]], headers: dict[str, str]) -> Iterable[str]:
    seen_ids: set[str] = set()
    for number, raw in enumerate(rows, start=1):
        row = {column: (raw.get(headers.get(column, column)) or "").strip() for column in ALL_COLUMNS}
        problems = row_problems(row, seen_ids)
        fields = [str(number)]
        fields += [row[column] for column in REQUIRED_COLUMNS]
        fields += [row[column] for column in OPTIONAL_COLUMNS]
        fields += [account_name_part("GivenName", row), account_name_part("Surname", row)]
        fields.append(" ".join(problems))
        # Control characters would break the output format; they are never valid in these fields.
        yield SEPARATOR.join(re.sub(r"[\x00-\x1f]", " ", field) for field in fields)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv_file", help="HR feed CSV (UTF-8, comma-separated, header row)")
    args = parser.parse_args(argv)

    try:
        with open(args.csv_file, encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            headers = header_map(reader.fieldnames or [])
            missing = [column for column in REQUIRED_COLUMNS if column not in headers]
            if missing:
                expected = ", ".join(ALL_COLUMNS)
                print(
                    f"The HR feed '{args.csv_file}' is missing required columns: "
                    f"{', '.join(missing)}. Expected columns: {expected}.",
                    file=sys.stderr,
                )
                return 2
            for line in convert(reader, headers):
                print(line)
    except (OSError, UnicodeDecodeError, csv.Error) as error:
        print(f"Could not read the HR feed '{args.csv_file}': {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
