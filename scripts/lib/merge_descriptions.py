"""Merge a model's column descriptions into its BigQuery schema JSON.

Reads the table's current schema on stdin (`bq show --schema`), reads the
ALTER COLUMN statements out of the model's SQL, and writes the same schema
back on stdout with a description on every column the model describes.

This exists to make it ONE metadata operation instead of one per column.
BigQuery caps table metadata updates at 5 per 10 seconds per table, and the
models here carry 7 to 26 descriptions; issuing them as separate ALTERs meant
pacing around that cap, which failed three times in three different ways —
each failure leaving the table rebuilt and correct with its descriptions half
applied. `bq update --schema` sets them all at once, so the cap stops being
something to stay under and the pauses go away with it.

A description naming a column the table does not have is an error, not a
no-op. The model SQL used to fail loudly on a renamed column because BigQuery
rejected the ALTER; that has to keep happening here or a rename would quietly
leave a column undescribed until 06-transform.sh's own check_described caught
it several minutes later, with no clue which model was at fault.
"""

import json
import re
import sys

# The same layout pipelines/tests/test_sql_marts_described.py enforces:
# ALTER TABLE <ds>.<table> ALTER COLUMN <col>\n  SET OPTIONS (description = "...");
_ALTER = re.compile(
    r'^ALTER TABLE (?:\w+)\.(?:\w+) ALTER COLUMN (\w+)\n'
    r'  SET OPTIONS \(description = "([^"]*)"\);$',
    re.M)


def descriptions(sql):
    return {m.group(1): m.group(2) for m in _ALTER.finditer(sql)}


def apply(fields, wanted):
    """Set descriptions on `fields` in place; return the names not found.

    Only top-level columns are described in this repo, but nested RECORD
    fields are walked anyway so a future nested column is described rather
    than silently reported missing.
    """
    for field in fields:
        name = field.get("name")
        if name in wanted:
            field["description"] = wanted.pop(name)
        if field.get("fields"):
            apply(field["fields"], wanted)
    return wanted


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: merge_descriptions.py <model.sql>  < schema.json")
    with open(sys.argv[1]) as handle:
        wanted = descriptions(handle.read())
    if not wanted:
        sys.exit(f"{sys.argv[1]}: no column descriptions found")

    schema = json.load(sys.stdin)
    # `bq show --schema --format=prettyjson` emits the bare field list; accept
    # the wrapped form too in case that ever changes.
    fields = schema["schema"]["fields"] if isinstance(schema, dict) else schema

    missing = apply(fields, dict(wanted))
    if missing:
        sys.exit(f"{sys.argv[1]}: describes columns the table does not have: "
                 + ", ".join(sorted(missing)))

    json.dump(fields, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
