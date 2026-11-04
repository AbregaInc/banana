#!/bin/bash
# Builds the Python runtime Banana Pi for Mac carries inside the app: a relocatable CPython
# (python-build-standalone, via uv), Locals at its reviewed commit and the pinned packages
# (requirements.lock.txt). Nothing is installed on the Mac outside the app.
#
#   tools/pi-mac-inference/build-runtime.sh        # prints the runtime folder, building it if needed
#
# The result is cached by a hash of everything pinned below, in ~/Library/Caches (shared by every
# worktree, survives tools/clean-builds.sh), and only the current one is kept. The Pi Mac build
# (project.yml, BananaMacBeta, PiDevelopment) copies it into Contents/Resources/PiRuntime and signs
# its binaries. See docs/design/PI-LOCAL-MODEL.md.
set -euo pipefail
# The embed caller keeps this lock until its copy is complete. Standalone builds take it too.
if [ "${BANANA_RUNTIME_CACHE_LOCKED:-}" != 1 ]; then
  exec /usr/bin/python3 "$(dirname "$0")/runtime-cache-lock.py" /bin/bash "$0" "$@"
fi
here="$(cd "$(dirname "$0")" && pwd)"
PYTHON_VERSION=3.13.13
LOCALS_REPO=https://github.com/Generated-Computers/Locals
LOCALS_COMMIT=4f4d03f10232c9f2adeb1e96e2a7bd79a9e7fe19

uv=$(command -v uv || true)
[ -z "$uv" ] && [ -x /opt/homebrew/bin/uv ] && uv=/opt/homebrew/bin/uv
[ -z "$uv" ] && [ -x "$HOME/.local/bin/uv" ] && uv="$HOME/.local/bin/uv"
[ -z "$uv" ] && { echo "error: build-runtime needs uv (https://docs.astral.sh/uv/)" >&2; exit 1; }

key=$( { echo "$PYTHON_VERSION $LOCALS_COMMIT"; cat "$here/requirements.lock.txt" "$0"; } | shasum -a 256 | cut -c1-16)
cache="$HOME/Library/Caches/Banana Pi build/pi-runtime"
out="$cache/$key"
if [ -x "$out/python/bin/python3" ] && [ -e "$out/.complete" ]; then echo "$out"; exit 0; fi

echo "Building Banana Pi's Python runtime ($key)…" >&2
mkdir -p "$cache"
work=$(mktemp -d "$cache/.work.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1. A standalone CPython, copied whole so it lives in the app, not where uv keeps it.
"$uv" python install "$PYTHON_VERSION" >&2
base=$("$uv" python find --no-project --managed-python "$PYTHON_VERSION")
base=$(cd "$(dirname "$base")/.." && pwd -P)
ditto "$base" "$work/python"
rm -f "$work"/python/lib/python3.13/EXTERNALLY-MANAGED
py="$work/python/bin/python3"

# 2. Locals at the reviewed commit, and the pinned packages.
git clone --quiet --filter=blob:none --no-checkout "$LOCALS_REPO" "$work/locals" >&2
git -C "$work/locals" checkout --quiet --detach "$LOCALS_COMMIT"
[ "$(git -C "$work/locals" rev-parse HEAD)" = "$LOCALS_COMMIT" ] || { echo "error: Locals is not at $LOCALS_COMMIT" >&2; exit 1; }
"$uv" pip install --quiet --python "$py" --no-cache -r "$here/requirements.lock.txt" >&2
"$uv" pip install --quiet --python "$py" --no-cache --no-deps "$work/locals" >&2
mkdir -p "$work/python/share/licenses"
cp "$work/locals/LICENSE" "$work/python/share/licenses/Locals-LICENSE.txt"
rm -rf "$work/locals"

# 2b. Every bundled package's own licence text, for Settings › Assistant licences.
"$py" -I - "$work/python" <<'PY'
import importlib.metadata as md, pathlib, sys
root = pathlib.Path(sys.argv[1]); out = ["Banana Pi for Mac: bundled Python runtime notices", ""]
lic = next(iter(root.glob("lib/python3.13/LICENSE.txt")), None)
if lic: out += ["Python 3.13", "", lic.read_text(errors="replace"), ""]
loc = root / "share/licenses/Locals-LICENSE.txt"
for dist in sorted(md.distributions(path=[str(root / "lib/python3.13/site-packages")]), key=lambda d: d.metadata["Name"].lower()):
    name, version = dist.metadata["Name"], dist.version
    texts = [f for f in (dist.files or []) if "licen" in str(f).lower() or "copying" in str(f).lower() or "notice" in str(f).lower()]
    body = "\n\n".join(pathlib.Path(dist.locate_file(f)).read_text(errors="replace") for f in texts if pathlib.Path(dist.locate_file(f)).is_file())
    if not body and name.lower() == "locals" and loc.exists(): body = loc.read_text()
    out += [f"{name} {version}", f"Licence: {dist.metadata.get('License-Expression') or dist.metadata.get('License') or 'see text'}", "", body or "(no licence file shipped by this package)", ""]
(root / "share/licenses/NOTICES.txt").write_text("\n".join(out))
PY

# 3. Only what runs: no tests, Tk, IDLE, headers, pip or caches.
p="$work/python/lib/python3.13"
rm -rf "$p/test" "$p/idlelib" "$p/tkinter" "$p/turtledemo" "$p/ensurepip" "$p/lib2to3" \
       "$p"/site-packages/pip "$p"/site-packages/pip-* \
       "$work/python/include" "$work/python/share/man" "$work"/python/lib/libtcl* "$work"/python/lib/libtk* \
       "$work"/python/lib/tcl* "$work"/python/lib/tk* "$work"/python/lib/itcl* "$work"/python/lib/thread*
find "$work/python" -type d \( -name __pycache__ -o -name tests -o -name test \) -prune -exec rm -rf {} +
find "$work/python" -name "*.a" -delete

# 4. Compiled once here, checked by hash rather than file time, so the app never writes inside itself.
"$py" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$work/python/lib" >&2 || true

# 5. It must start Locals with nothing but itself.
env -i HOME="$HOME" PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 "$py" -I -c \
  "import locals.server, mlx.core, mlx_lm, transformers, llguidance; print('runtime ok')" >&2

touch "$work/.complete"
rm -rf "$out"
mv "$work" "$out"
trap - EXIT
# Keep only the current runtime.
find "$cache" -mindepth 1 -maxdepth 1 ! -name "$key" -exec rm -rf {} +
echo "$out"
