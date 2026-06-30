#!/bin/bash
#
# alibi-to-5.sh — schedule a weekday Mac wake and run a wake routine, all from
# one script. The LaunchAgent calls this same file back with the (internal)
# "run" command, so there is no separate install/uninstall script.
#
# Commands you use:
#   alibi-to-5.sh set [HH:MM]   Schedule a Mon-Fri wake + install the agent.
#                               Prompts for the time if you omit it.
#   alibi-to-5.sh unset         Cancel the schedule + remove the agent.
#   alibi-to-5.sh test          Run the routine now and show the log tail.
#   alibi-to-5.sh status        Show the schedule, agent state, recent log.
#   alibi-to-5.sh help          Show usage.
#
# Internal (the LaunchAgent calls this; you never type it yourself):
#   alibi-to-5.sh run           The wake routine itself.
#
# The routine: keep the Mac awake (caffeinate), jiggle the mouse (cliclick) so
# Slack/Teams do not show you "away", open your apps, and fire a one-shot
# "are you there" at the Codex CLI to start its usage window.
#
# Logs to ~/Library/Logs/alibi-to-5.log

set -uo pipefail

# ---- Config (edit these) --------------------------------------------------
WAKE_DAYS="MTWRF"                                  # Mon-Fri
PLIST_LABEL="com.user.alibi-to-5"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG="$HOME/Library/Logs/alibi-to-5.log"
KEEP_AWAKE_SECONDS=32400                           # caffeinate hold ~9h after wake
JIGGLE_INTERVAL_SECONDS=60                         # nudge cadence; keep < away threshold (Teams ~5m, Slack ~10m)
JIGGLE_PIXELS=3                                    # nudge distance; returns to origin each time
CODEX_PROMPT="are you there"
OPEN_APPS=("Slack")                                # apps to open on wake; add "Microsoft Teams", etc.

# Absolute path to THIS script, baked into the agent so it can call us back.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- Helpers --------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }
say() { printf '%s\n' "$*"; }
app_installed() { [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]; }

# Resolve a CLI through a login shell: launchd runs with a minimal PATH, so we
# pick up Homebrew / npm-global / etc. the same way an interactive shell would.
# Pass the name as a positional ($1 inside the -c script) rather than
# interpolating it into the command string, so it is never treated as code.
resolve_bin() { /bin/zsh -lc 'command -v -- "$1"' zsh "$1" 2>/dev/null; }

usage() {
  cat <<'EOF'
alibi-to-5 - schedule a weekday Mac wake and run a wake routine.

Usage:
  alibi-to-5.sh set [HH:MM]   Schedule a Mon-Fri wake + install the agent.
                              Prompts for the time if you omit it.
  alibi-to-5.sh unset         Cancel the schedule + remove the agent.
  alibi-to-5.sh test          Run the routine now and show the log tail.
  alibi-to-5.sh status        Show the schedule, agent state, recent log.
  alibi-to-5.sh help          Show this help.

On each weekday wake the routine keeps the Mac awake (caffeinate), jiggles the
mouse (cliclick) so Slack/Teams stay active, opens your apps, and pings Codex.
EOF
}

# ---- write_plist <hour> <minute> -----------------------------------------
# Emits the LaunchAgent plist that runs "<this script> run" every weekday at
# the given time. StartCalendarInterval (not RunAtLoad) means launchd fires it
# on the scheduled wake even if you are already logged in.
write_plist() {
  local hour="$1" min="$2" wd
  mkdir -p "$HOME/Library/LaunchAgents"
  {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SELF</string>
        <string>run</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
PLIST
    # Weekday: 1=Mon ... 5=Fri
    for wd in 1 2 3 4 5; do
      printf '        <dict><key>Weekday</key><integer>%s</integer><key>Hour</key><integer>%s</integer><key>Minute</key><integer>%s</integer></dict>\n' "$wd" "$hour" "$min"
    done
    cat <<'PLIST'
    </array>
</dict>
</plist>
PLIST
  } >"$PLIST_PATH"
}

# ---- set [HH:MM] ----------------------------------------------------------
cmd_set() {
  local hm="${1:-}"
  if [ -z "$hm" ]; then
    read -r -p "Wake time in 24h HH:MM (e.g. 09:40): " hm
  fi
  if ! [[ "$hm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    say "ERROR: '$hm' is not a valid HH:MM time."; exit 1
  fi
  local hour=$((10#${hm%%:*})) min=$((10#${hm##*:}))

  say "Scheduling wake for $WAKE_DAYS at $hm (needs admin password)..."
  # 'wake' = wake from sleep (FileVault stays unlocked). Mac must be ASLEEP.
  sudo pmset repeat wake "$WAKE_DAYS" "$hm:00"

  write_plist "$hour" "$min"
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"

  say
  say "Done - wake + routine scheduled at $hm, Mon-Fri."
  say "Runtime script: $SELF"
  say "(If you move/rename this script, just run 'set' again.)"
  say
  say "Manual steps:"
  say "  * Keep the Mac ASLEEP (not shut down)."
  say "  * System Settings -> Lock Screen -> require password 'Never' (keeps FileVault on)."
  say
  pmset -g sched
}

# ---- unset ----------------------------------------------------------------
cmd_unset() {
  say "Cancelling scheduled wake (needs admin password)..."
  sudo pmset repeat cancel
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  say "Removed the schedule and the LaunchAgent."
  say "(Lock Screen / FileVault settings you changed by hand are left as-is.)"
}

# ---- run (the routine the agent calls; not shown in help) -----------------
cmd_run() {
  log "==== alibi-to-5 run starting ===="

  # 0. Keep the Mac awake. A scheduled wake on battery re-sleeps quickly
  #    otherwise; caffeinate holds display + system awake for the work day.
  /usr/bin/caffeinate -dimsu -t "$KEEP_AWAKE_SECONDS" >>"$LOG" 2>&1 &
  log "caffeinate started: keeping awake for $((KEEP_AWAKE_SECONDS/3600))h."

  # 1. Mouse jiggle so Slack/Teams do not mark you "away". Away status is driven
  #    by OS idle time (seconds since the last HID event), and ANY event resets
  #    it -- so distance is irrelevant, cadence is what matters. We nudge the
  #    cursor and move it straight back so it never drifts.
  local cliclick
  cliclick="$(resolve_bin cliclick)"
  if [ -n "$cliclick" ]; then
    (
      end=$(( SECONDS + KEEP_AWAKE_SECONDS ))
      while [ "$SECONDS" -lt "$end" ]; do
        "$cliclick" "m:+${JIGGLE_PIXELS},+0" "m:-${JIGGLE_PIXELS},+0" >/dev/null 2>&1
        sleep "$JIGGLE_INTERVAL_SECONDS"
      done
    ) >>"$LOG" 2>&1 &
    log "Mouse jiggle started via $cliclick (${JIGGLE_PIXELS}px every ${JIGGLE_INTERVAL_SECONDS}s)."
  else
    log "WARNING: cliclick not found (brew install cliclick); jiggle skipped - Slack/Teams may show away."
  fi

  # 2. Open the configured apps. The empty-array-safe expansion keeps this
  #    working under 'set -u' on macOS bash 3.2 even if OPEN_APPS is cleared.
  local app
  for app in ${OPEN_APPS[@]+"${OPEN_APPS[@]}"}; do
    if app_installed "$app"; then
      open -a "$app" >>"$LOG" 2>&1
      log "Opened $app."
    else
      log "WARNING: $app.app not found; skipped."
    fi
  done

  # 3. Ping Codex to start its usage window (headless, read-only sandbox: it
  #    only returns text -- no file changes, no commands -- but the request
  #    starts a session, which begins the usage/rate-limit window).
  local codex
  codex="$(resolve_bin codex)"
  if [ -n "$codex" ]; then
    "$codex" exec --sandbox read-only "$CODEX_PROMPT" >>"$LOG" 2>&1 &
    log "Codex '$CODEX_PROMPT' dispatched via $codex."
  else
    log "WARNING: codex CLI not found via login shell PATH; skipped."
  fi

  log "==== run done ===="
}

# ---- test -----------------------------------------------------------------
cmd_test() {
  say "Running the routine now... (this starts the real ~9h caffeinate + jiggle)"
  cmd_run
  say "Recent log:"
  tail -n 15 "$LOG" 2>/dev/null || say "(no log yet)"
}

# ---- status ---------------------------------------------------------------
cmd_status() {
  say "== Repeating wake schedule =="
  pmset -g sched
  say
  say "== LaunchAgent =="
  launchctl list 2>/dev/null | grep -i alibi-to-5 || say "(agent not loaded)"
  [ -f "$PLIST_PATH" ] && say "plist: $PLIST_PATH" || say "plist: (none)"
  say
  say "== Recent log =="
  tail -n 15 "$LOG" 2>/dev/null || say "(no log yet)"
}

# ---- dispatch -------------------------------------------------------------
main() {
  case "${1:-help}" in
    set)            shift; cmd_set "${1:-}" ;;
    unset)          cmd_unset ;;
    run)            cmd_run ;;          # internal: invoked by the LaunchAgent
    test)           cmd_test ;;
    status)         cmd_status ;;
    help|-h|--help) usage ;;
    *) say "Unknown command: $1"; say; usage; exit 1 ;;
  esac
}
main "$@"
