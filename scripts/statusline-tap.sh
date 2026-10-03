#!/bin/bash
# Session Bar status line tap.
#
# Claude Code pipes a JSON blob to the status line command on every refresh. It includes your
# usage limits (rate_limits.five_hour / seven_day). This script saves that blob for Session Bar,
# then hands the same input to your original status line command, so your status line looks
# exactly as before.
#
# Installed to ~/.claude/session-bar/statusline-tap.sh; your original command is kept in
# ~/.claude/session-bar/original-statusline and put back by uninstall.sh.

dir="$HOME/.claude/session-bar"
input=$(cat)

# Only keep snapshots that carry limits (API-key sessions have none), written atomically
# because several sessions can refresh at the same moment.
case "$input" in
  *'"five_hour"'*|*'"seven_day"'*)
    tmp="$dir/status.json.$$"
    printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$dir/status.json"
    ;;
esac

orig="$dir/original-statusline"
if [ -s "$orig" ]; then
  printf '%s' "$input" | /bin/bash -c "$(cat "$orig")"
fi
