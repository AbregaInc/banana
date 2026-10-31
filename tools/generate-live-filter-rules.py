#!/usr/bin/env python3
"""Generate the web grammar from the Apple app's bundled rule definitions."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rules = json.loads((root / "Shared/LiveFilterRules.json").read_text())
(root / "Service/public/app/assets/live-filter-rules.js").write_text(
    "// Generated from Shared/LiveFilterRules.json; parity checked by live-filter.test.js.\nexport default "
    + json.dumps(rules, separators=(",", ":")) + ";\n")
