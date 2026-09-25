#!/usr/bin/env python3
"""Read an HR feed CSV and print one line per row for onboard-user.sh.

Bash has no reliable CSV parser, and samba-tool already needs Python 3, so this helper does
the parsing, the field checks and the ASCII name normalisation. The rules match the
PowerShell module (Test-ItoOnboardingRecord and ConvertTo-ItoAsciiName), and both are tested
against tests/fixtures/account-names.csv.

Fields are separated by the ASCII unit separator (0x1F). A tab would not work: bash's read
treats runs of tabs as one separator, so empty fields would disappear.

Output columns, in input order:

    row, EmployeeId, GivenName, Surname, Department, Title, Manager, StartDate,
    given_ascii, surname_ascii, problems

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
EMPLOYEE_ID = re.compile(r"^[A-Za-z0-9-]{1,16}$")
ACCOUNT_NAME = re.compile(r"^[A-Za-z0-9._-]{1,20}$")
NAME_PUNCTUATION = frozenset(" .'-’")
SEPARATOR = "\x1f"


def ascii_name(name: str) -> str:
    """Lower-case ASCII letters and digits of a name, after Unicode NFKD decomposition."""
    decomposed = unicodedata.normalize("NFKD", name)
    return "".join(ch.lower() for ch in decomposed if ch.isascii() and ch.isalnum())


def is_person_name(name: str) -> bool:
    """Letters, combining marks, spaces, full stops, hyphens and apostrophes; 1-64 characters."""
    if not 1 <= len(name) <= 64:
        return False
    if not unicodedata.category(name[0]).startswith("L"):
        return False
    for ch in name[1:]:
        category = unicodedata.category(ch)
        if not (category[0] in "LM" or ch in NAME_PUNCTUATION):
            return False
    last = name[-1]
    return unicodedata.category(last)[0] in "LM" or last == "."


def has_control_characters(value: str) -> bool:
    return any(unicodedata.category(ch) == "Cc" for ch in value)


def row_problems(row: dict[str, str], seen_ids: set[str]) -> list[str]:
    """Return the problems with one row. An empty list means the row is valid."""
    problems: list[str] = []
    employee_id = row["EmployeeId"]
    if not employee_id:
        problems.append("EmployeeId is required.")
    elif not EMPLOYEE_ID.match(employee_id):
        problems.append(f"EmployeeId '{employee_id}' must be 1-16 letters, digits or hyphens.")

    for field in ("GivenName", "Surname"):
        value = row[field]
        if not value:
            problems.append(f"{field} is required.")
        elif not is_person_name(value):
            problems.append(f"{field} '{value}' contains characters that are not allowed in a name.")
        elif not ascii_name(value):
            problems.append(
                f"{field} '{value}' has no letters that can be used in an account name. "
                "Add a Latin-script spelling to the HR record."
            )

    if not row["Department"]:
        problems.append("Department is required.")
    elif has_control_characters(row["Department"]):
        problems.append("Department must not contain control characters.")

    title = row["Title"]
    if len(title) > 64 or has_control_characters(title):
        problems.append("Title must be at most 64 characters with no control characters.")

    manager = row["Manager"]
    if manager and not ACCOUNT_NAME.match(manager):
        problems.append(f"Manager '{manager}' must be the manager's account name (sAMAccountName).")

    start_date = row["StartDate"]
    if start_date:
        try:
            datetime.datetime.strptime(start_date, "%Y-%m-%d")
        except ValueError:
            problems.append(f"StartDate '{start_date}' must use the format yyyy-MM-dd.")

    if not problems:
        key = employee_id.lower()
        if key in seen_ids:
            problems.append(f"EmployeeId '{employee_id}' appears more than once in this feed.")
        seen_ids.add(key)
    return problems


def convert(rows: Iterable[dict[str, str | None]]) -> Iterable[str]:
    seen_ids: set[str] = set()
    for number, raw in enumerate(rows, start=1):
        row = {
            column: (raw.get(column) or "").strip()
            for column in REQUIRED_COLUMNS + OPTIONAL_COLUMNS
        }
        problems = row_problems(row, seen_ids)
        fields = [str(number)]
        fields += [row[column] for column in REQUIRED_COLUMNS]
        fields += [row[column] for column in OPTIONAL_COLUMNS]
        fields += [ascii_name(row["GivenName"]), ascii_name(row["Surname"])]
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
            columns = reader.fieldnames or []
            missing = [column for column in REQUIRED_COLUMNS if column not in columns]
            if missing:
                expected = ", ".join(REQUIRED_COLUMNS + OPTIONAL_COLUMNS)
                print(
                    f"The HR feed '{args.csv_file}' is missing required columns: "
                    f"{', '.join(missing)}. Expected columns: {expected}.",
                    file=sys.stderr,
                )
                return 2
            for line in convert(reader):
                print(line)
    except (OSError, UnicodeDecodeError, csv.Error) as error:
        print(f"Could not read the HR feed '{args.csv_file}': {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
