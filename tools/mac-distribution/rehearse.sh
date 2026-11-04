#!/bin/bash
# Prepare two isolated local installers. Does not launch, install, or publish an app.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${BANANA_TEST_BASE_URL:?Set your Tailscale preview base URL, including /updates/test}"
: "${SPARKLE_BIN:?Set the Sparkle distribution bin directory}"
signing=(--test)
if [[ "${BANANA_ADHOC_TEST:-0}" != 1 ]]; then
  : "${BANANA_DEVELOPER_ID_IDENTITY:?Set Developer ID identity for a Gatekeeper-compatible installer}"
  if [[ -z "${BANANA_NOTARY_PROFILE:-}" ]] && [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    echo 'Set BANANA_NOTARY_PROFILE or the three ASC key environment variables for notarization.'
    exit 1
  fi
  signing+=(--notarize-test --identity "$BANANA_DEVELOPER_ID_IDENTITY")
fi
out=${BANANA_TEST_OUTPUT:-private/landing-download-preview/updates/test}
key=${BANANA_TEST_KEY_FILE:-$HOME/.config/banana/installer-test.ed25519}
if [[ -e "$out/1/Banana-Installer-Test-1.dmg" || -e "$out/2/Banana-Installer-Test-2.dmg" ]]; then
  echo 'Existing rehearsal installers are preserved. Choose a fresh output directory and URL.'
  exit 1
fi
mkdir -p private/mac-distribution
export BANANA_TEST_KEY_FILE="$key"
python3 - <<'PY'
import base64, os, pathlib, subprocess
path = pathlib.Path(os.environ['BANANA_TEST_KEY_FILE']).expanduser()
path.parent.mkdir(parents=True, exist_ok=True)
if not path.exists():
    raw = subprocess.check_output(['openssl','genpkey','-algorithm','ED25519','-outform','DER'])
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as out: out.write(base64.b64encode(raw[-32:]))
seed = base64.b64decode(path.read_bytes(), validate=True)
if len(seed) != 32: raise SystemExit('Expected a 32-byte test key seed')
der = bytes.fromhex('302e020100300506032b657004220420') + seed
public = subprocess.run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],
                        input=der, capture_output=True, check=True).stdout[-32:]
pathlib.Path('private/mac-distribution/test-public-key.txt').write_bytes(base64.b64encode(public))
PY
export BANANA_UPDATE_PUBLIC_KEY="$(cat private/mac-distribution/test-public-key.txt)"
export BANANA_UPDATE_FEED_URL="$BANANA_TEST_BASE_URL/appcast.xml"
tools/mac-distribution/build.sh test
for version in 1 2; do
  python3 tools/mac-distribution/package.py \
    '.build/mac-distribution/Build/Products/Release/Banana Installer Test.app' \
    "${signing[@]}" --test-version "$version" --out "$out/$version" \
    --base-url "$BANANA_TEST_BASE_URL/$version" --sparkle-bin "$SPARKLE_BIN" --key-file "$key"
done
cp "$out/2/appcast.xml" "$out/appcast.xml"
echo "Install build 1: $BANANA_TEST_BASE_URL/1/Banana-Installer-Test-1.dmg"
echo "Then choose Check for Updates to install build 2."
