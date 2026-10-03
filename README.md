# Session Bar

A macOS menu bar app for [Claude Code](https://claude.com/claude-code):

- **Usage at a glance**: rings for your 5-hour and weekly limits with reset times (the same numbers `/usage` shows), plus a pace line: "At this pace: 100% at 3:40 PM". The menu bar shows whichever limit is closer to running out.
- **Live session list**: every running session, newest first, with quick search. Grouped by project when more than five are running. An amber dot on the menu bar icon means a session is waiting for you.
- **Notifications**: a session needs your answer, a long task finished, a limit passed 80% / 95%. Each can be switched off.
- **Phone in one click**: make a running session reachable from the Claude phone app while it keeps running on your Mac, or disconnect the phone again. No restart.
- **Rename** running sessions (types `/rename`) and closed ones.
- **New session without a terminal**: pick a folder, then start it for your phone or open it in iTerm.
- **History**: search, preview (last reply, prompts, duration, tokens), resume in an iTerm tab, delete one or many, one-click cleanup of empty sessions, and keep history for 1 week, 2 weeks or 30 days.

Design walkthrough with clickable mockups and every flow: [`docs/design.html`](docs/design.html).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aadilkadiwal/claude-session-bar/main/install.sh | bash
```

Or from a checkout: `./install.sh`. Run it again any time to update.

Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`), Claude Code, iTerm2.

The installer:
1. Builds the app from source. Because it's built locally, there's no unsigned download for Gatekeeper to block.
2. Copies **Session Bar.app** to `/Applications`.
3. Points Claude Code's status line at a small tap script (`~/.claude/session-bar/statusline-tap.sh`) that saves the usage numbers and then runs **your original status line unchanged**. Your `settings.json` is backed up first, to `settings.json.session-bar-backup`.
4. Opens the app. It turns on *Open at login*, which you can switch off in Settings.

## Remove

```bash
./uninstall.sh        # or ~/.claude/session-bar/src/uninstall.sh if you used the curl install
```

Restores your original status line and removes the app and its data. Your Claude Code sessions are not touched.

## How it works

Session Bar has no server and no login. It reads what Claude Code already writes, and every action is a normal `claude` command.

| Shows / does | Source |
|---|---|
| Running sessions, busy/idle, phone on/off | `~/.claude/sessions/<pid>.json` (watched for changes) + `claude agents --json` |
| Usage rings | `rate_limits` from the status line JSON, saved by the tap to `~/.claude/session-bar/status.json` |
| History, names, models, sizes | Head and tail of `~/.claude/projects/*/*.jsonl` (cached) |
| 📱 on a running session (iTerm) | Types `/remote-control` into that exact tab, found by its tty, the same as typing it yourself. It keeps running on the Mac **and** is on your phone. Clicking again chooses *Disconnect* from that menu, so it leaves the phone but keeps running. Only works when the session is idle. If you've typed something in its prompt, nothing is sent and your text is left as it was. |
| 📱 on a background session | It has no window, so it reopens in iTerm with `claude --resume <id> --remote-control`: on your Mac and your phone. |
| Stop | `claude stop <id>` (background) or SIGTERM (terminal). Also removes it from the phone. |
| New for phone | `claude --bg --remote-control -n <name>` in the chosen folder |
| Open / resume a session | A new tab in your current iTerm window (a new window if none is open), via iTerm's AppleScript API. macOS asks once to allow it. |
| Keep history for 7 / 14 / 30 days | `cleanupPeriodDays` in `~/.claude/settings.json` (Claude Code's own cleanup) |
| Pace forecast | Usage readings logged to `~/.claude/session-bar/usage-log.jsonl` (8 days kept). Rate over the last hour (5-hour limit) or day (weekly). |
| Waiting / finished alerts | `waitingFor` and `status` in each session's pid file, read every 3 s (no process started) |
| Rename | Running: types `/rename <name>` (same safety rules as the phone button). Closed: appends a `custom-title` line, as Claude Code does. |
| Check for updates | `git fetch` in the folder the installer built from; Update pulls and re-runs `install.sh` |
| Delete / Clean up | Moves transcripts to the Trash, so you can still restore them |

Notes:
- Usage only updates while a Claude Code session is active, because that's when Claude Code sends it. The dropdown shows how old the numbers are.
- Background sessions only start in folders you've trusted. If a folder isn't trusted yet, the app offers to open it in iTerm so you can accept the prompt.
- Deleting history frees space on your Mac. Sessions listed on claude.ai or in the phone app are kept on Anthropic's servers and aren't affected.

## Develop

```bash
swift build                      # debug build
swift test                       # unit tests (SessionBarCore)
SESSION_BAR_INTEGRATION=~/some/trusted/folder swift test --filter testIntegration
                                 # real end-to-end: start a phone session, see it, stop it, clean up
scripts/build-app.sh             # -> build/Session Bar.app
```

Layout:
- `Sources/SessionBarCore`: file parsing, `claude` commands, settings. No UI, unit-tested.
- `Sources/SessionBar`: SwiftUI menu bar app (`MenuView` dropdown, `DetailsView` window).
- `scripts/statusline-tap.sh`: the status line tap.
