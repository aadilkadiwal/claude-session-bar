#!/bin/bash
# Removes Session Bar and puts your original status line back.
set -euo pipefail

DATA_DIR="$HOME/.claude/session-bar"
SETTINGS="$HOME/.claude/settings.json"

pkill -x SessionBar 2>/dev/null || true
rm -rf "/Applications/Session Bar.app" "$HOME/Applications/Session Bar.app"
echo "✓ App removed"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" "$DATA_DIR/statusline-tap.sh" "$DATA_DIR/original-statusline" <<'PY'
import json, os, sys
settings, tap, orig_file = sys.argv[1:4]
with open(settings) as f:
    data = json.load(f)
line = data.get("statusLine") or {}
if line.get("command") == tap:
    orig = open(orig_file).read().strip() if os.path.exists(orig_file) else ""
    if orig:
        data["statusLine"] = {**line, "command": orig}
    else:
        data.pop("statusLine", None)
    with open(settings + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(settings + ".tmp", settings)
    print("✓ Status line restored")
PY
fi

rm -rf "$DATA_DIR"
echo "✓ Session Bar data removed (your Claude Code sessions are untouched)"
