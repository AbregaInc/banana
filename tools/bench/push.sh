#!/bin/zsh
# Copy the bench dishes into Banana's Documents/bench on a device, for `--estimator-bench`.
#   tools/bench/push.sh <device UDID> [folder, default build/bench/nutrition5k]
# Writes only the app's own Documents/bench/nutrition5k; touches nothing else.
set -euo pipefail
udid=${1:?device UDID}
folder=${2:-build/bench/nutrition5k}
[[ -f "$folder/manifest.json" ]] || { echo "no $folder/manifest.json — run tools/bench/fetch_nutrition5k.py first"; exit 1; }
xcrun devicectl device copy to --device "$udid" --domain-type appDataContainer \
  --domain-identifier "${BANANA_BUNDLE_ID:-$(sed -n 's/^BANANA_BUNDLE_ID *= *//p' Config/Local.xcconfig Config/Base.xcconfig 2>/dev/null | head -1)}" --source "$folder" --destination Documents/bench/nutrition5k
echo "copied; launch Banana with --estimator-bench and read the 🔬 bench lines in playback.log"
