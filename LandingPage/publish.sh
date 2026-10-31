#!/usr/bin/env bash
# Regenerate only published content and check the full static site before deploy.
set -euo pipefail
cd "$(dirname "$0")/.."
uv run --locked LandingPage/build_content.py
python3 LandingPage/check_site.py
cd LandingPage
volta run --node 24.22.1 --bundled-npm npx --yes wrangler@4.81.1 deploy
