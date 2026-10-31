#!/usr/bin/env python3
"""Replace private text in retained evidence (device identifiers, team ids, names, home paths).

    tools/redact-evidence.py --deny ~/.config/banana/public-export.deny docs/performance

Every text file under the given folders is rewritten in place: each match of a pattern from the
deny file (one extended regex per line, # comments) becomes <redacted>; absolute home paths
(/Users/<name>/…) become ~/…; Apple device UDIDs become <device-udid> whether or not the deny
file lists them. Binary files are left alone. The numbers in the evidence do not change; what
goes is who ran it, on which registered device, from which account.
"""
import argparse
from pathlib import Path
import re
import sys

UDID = re.compile(r'\b0000[0-9A-F]{4}-[0-9A-F]{16}\b')
HOME = re.compile(r'/Users/[A-Za-z0-9._-]+/')


def patterns(deny_file):
    if deny_file is None:
        return []
    lines = Path(deny_file).read_text().splitlines()
    return [re.compile(line) for line in lines if line.strip() and not line.startswith('#')]


def redact(text, deny):
    text = UDID.sub('<device-udid>', text)
    text = HOME.sub('~/', text)
    for pattern in deny:
        text = pattern.sub('<redacted>', text)
    return text


def redact_tree(roots, deny):
    changed = []
    for root in roots:
        for path in sorted(p for p in Path(root).rglob('*') if p.is_file()):
            try:
                original = path.read_text(encoding='utf-8')
            except (UnicodeDecodeError, OSError):
                continue
            result = redact(original, deny)
            if result != original:
                path.write_text(result, encoding='utf-8')
                changed.append(path)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('roots', nargs='+', type=Path)
    parser.add_argument('--deny', type=Path, help='extended regexes, one per line, # comments; same file as tools/public-export.sh uses')
    args = parser.parse_args()
    changed = redact_tree(args.roots, patterns(args.deny))
    for path in changed:
        print(path)
    print(f'{len(changed)} files redacted', file=sys.stderr)


if __name__ == '__main__':
    main()
