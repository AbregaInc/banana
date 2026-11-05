#!/bin/bash
# Compatibility entry point. Preparation is the default; upload must be explicit.
set -euo pipefail
exec "$(dirname "$0")/testflight.sh" mac "$@"
