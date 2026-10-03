#!/bin/bash
# Session Bar installer.
#
# One command:
#   curl -fsSL https://raw.githubusercontent.com/aadilkadiwal/claude-session-bar/main/install.sh | bash
# or from a checkout:
#   ./install.sh
#
# Builds the app from source (no unsigned download for Gatekeeper to block), copies it to
# /Applications, hooks your Claude Code status line so usage limits reach the app, and opens it.
# Running it again updates everything in place.
set -euo pipefail

REPO_URL="${SESSION_BAR_REPO:-https://github.com/aadilkadiwal/claude-session-bar.git}"
DATA_DIR="$HOME/.claude/session-bar"
SETTINGS="$HOME/.claude/settings.json"
TAP="$DATA_DIR/statusline-tap.sh"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; reset=$'\033[0m'
step() { echo "${bold}==>${reset} $*"; }
ok()   { echo "    ${green}✓${reset} $*"; }
warn() { echo "    ${yellow}!${reset} $*"; }
die()  { echo "    ${red}✗${reset} $*" >&2; exit 1; }

step "Checking requirements"
[ "$(uname)" = "Darwin" ] || die "Session Bar is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "Needs macOS 14 (Sonoma) or later. You have $(sw_vers -productVersion)."
ok "macOS $(sw_vers -productVersion)"
xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null || die "Needs Xcode Command Line Tools. Run: xcode-select --install"
ok "Swift $(swift --version 2>/dev/null | grep -o 'Swift version [0-9.]*' | cut -d' ' -f3)"
command -v python3 >/dev/null || die "Needs python3 (comes with the Command Line Tools)."
if command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ]; then ok "Claude Code found"
else warn "Claude Code not found on PATH. Session Bar will tell you if it can't find it."; fi

# Use this checkout if we're inside one, otherwise clone or update a copy under ~/.claude/session-bar/src.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/Package.swift" ] && [ -f "$here/scripts/build-app.sh" ]; then
  SRC="$here"
else
  SRC="$DATA_DIR/src"
  step "Downloading source"
  command -v git >/dev/null || die "Needs git."
  if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only --quiet; else rm -rf "$SRC"; git clone --quiet --depth 1 "$REPO_URL" "$SRC"; fi
  ok "$SRC"
fi

step "Building (first build takes about a minute)"
APP_BUILT="$("$SRC/scripts/build-app.sh" 2>&1 | tail -1)"
[ -d "$SRC/$APP_BUILT" ] || die "Build failed. Run $SRC/scripts/build-app.sh to see the error."
ok "Built"

step "Installing the app"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x SessionBar 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Session Bar.app"
cp -R "$SRC/$APP_BUILT" "$DEST/"
ok "$DEST/Session Bar.app"

step "Connecting your status line (so usage limits reach the app)"
mkdir -p "$DATA_DIR"
echo "$SRC" > "$DATA_DIR/source-path"   # where Settings → Check for updates looks
cp "$SRC/scripts/statusline-tap.sh" "$TAP"
chmod +x "$TAP"
python3 - "$SETTINGS" "$TAP" "$DATA_DIR/original-statusline" <<'PY'
import json, os, shutil, sys
settings, tap, orig_file = sys.argv[1:4]
data = {}
if os.path.exists(settings):
    try:
        with open(settings) as f:
            data = json.load(f)
    except Exception as e:
        sys.exit(f"    ~/.claude/settings.json isn't valid JSON ({e}). Fix it and run the installer again. Nothing was changed.")
    backup = settings + ".session-bar-backup"
    if not os.path.exists(backup):
        shutil.copy2(settings, backup)
line = data.get("statusLine") or {}
current = line.get("command", "") if line.get("type", "command") == "command" else ""
if current != tap:
    # Remember what was there so the tap can keep running it and uninstall can put it back.
    with open(orig_file, "w") as f:
        f.write(current)
    data["statusLine"] = {**line, "type": "command", "command": tap}
    with open(settings + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(settings + ".tmp", settings)
    print("    \033[32m✓\033[0m status line now goes through Session Bar" + (" (your own status line still shows)" if current else ""))
else:
    print("    \033[32m✓\033[0m already connected")
PY

step "Opening Session Bar"
open "$DEST/Session Bar.app"
ok "Look for the ring in your menu bar"
echo
echo "${bold}Done.${reset} Usage numbers appear after your next Claude Code message."
echo "${dim}Update: run this installer again · Remove: $SRC/uninstall.sh${reset}"
