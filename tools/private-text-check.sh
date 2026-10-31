#!/bin/zsh
# Text that must not go public. Every line of ~/.config/banana/public-export.deny (one extended
# regex per line: the team id, device ids, private addresses and names) is searched for in text
# files, after the public literals of ~/.config/banana/public-export.allow (one per line, such as
# the support address) are taken out of each line.
#
#   tools/private-text-check.sh <folder>          the text files under a folder (an export)
#   tools/private-text-check.sh --commit <rev>    the files of a commit, as git holds them
#   tools/private-text-check.sh --changes <rev>   only the files that commit adds, changes or renames
#                                                 against its first parent (all of them for a root)
#
# Prints path:line:text for each hit (the first 200) and exits 1; exits 0 when nothing was found;
# exits 2 when the deny list is missing, so that a caller never takes "unchecked" for "clean".
#
# The hits are collected whole, then shown: a `head` inside a condition made grep die of SIGPIPE
# past 200 hits, pipefail turned that into "no hits", and 262 files of private text went into an
# export (30 Oct 2026).
set -uo pipefail
DENY="${BANANA_EXPORT_DENY:-$HOME/.config/banana/public-export.deny}"
ALLOW="${BANANA_EXPORT_ALLOW:-$HOME/.config/banana/public-export.allow}"
[[ -f "$DENY" ]] || { echo "No $DENY: nothing was checked for private text." >&2; exit 2; }
PATTERNS="$(grep -v '^#' "$DENY" | grep . || true)"
[[ -n "$PATTERNS" ]] || { echo "$DENY holds no patterns: nothing was checked for private text." >&2; exit 2; }
ALLOW_SED=""
[[ -f "$ALLOW" ]] && ALLOW_SED="$(grep -v '^#' "$ALLOW" | grep . | sed -e 's/[][\.*^$/]/\\&/g' -e 's#.*#s/&//g#' || true)"

SCRATCH=""
cleanup() { [[ -n "$SCRATCH" ]] && rm -rf "$SCRATCH"; }
trap cleanup EXIT
if [[ "${1:-}" == --commit || "${1:-}" == --changes ]]; then
    REV="${2:?usage: tools/private-text-check.sh --commit|--changes <rev>}"
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/private-text-check.XXXXXX")"
    PATHS=()
    if [[ "$1" == --changes ]] && git rev-parse -q --verify "$REV^" >/dev/null 2>&1; then
        PATHS=("${(@0)$(git diff-tree -z -r --no-commit-id --diff-filter=AMRC --name-only "$REV^" "$REV")}")
        PATHS=("${(@)PATHS:#}")
        [[ ${#PATHS} -gt 0 ]] || exit 0
    fi
    git archive "$REV" -- "${PATHS[@]}" | tar -x -C "$SCRATCH" || { echo "Could not read the files of $REV." >&2; exit 2; }
    DIR="$SCRATCH"
else
    DIR="${1:?usage: tools/private-text-check.sh <folder> | --commit <rev>}"
    [[ -d "$DIR" ]] || { echo "$DIR is not a folder." >&2; exit 2; }
fi

# Candidate lines first, then the allowed literals removed, then matched again: a line whose only
# hit is an allowed literal drops out, a line with private text beside one stays. ripgrep is used
# when installed: the same hits as the system grep on a leaky tree (2502 lines, checked line for
# line), in 6 s where the system grep takes 90 s over the retained trace XML (30 Oct 2026).
# BANANA_CHECK_ENGINE=grep forces the system grep.
PATTERN_FILE="$(mktemp "${TMPDIR:-/tmp}/private-text-patterns.XXXXXX")"
print -r -- "$PATTERNS" > "$PATTERN_FILE"
if [[ "${BANANA_CHECK_ENGINE:-}" != grep ]] && command -v rg >/dev/null 2>&1; then
    search() { rg -n --no-ignore --hidden --no-messages -g '!.git' -f "$PATTERN_FILE" .; }
    rematch() { rg -f "$PATTERN_FILE"; }
else
    search() { LC_ALL=C grep -rIEn --exclude-dir=.git -f "$PATTERN_FILE" .; }
    rematch() { LC_ALL=C grep -E -f "$PATTERN_FILE"; }
fi
CANDIDATES="$(cd "$DIR" && search | sed 's#^\./##' || true)"
HITS=""
if [[ -n "$CANDIDATES" ]]; then
    HITS="$(print -r -- "$CANDIDATES" | sed -f <(print -r -- "$ALLOW_SED") | rematch | cut -c1-200 || true)"
fi
rm -f "$PATTERN_FILE"
if [[ -n "$HITS" ]]; then
    print -r -- "$HITS" | head -200
    echo "$(print -r -- "$HITS" | wc -l | tr -d ' ') lines in $(print -r -- "$HITS" | cut -d: -f1 | sort -u | wc -l | tr -d ' ') files hold private text (first 200 shown)." >&2
    exit 1
fi
exit 0
