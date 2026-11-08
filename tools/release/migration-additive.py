#!/usr/bin/env python3
"""Check D1 migrations are additive: they may create tables, indexes, triggers and views, add
columns and insert rows; nothing that drops, rewrites, renames or deletes existing data.

    migration-additive.py Service/migrations/0027_x.sql ...

Prints each statement that is not additive and exits 1 when there is any. A migration that must
remove or rewrite data is a deliberate, reviewed step of its own, not part of a routine deploy.
"""
import re
import sys

ALLOWED = [
    r"CREATE\s+(TEMP\s+|TEMPORARY\s+)?TABLE\b",
    r"CREATE\s+(UNIQUE\s+)?INDEX\b",
    r"CREATE\s+TRIGGER\b",
    r"CREATE\s+VIEW\b",
    r"ALTER\s+TABLE\s+\S+\s+ADD\s+(COLUMN\s+)?",
    r"INSERT\s+(OR\s+IGNORE\s+)?INTO\b",
    r"BEGIN(\s+TRANSACTION)?$", r"COMMIT$", r"END$",
]


def statements(sql):
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    depth, current, out = 0, [], []
    # Triggers contain semicolons inside BEGIN ... END; keep them as one statement.
    for part in re.split(r"(;)", sql):
        current.append(part)
        text = "".join(current)
        if part == ";":
            depth = len(re.findall(r"\bBEGIN\b", text, re.I)) - len(re.findall(r"\bEND\b", text, re.I))
            if not re.match(r"\s*CREATE\s+TRIGGER", text, re.I) or depth <= 0:
                out.append(text.strip().rstrip(";").strip())
                current = []
    tail = "".join(current).strip()
    if tail:
        out.append(tail)
    return [s for s in out if s]


def main(paths):
    bad = 0
    for path in paths:
        for statement in statements(open(path, encoding="utf-8").read()):
            flat = " ".join(statement.split())
            if not any(re.match(pattern, flat, re.I) for pattern in ALLOWED):
                print(f"{path}: not additive: {flat[:160]}")
                bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
