#!/bin/zsh
# The public tree: the last commit's files without the private ones (tools/public-export.exclude).
# Nothing is pushed.
#
#   tools/public-export.sh <empty or new folder>     a new repository with one commit
#   tools/public-export.sh <clone of the public one> one more commit on top: this version
#
# It stops, and leaves the folder for reading, when the tree still holds something that must not
# go out (tools/private-text-check.sh: the deny list in ~/.config/banana).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: tools/public-export.sh <folder>}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash first: the export is of the last commit." >&2; exit 1; }
mkdir -p "$OUT"
UPDATE=""
if [[ -e "$OUT/.git" ]]; then
    # A clone of the public repository: its files are replaced by this commit's. Never the
    # private repository itself, which is the only one that holds the private files.
    UPDATE=1
    grep -v '^#' tools/public-export.exclude | while read -r entry; do
        [[ -z "$entry" || ! -e "$OUT/$entry" ]] || { echo "$OUT holds $entry: it is not the public repository." >&2; exit 1; }
    done
    [[ -z "$(git -C "$OUT" status --porcelain)" ]] || { echo "$OUT has changes of its own." >&2; exit 1; }
    find "$OUT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
else
    [[ -z "$(ls -A "$OUT")" ]] || { echo "$OUT is not empty." >&2; exit 1; }
fi

git archive HEAD | tar -x -C "$OUT"
grep -v '^#' tools/public-export.exclude | while read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ -e "$OUT/$entry" ]] || { echo "tools/public-export.exclude names $entry, which is not in the tree." >&2; exit 1; }
    rm -rf "$OUT/$entry"
done

tools/private-text-check.sh "$OUT" || { echo "Fix them or keep the file out of the tree, then export again." >&2; exit 1; }

# The public commit's name and address are said outright: a new repository would otherwise take
# whatever this Mac's global git identity is.
[[ -f "$HOME/.config/banana/release.env" ]] && source "$HOME/.config/banana/release.env"
SOURCE="$(git rev-parse --short HEAD)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1) ($(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml | head -1))"
cd "$OUT"
[[ -n "$UPDATE" ]] || git init -q -b main
git add -A
if [[ -z "${BANANA_PUBLIC_NAME:-}" || -z "${BANANA_PUBLIC_EMAIL:-}" ]]; then
    echo "$OUT is ready and not committed: set BANANA_PUBLIC_NAME and BANANA_PUBLIC_EMAIL (~/.config/banana/release.env) for the public commit." >&2
    exit 1
fi
if [[ -n "$UPDATE" && -z "$(git status --porcelain)" ]]; then
    echo "$OUT already holds this commit's files: nothing to add."
    exit 0
fi
git -c user.name="$BANANA_PUBLIC_NAME" -c user.email="$BANANA_PUBLIC_EMAIL" \
    commit -q -m "Banana $VERSION" -m "Exported from the author's repository at $SOURCE."
echo "$OUT: $(git ls-files | wc -l | tr -d ' ') files, commit $(git rev-list --count HEAD) by $(git log -1 --format='%an <%ae>'): $(git log -1 --format=%s)."
