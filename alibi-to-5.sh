#!/bin/bash
#
# alibi-to-5.sh — schedule a weekday Mac wake and run a wake routine, all from
# one script. The LaunchAgent calls this same file back with the (internal)
# "run" command, so there is no separate install/uninstall script.
#
# Commands you use:
#   alibi-to-5.sh set [HH:MM] [flags]   Schedule a Mon-Fri wake + install agent.
#                                       Prompts for the time if you omit it.
#   alibi-to-5.sh unset                 Cancel the schedule, remove the agent,
#                                       and stop a running routine.
#   alibi-to-5.sh test [flags]          Run the routine now and show the log tail.
#   alibi-to-5.sh doctor [flags]        Preflight checks (Accessibility, bins, etc).
#   alibi-to-5.sh pause [DURATION]      Take a break: stop looking active now.
#   alibi-to-5.sh resume                End a pause.
#   alibi-to-5.sh status                Show the schedule, agent state, log.
#   alibi-to-5.sh help                  Show usage (lists the feature flags).
#
# Internal (the LaunchAgent calls this; you never type it yourself):
#   alibi-to-5.sh run [flags]           The wake routine itself.
#
# The routine: skip the day entirely on a public holiday / PTO date, else keep
# the Mac awake (caffeinate), run a humanized activity loop (cliclick with
# randomized cadence/distance) so Slack/Teams do not show you "away", shaped to a
# workday (optional end time + a jittered lunch gap and short random micro-breaks
# where you intentionally go Away, plus a random morning start delay and on-demand
# pause/resume), open the enabled apps (Slack/Teams), ping the enabled CLIs
# (Codex/Claude) to start their usage windows, and optionally post a good-morning
# message to a Slack/Teams webhook. Every integration is an independent toggle --
# a config default plus a --flag/--no-flag on 'set' that is baked into the agent.
# See usage() / the README for the flags.
#
# Logs to ~/Library/Logs/alibi-to-5.log

set -uo pipefail

# ---- Config (edit these) --------------------------------------------------
WAKE_DAYS="MTWRF"                                  # Mon-Fri
PLIST_LABEL="com.user.alibi-to-5"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG="$HOME/Library/Logs/alibi-to-5.log"
PIDFILE="$HOME/Library/Logs/alibi-to-5.pids"       # PIDs of the running routine (caffeinate + loop), so 'unset' can stop them
CONTROLFILE="$HOME/Library/Logs/alibi-to-5.control" # pause state: a "paused-until" epoch (0 = indefinite)
STATEFILE="$HOME/Library/Logs/alibi-to-5.state"    # today's resolved window/lunch epochs, for 'status'
KEEP_AWAKE_SECONDS=32400                            # fallback active-window length (~9h) when WORK_END is unset
LOG_MAX_BYTES=$((5 * 1024 * 1024))                 # rotate the log to .log.1 once it exceeds this (0 disables)

# Humanized jiggle: cadence and distance are randomized per nudge so the activity
# does not look like a metronome. Keep the MAX interval under the away threshold
# (Teams ~5m, Slack ~10m).
JIGGLE_MIN_SECONDS=45                               # nudge cadence, lower bound
JIGGLE_MAX_SECONDS=120                              # nudge cadence, upper bound
JIGGLE_MIN_PIXELS=1                                 # nudge distance, lower bound (returns to origin)
JIGGLE_MAX_PIXELS=8                                 # nudge distance, upper bound
START_JITTER_MAX_SECONDS=600                        # random 0..this delay before activity begins (0 disables)
PAUSE_POLL_SECONDS=30                               # how often the loop re-checks lunch/pause state

# Workday shape. WORK_END sets an explicit end-of-day (else KEEP_AWAKE_SECONDS is
# used). LUNCH_START enables a mid-day idle gap (you show "Away" like a real
# person, then resume). Empty = off. Both are also flags on 'set' (--until,
# --lunch/--no-lunch), baked into the agent.
WORK_END=""                                        # "HH:MM" end-of-day; empty -> use KEEP_AWAKE_SECONDS
LUNCH_START=""                                      # "HH:MM" lunch start; empty -> no lunch gap
LUNCH_MINUTES=45                                    # lunch length
LUNCH_JITTER_MINUTES=10                             # +/- randomization on lunch start and length, rolled per day

# Micro-breaks: short random "Away" gaps sprinkled through the day beyond lunch
# (coffee/bathroom). Kept UNDER the away threshold so they read as brief natural
# gaps, not a disconnect. Resolved per day in resolve_schedule.
MICROBREAK_MAX_COUNT=3                              # up to N micro-breaks/day (0 disables)
MICROBREAK_MIN_MINUTES=4                            # each break's length, lower bound
MICROBREAK_MAX_MINUTES=12                           # each break's length, upper bound (keep <= ~away threshold)

# Holiday / PTO skip: on a skip day the routine does not run at all (machine goes
# back to sleep, you look genuinely offline). Public holidays come from the
# Nager.Date API for COUNTRY_CODE, cached per year; EXTRA_SKIP_DATES adds manual
# PTO/one-offs the API can't know. Fail-open: any lookup failure -> run normally.
ENABLE_HOLIDAY_SKIP=1                               # master toggle (also --holidays/--no-holidays on 'set')
COUNTRY_CODE=""                                     # ISO-3166 alpha-2 (e.g. US, PT); empty -> no holiday lookup
EXTRA_SKIP_DATES=()                                 # manual YYYY-MM-DD skip dates (PTO / one-offs)
HOLIDAY_CACHE_DIR="$HOME/.config/alibi-to-5"        # cached holidays-<YYYY>.json lives here

# Today's resolved micro-break windows (parallel arrays), filled by resolve_schedule.
MB_S_EPOCHS=()
MB_E_EPOCHS=()

# Feature toggles (defaults). Each is also a --flag / --no-flag on 'set', and the
# resolved choice is baked into the LaunchAgent, so it applies on every wake.
ENABLE_SLACK=1                                     # open Slack.app
ENABLE_TEAMS=0                                     # open Microsoft Teams.app
ENABLE_CODEX=1                                     # ping the Codex CLI to start its usage window
ENABLE_CLAUDE=0                                    # ping the Claude CLI to start its usage window
CODEX_PROMPT="are you there"
CLAUDE_PROMPT="are you there"

# Good-morning message: non-empty text (or --good-morning "TEXT" on 'set') posts to
# a Slack/Teams incoming webhook after the apps open. {time}/{date}/{day} tokens are
# interpolated at wake. Webhook URLs live OUTSIDE the repo, in SECRETS_FILE.
GOOD_MORNING_TEXT=""
GOOD_MORNING_PLATFORM="slack"                      # slack | teams
SECRETS_FILE="$HOME/.config/alibi-to-5/secrets"    # sourced: SLACK_WEBHOOK_URL / TEAMS_WEBHOOK_URL

OPEN_APPS=()                                       # any OTHER apps to open (Slack/Teams have their own toggles)

# Absolute path to THIS script, baked into the agent so it can call us back.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- Helpers --------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }
say() { printf '%s\n' "$*"; }
app_installed() { [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]; }

# Resolve a CLI the same way an interactive shell would: launchd runs with a
# minimal PATH, so we source the user's shell config to pick up Homebrew,
# ~/.local/bin, npm-global, etc. We use an *interactive* login shell (-i, not
# just -l): zsh only sources ~/.zshrc for interactive shells, and that is where
# PATH additions like ~/.local/bin typically live -- a plain login shell (-l)
# reads .zprofile/.zlogin but NOT .zshrc, so it misses them under launchd.
# stdin from /dev/null so a stray interactive prompt can never block us.
# Pass the name as a positional ($1 inside the -c script) rather than
# interpolating it into the command string, so it is never treated as code.
resolve_bin() { /bin/zsh -ilc 'command -v -- "$1"' zsh "$1" </dev/null 2>/dev/null; }

# JSON-escape a string for a {"text":"..."} webhook payload -- dependency-free.
# Order matters: double the backslashes FIRST, so the escapes we add below are
# not themselves re-doubled.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# XML-escape a string so user-supplied greeting text can be baked into the plist
# as a <string>. Ampersand FIRST, for the same reason as above.
xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# Fill {time}/{date}/{day} tokens in a greeting at send time; unknown tokens are
# left as-is.
interpolate() {
  local s=$1
  s=${s//\{time\}/$(date '+%H:%M')}
  s=${s//\{date\}/$(date '+%Y-%m-%d')}
  s=${s//\{day\}/$(date '+%A')}
  printf '%s' "$s"
}

# Random integer in [LO, HI] inclusive. Degenerate ranges (HI <= LO) return LO,
# so callers never divide by zero or get an out-of-range value.
rand_between() {
  local lo=$1 hi=$2
  [ "$hi" -le "$lo" ] && { echo "$lo"; return; }
  echo $(( lo + RANDOM % (hi - lo + 1) ))
}

# True (0) when START <= NOW < END for a valid window. Empty/zero/degenerate
# windows count as "not in window", so a disabled lunch gap is simply never hit.
in_window() {
  local now=$1 s=$2 e=$3
  [ -n "$s" ] && [ -n "$e" ] || return 1
  [ "$s" -gt 0 ] && [ "$e" -gt "$s" ] || return 1
  [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ]
}

# True (0) when a pause is in effect. The control file holds a "paused-until"
# epoch: 0 means indefinite (until 'resume'); a positive value pauses until then.
# No file = not paused.
is_paused() {
  local cf=$1 now=$2 until
  [ -f "$cf" ] || return 1
  until=$(cat "$cf" 2>/dev/null)
  [ -n "$until" ] || return 1
  [ "$until" -le 0 ] && return 0
  [ "$now" -lt "$until" ]
}

# Parse a break duration to seconds: NNs / NNm / NNh, or a bare number = minutes.
# Echoes the seconds; returns 1 on anything malformed.
parse_duration() {
  local s=$1 n unit
  n=${s%[smh]}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$s" in
    *s) unit=s ;;
    *h) unit=h ;;
    *m) unit=m ;;
    *)  unit=m ;;   # bare number = minutes
  esac
  case "$unit" in
    s) echo "$n" ;;
    m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
  esac
}

# "HH:MM" -> today's epoch for that wall-clock time (macOS BSD date).
hm_to_epoch() {
  date -j -f "%Y-%m-%d %H:%M" "$(date +%F) $1" +%s 2>/dev/null
}

# True (0) when NOW falls inside one of today's resolved micro-break windows,
# held in the parallel MB_S_EPOCHS / MB_E_EPOCHS arrays (see resolve_schedule).
# Empty arrays -> never inside, so micro-breaks disabled is simply never hit.
in_microbreak() {
  local now=$1 i n=${#MB_S_EPOCHS[@]}
  for (( i = 0; i < n; i++ )); do
    in_window "$now" "${MB_S_EPOCHS[$i]}" "${MB_E_EPOCHS[$i]}" && return 0
  done
  return 1
}

# True (0) when the loop should nudge right now: not in the lunch gap, not in a
# micro-break, and not manually paused. Composes the tested predicates above.
should_jiggle() {
  local now=$1 ls=$2 le=$3 cf=$4
  in_window "$now" "$ls" "$le" && return 1
  in_microbreak "$now" && return 1
  is_paused "$cf" "$now" && return 1
  return 0
}

# True (0) when the log file should be rotated: its size in bytes exceeds the
# cap. A non-numeric size (no file) or a zero/disabled cap never rotates.
log_needs_rotation() {
  local bytes=$1 cap=$2
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cap" -gt 0 ] || return 1
  [ "$bytes" -gt "$cap" ]
}

# True (0) when TODAY (YYYY-MM-DD) is one of the given skip dates. Whole-token
# compare, so a prefix like 2026-07-0 never matches 2026-07-04. Empty list -> no.
is_skip_day() {
  local today=$1 d; shift
  for d in "$@"; do
    [ "$d" = "$today" ] && return 0
  done
  return 1
}

# Pull YYYY-MM-DD values out of a Nager.Date PublicHolidays JSON payload, one per
# line, dependency-free (no jq). Matches only the "date":"..." fields, so numeric
# fields like launchYear are ignored.
extract_holiday_dates() {
  printf '%s' "$1" \
    | grep -oE '"date":"[0-9]{4}-[0-9]{2}-[0-9]{2}"' \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}'
}

# Resolve the day's schedule from the flags: the active-window end epoch, the
# caffeinate duration derived from it, and today's (jittered) lunch window. Sets
# WINDOW_END_EPOCH / CAFFEINATE_SECS / LUNCH_S_EPOCH / LUNCH_E_EPOCH.
resolve_schedule() {
  local now end base js jlen count span slot i slot_s slot_e len bs be
  now=$(date +%s)
  # Active-window end: explicit WORK_END wins; else fall back to the duration.
  # Also fall back if the end time is missing, malformed, or already past.
  end=0
  if [ -n "$FEAT_UNTIL" ] && [[ "$FEAT_UNTIL" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    end=$(hm_to_epoch "$FEAT_UNTIL"); end=${end:-0}
  fi
  [ "$end" -le "$now" ] && end=$(( now + KEEP_AWAKE_SECONDS ))
  WINDOW_END_EPOCH=$end
  CAFFEINATE_SECS=$(( end - now ))

  # Lunch gap: jitter start and length by +/- LUNCH_JITTER_MINUTES, clamp to the
  # window. Disabled unless LUNCH_START is a valid time.
  LUNCH_S_EPOCH=0; LUNCH_E_EPOCH=0
  if [ -n "$FEAT_LUNCH_START" ] && [[ "$FEAT_LUNCH_START" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    base=$(hm_to_epoch "$FEAT_LUNCH_START"); base=${base:-0}
    if [ "$base" -gt 0 ]; then
      js=$(( (RANDOM % (2 * LUNCH_JITTER_MINUTES + 1)) - LUNCH_JITTER_MINUTES ))
      jlen=$(( (RANDOM % (2 * LUNCH_JITTER_MINUTES + 1)) - LUNCH_JITTER_MINUTES ))
      LUNCH_S_EPOCH=$(( base + js * 60 ))
      LUNCH_E_EPOCH=$(( LUNCH_S_EPOCH + (FEAT_LUNCH_MIN + jlen) * 60 ))
      [ "$LUNCH_E_EPOCH" -gt "$WINDOW_END_EPOCH" ] && LUNCH_E_EPOCH=$WINDOW_END_EPOCH
    fi
  fi

  # Micro-breaks: split the remaining active span into `count` equal slots and drop
  # one short break of random length into each, skipping any that would collide with
  # the lunch gap. Per-slot placement keeps the breaks from overlapping each other.
  MB_S_EPOCHS=(); MB_E_EPOCHS=()
  if [ "$MICROBREAK_MAX_COUNT" -gt 0 ]; then
    count=$(rand_between 0 "$MICROBREAK_MAX_COUNT")
    if [ "$count" -gt 0 ] && [ "$WINDOW_END_EPOCH" -gt "$now" ]; then
      span=$(( WINDOW_END_EPOCH - now ))
      slot=$(( span / count ))
      for (( i = 0; i < count; i++ )); do
        len=$(( $(rand_between "$MICROBREAK_MIN_MINUTES" "$MICROBREAK_MAX_MINUTES") * 60 ))
        slot_s=$(( now + i * slot ))
        slot_e=$(( now + (i + 1) * slot ))
        [ $(( slot_e - len )) -le "$slot_s" ] && continue   # break can't fit this slot
        bs=$(rand_between "$slot_s" $(( slot_e - len )))
        be=$(( bs + len ))
        # skip a break that would overlap the lunch gap
        if [ "$LUNCH_S_EPOCH" -gt 0 ] && [ "$bs" -lt "$LUNCH_E_EPOCH" ] && [ "$be" -gt "$LUNCH_S_EPOCH" ]; then
          continue
        fi
        MB_S_EPOCHS+=("$bs"); MB_E_EPOCHS+=("$be")
      done
    fi
  fi
}

# Resolve the feature toggles: start from the config-constant defaults, then
# apply CLI flags. Shared by 'set' (to record the choice) and 'run'/'test' (to
# act on it), so the same argv means the same thing everywhere. Sets the FEAT_*
# and GM_* globals. Unknown args are ignored so a mixed argv can be passed in.
parse_feature_flags() {
  FEAT_SLACK=$ENABLE_SLACK
  FEAT_TEAMS=$ENABLE_TEAMS
  FEAT_CODEX=$ENABLE_CODEX
  FEAT_CLAUDE=$ENABLE_CLAUDE
  GM_TEXT=$GOOD_MORNING_TEXT
  GM_PLATFORM=$GOOD_MORNING_PLATFORM
  FEAT_UNTIL=$WORK_END
  FEAT_LUNCH_START=$LUNCH_START
  FEAT_LUNCH_MIN=$LUNCH_MINUTES
  FEAT_HOLIDAYS=$ENABLE_HOLIDAY_SKIP
  FEAT_COUNTRY=$COUNTRY_CODE
  local l
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slack)           FEAT_SLACK=1 ;;
      --no-slack)        FEAT_SLACK=0 ;;
      --teams)           FEAT_TEAMS=1 ;;
      --no-teams)        FEAT_TEAMS=0 ;;
      --codex)           FEAT_CODEX=1 ;;
      --no-codex)        FEAT_CODEX=0 ;;
      --claude)          FEAT_CLAUDE=1 ;;
      --no-claude)       FEAT_CLAUDE=0 ;;
      --good-morning)    shift; GM_TEXT=${1:-} ;;
      --no-good-morning) GM_TEXT="" ;;
      --gm-platform)     shift; GM_PLATFORM=${1:-slack} ;;
      --until)           shift; FEAT_UNTIL=${1:-} ;;
      --lunch)           shift; l=${1:-}
                         FEAT_LUNCH_START=${l%%/*}
                         case "$l" in */*) FEAT_LUNCH_MIN=${l##*/} ;; esac ;;
      --no-lunch)        FEAT_LUNCH_START="" ;;
      --holidays)        FEAT_HOLIDAYS=1 ;;
      --no-holidays)     FEAT_HOLIDAYS=0 ;;
      --country)         shift; FEAT_COUNTRY=${1:-} ;;
    esac
    shift
  done
}

# Serialize the resolved toggles into an explicit, canonical flag array (CANON),
# for baking into the plist. Fully explicit (--slack AND --no-slack are emitted
# as appropriate) so a live schedule never depends on the config defaults, which
# may be edited later.
build_canonical_flags() {
  CANON=()
  [ "$FEAT_SLACK"  = 1 ] && CANON+=(--slack)  || CANON+=(--no-slack)
  [ "$FEAT_TEAMS"  = 1 ] && CANON+=(--teams)  || CANON+=(--no-teams)
  [ "$FEAT_CODEX"  = 1 ] && CANON+=(--codex)  || CANON+=(--no-codex)
  [ "$FEAT_CLAUDE" = 1 ] && CANON+=(--claude) || CANON+=(--no-claude)
  if [ -n "$GM_TEXT" ]; then
    CANON+=(--good-morning "$GM_TEXT" --gm-platform "$GM_PLATFORM")
  fi
  [ -n "$FEAT_UNTIL" ] && CANON+=(--until "$FEAT_UNTIL")
  if [ -n "$FEAT_LUNCH_START" ]; then
    CANON+=(--lunch "$FEAT_LUNCH_START/$FEAT_LUNCH_MIN")
  else
    CANON+=(--no-lunch)
  fi
  [ "$FEAT_HOLIDAYS" = 1 ] && CANON+=(--holidays) || CANON+=(--no-holidays)
  [ -n "$FEAT_COUNTRY" ] && CANON+=(--country "$FEAT_COUNTRY")
}

# POST plain text to an incoming webhook. curl -f makes a 4xx/5xx a failure we
# can log. Output (and any error) goes to the log.
post_webhook() {
  local url=$1 text=$2
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"$(json_escape "$text")\"}" "$url" >>"$LOG" 2>&1
}

# Send the good-morning greeting when configured: source the out-of-repo secrets
# file for the webhook URL, interpolate tokens, and post. Warn-and-skip on any
# missing piece so a wake is never blocked by it.
send_good_morning() {
  local text=$1 platform=$2 url var
  [ -n "$text" ] || return 0
  if [ ! -f "$SECRETS_FILE" ]; then
    log "WARNING: good-morning set but $SECRETS_FILE missing; skipped."
    return 0
  fi
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
  case "$platform" in
    teams) var=TEAMS_WEBHOOK_URL ;;
    *)     var=SLACK_WEBHOOK_URL ;;
  esac
  url=${!var:-}
  if [ -z "$url" ]; then
    log "WARNING: good-morning platform '$platform' has no $var in $SECRETS_FILE; skipped."
    return 0
  fi
  if post_webhook "$url" "$(interpolate "$text")"; then
    log "Good-morning message posted to $platform."
  else
    log "WARNING: good-morning post to $platform failed (see curl output above)."
  fi
}

# Rotate the log to a single .log.1 backup once it passes LOG_MAX_BYTES, so it
# cannot grow unbounded over months. Best-effort; never blocks a run.
rotate_log() {
  local bytes
  bytes=$(stat -f%z "$LOG" 2>/dev/null)
  if log_needs_rotation "${bytes:-}" "$LOG_MAX_BYTES"; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
  fi
}

# Path to this year's cached public-holiday file.
holiday_cache_file() { echo "$HOLIDAY_CACHE_DIR/holidays-$(date +%Y).json"; }

# Ensure this year's public-holiday cache exists, fetching it once from the
# Nager.Date API for the resolved country (the --country flag / FEAT_COUNTRY, else
# the COUNTRY_CODE config default). Best-effort and FAIL-OPEN: no country set, no
# network, or a bad/empty response leaves the cache absent and returns non-zero,
# so the caller falls back to running (never a false skip).
ensure_holiday_cache() {
  local year cache country=${FEAT_COUNTRY:-$COUNTRY_CODE}
  [ -n "$country" ] || return 1
  year=$(date +%Y); cache="$HOLIDAY_CACHE_DIR/holidays-$year.json"
  [ -s "$cache" ] && return 0
  mkdir -p "$HOLIDAY_CACHE_DIR"
  if curl -fsS "https://date.nager.at/api/v3/PublicHolidays/$year/$country" -o "$cache" 2>>"$LOG" \
     && [ -s "$cache" ]; then
    return 0
  fi
  rm -f "$cache" 2>/dev/null
  return 1
}

# Today's full skip-date set: cached public holidays (when available) plus the
# manual EXTRA_SKIP_DATES (PTO / one-offs the API can't know). One date per line.
load_skip_dates() {
  if ensure_holiday_cache; then
    extract_holiday_dates "$(cat "$(holiday_cache_file)" 2>/dev/null)"
  fi
  local d
  for d in ${EXTRA_SKIP_DATES[@]+"${EXTRA_SKIP_DATES[@]}"}; do
    printf '%s\n' "$d"
  done
}

# Stop an in-flight routine started by a previous 'run': the caffeinate hold and
# the activity loop, both recorded in PIDFILE. Both self-terminate at the window
# end, but this lets 'unset' end them now. We match on IDENTITY (the recorded PID
# must still look like one of ours -- our script, or our caffeinate invocation),
# never a bare recorded PID, so a recycled PID can't take down an unrelated
# process. Returns 0 if it stopped anything, 1 if nothing ran.
stop_routine() {
  local killed=1 pid cmd
  if [ -f "$PIDFILE" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
      case "$cmd" in
        *alibi-to-5*|*"caffeinate -dimsu"*)
          pkill -P "$pid" 2>/dev/null   # reap any child (sleep/cliclick) of the loop
          kill "$pid" 2>/dev/null
          killed=0 ;;
      esac
    done <"$PIDFILE"
    rm -f "$PIDFILE"
  fi
  rm -f "$STATEFILE"
  return "$killed"
}

usage() {
  cat <<'EOF'
alibi-to-5 - schedule a weekday Mac wake and run a wake routine.

Usage:
  alibi-to-5.sh set [HH:MM] [flags]   Schedule a Mon-Fri wake + install the agent.
                                      Prompts for the time if you omit it.
  alibi-to-5.sh unset                 Cancel the schedule, remove the agent, and
                                      stop a running routine (caffeinate + loop).
  alibi-to-5.sh test [flags]          Run the routine now and show the log tail.
  alibi-to-5.sh doctor [flags]        Preflight checks (Accessibility grant, bins,
                                      webhook, schedule, power). 'set' runs it too.
  alibi-to-5.sh pause [DURATION]      Take a break: stop looking active now (you
                                      go "Away"). No DURATION = until 'resume';
                                      else 30m / 1h / 90s / a number of minutes.
  alibi-to-5.sh resume                End a pause and pick activity back up.
  alibi-to-5.sh status                Show schedule, state, window/lunch, log.
  alibi-to-5.sh help                  Show this help.

Feature flags (for 'set' and 'test'; each overrides its config default and is
baked into the agent, so it applies on every wake):
  --slack / --no-slack        Open Slack.app                 (default: on)
  --teams / --no-teams        Open Microsoft Teams.app        (default: off)
  --codex / --no-codex        Ping the Codex CLI usage window (default: on)
  --claude / --no-claude      Ping the Claude CLI usage window (default: off)
  --good-morning "TEXT"       Post TEXT to a webhook after apps open (off if unset).
                              {time}/{date}/{day} tokens are filled in at wake.
  --gm-platform slack|teams   Which webhook the greeting uses (default: slack).
  --until HH:MM               End the active window at this time (default: ~9h).
  --lunch HH:MM[/MIN]         Idle lunch gap (default 45m), jittered daily.
  --no-lunch                  Disable the lunch gap.
  --holidays / --no-holidays  Skip public-holiday/PTO days entirely (default: on).
                              Needs a country set; PTO via EXTRA_SKIP_DATES.
  --country CC                ISO-3166 country (e.g. US, PT) for the holiday
                              lookup (default: COUNTRY_CODE; empty = no lookup).

Example:
  alibi-to-5.sh set 09:40 --teams --until 17:00 --lunch 13:00 \
                --good-morning "Online {day} {time}"

The activity loop humanizes itself: randomized nudge cadence/distance, a random
morning start delay, an optional jittered lunch gap where you naturally show
"Away", and on-demand pause/resume. The greeting needs a webhook URL in
~/.config/alibi-to-5/secrets (see secrets.example); it is never committed.
EOF
}

# ---- write_plist <hour> <minute> -----------------------------------------
# Emits the LaunchAgent plist that runs "<this script> run" every weekday at
# the given time. StartCalendarInterval (not RunAtLoad) means launchd fires it
# on the scheduled wake even if you are already logged in.
write_plist() {
  local hour="$1" min="$2"; shift 2
  local flags=("$@") f wd
  mkdir -p "$HOME/Library/LaunchAgents"
  {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <!-- run() backgrounds the long-lived work (caffeinate, the jiggle loop) and
         the CLI usage-window pings, then exits fast. Without this, launchd
         flushes the job's process group on that exit and kills every
         backgrounded child (machine sleeps, you show Away, the codex/claude
         ping never completes). Opt out so the children outlive run(). -->
    <key>AbandonProcessGroup</key>
    <true/>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SELF</string>
        <string>run</string>
PLIST
    # The resolved feature flags, so the agent calls `run` with the same choices
    # you made at `set` time. xml_escape guards user-supplied greeting text.
    for f in ${flags[@]+"${flags[@]}"}; do
      printf '        <string>%s</string>\n' "$(xml_escape "$f")"
    done
    cat <<'PLIST'
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
  # First arg is the optional HH:MM; anything starting with -- is a feature flag.
  local hm="${1:-}"
  case "$hm" in
    ""|--*) hm="" ;;   # no time given -> prompt; leave flags in "$@"
    *)      shift ;;   # consume the time, leaving only flags in "$@"
  esac
  if [ -z "$hm" ]; then
    read -r -p "Wake time in 24h HH:MM (e.g. 09:40): " hm
  fi
  if ! [[ "$hm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    say "ERROR: '$hm' is not a valid HH:MM time."; exit 1
  fi
  local hour=$((10#${hm%%:*})) min=$((10#${hm##*:}))

  # Resolve the toggles now and bake the canonical flags into the agent.
  parse_feature_flags "$@"
  build_canonical_flags

  say "Scheduling wake for $WAKE_DAYS at $hm (needs admin password)..."
  # 'wake' = wake from sleep (FileVault stays unlocked). Mac must be ASLEEP.
  sudo pmset repeat wake "$WAKE_DAYS" "$hm:00"

  write_plist "$hour" "$min" "${CANON[@]}"
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"

  say
  say "Done - wake + routine scheduled at $hm, Mon-Fri."
  say "Enabled: slack=$FEAT_SLACK teams=$FEAT_TEAMS codex=$FEAT_CODEX claude=$FEAT_CLAUDE good-morning=$([ -n "$GM_TEXT" ] && echo "$GM_PLATFORM" || echo off)"
  say "Runtime script: $SELF"
  say "(If you move/rename this script, just run 'set' again.)"
  say
  say "Manual steps:"
  say "  * Keep the Mac ASLEEP (not shut down)."
  say "  * System Settings -> Lock Screen -> require password 'Never' (keeps FileVault on)."
  say
  pmset -g sched
  say
  say "Preflight (doctor) -- warnings do not block the schedule:"
  cmd_doctor "${CANON[@]}" || true
}

# ---- unset ----------------------------------------------------------------
cmd_unset() {
  say "Cancelling scheduled wake (needs admin password)..."
  sudo pmset repeat cancel
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  if stop_routine; then
    say "Stopped the in-flight routine (caffeinate + activity loop)."
  else
    say "No running routine to stop."
  fi
  rm -f "$CONTROLFILE"
  say "Removed the schedule and the LaunchAgent."
  say "(Lock Screen / FileVault settings you changed by hand are left as-is.)"
}

# ---- pause [DURATION] / resume --------------------------------------------
# Take a real break without shutting the routine down: pause stops the jiggle so
# you go idle (and show "Away"); the running loop notices within PAUSE_POLL_SECONDS.
cmd_pause() {
  local dur="${1:-}" until secs
  if [ -z "$dur" ]; then
    until=0                                   # indefinite, until 'resume'
  else
    if ! secs=$(parse_duration "$dur"); then
      say "ERROR: '$dur' is not a valid duration (e.g. 30m, 1h, 90s, or a number of minutes)."; exit 1
    fi
    until=$(( $(date +%s) + secs ))
  fi
  mkdir -p "$(dirname "$CONTROLFILE")"
  echo "$until" >"$CONTROLFILE"
  if [ "$until" -le 0 ]; then
    say "Paused indefinitely - you'll show 'Away' within ${PAUSE_POLL_SECONDS}s. Run 'resume' to come back."
  else
    say "Paused until $(date -r "$until" '+%H:%M') (auto-resumes then; or run 'resume')."
  fi
}

cmd_resume() {
  if [ -f "$CONTROLFILE" ]; then
    rm -f "$CONTROLFILE"
    say "Resumed - activity picks back up within ${PAUSE_POLL_SECONDS}s."
  else
    say "Not paused."
  fi
}

# ---- run (the routine the agent calls; not shown in help) -----------------
cmd_run() {
  parse_feature_flags "$@"
  rotate_log
  log "==== alibi-to-5 run starting ===="

  # Holiday / PTO skip: on a skip day, do not run at all -- the machine goes back
  # to sleep and you look genuinely offline. FAIL-OPEN: any lookup trouble falls
  # through to a normal run, since a false skip (looking offline on a real
  # workday) is the exact failure this tool exists to prevent.
  if [ "$FEAT_HOLIDAYS" = 1 ]; then
    local today skipdates
    today=$(date +%F)
    skipdates=$(load_skip_dates)
    if [ -n "$skipdates" ] && is_skip_day "$today" $skipdates; then
      log "Today ($today) is a skip day (holiday/PTO); not running."
      log "==== run done (skipped) ===="
      return 0
    fi
  fi

  # Fresh run: supersede any previous one and clear a stale pause (a pause never
  # carries into a new day). PIDFILE lists the caffeinate + loop PIDs for 'unset'.
  mkdir -p "$(dirname "$PIDFILE")"
  : >"$PIDFILE"
  rm -f "$CONTROLFILE"

  # Resolve today's window + (jittered) lunch + micro-breaks, record for 'status'.
  local i
  resolve_schedule
  { echo "window_end=$WINDOW_END_EPOCH"
    echo "lunch_start=$LUNCH_S_EPOCH"
    echo "lunch_end=$LUNCH_E_EPOCH"
    for i in ${!MB_S_EPOCHS[@]+"${!MB_S_EPOCHS[@]}"}; do
      echo "microbreak=${MB_S_EPOCHS[$i]}-${MB_E_EPOCHS[$i]}"
    done; } >"$STATEFILE"
  log "Window ends $(date -r "$WINDOW_END_EPOCH" '+%H:%M'); lunch $([ "$LUNCH_S_EPOCH" -gt 0 ] && echo "$(date -r "$LUNCH_S_EPOCH" '+%H:%M')-$(date -r "$LUNCH_E_EPOCH" '+%H:%M')" || echo off); micro-breaks ${#MB_S_EPOCHS[@]}."

  # 0. Keep the Mac awake. A scheduled wake on battery re-sleeps quickly
  #    otherwise; caffeinate holds display + system awake until the window end.
  #    It starts immediately (before any start-jitter) so we don't re-sleep.
  /usr/bin/caffeinate -dimsu -t "$CAFFEINATE_SECS" >>"$LOG" 2>&1 &
  echo "$!" >>"$PIDFILE"
  log "caffeinate started (pid $!): keeping awake for ~$((CAFFEINATE_SECS/3600))h."

  # 0b. Morning start jitter: hold off the visible activity a random 0..N seconds
  #     so "came online" varies day to day (caffeinate already holds the machine).
  if [ "$START_JITTER_MAX_SECONDS" -gt 0 ]; then
    local delay; delay=$(rand_between 0 "$START_JITTER_MAX_SECONDS")
    log "Start jitter: waiting ${delay}s before activity."
    sleep "$delay"
  fi

  # 1. Activity loop. Away status is driven by OS idle time (seconds since the
  #    last HID event); ANY event resets it, so distance is irrelevant and cadence
  #    is what matters. Each cycle asks should_jiggle (not lunch, not paused): if
  #    so, one jittered nudge then a random sleep; otherwise poll, letting the idle
  #    timer climb so you show "Away" through lunch/breaks, then resume.
  local cliclick
  cliclick="$(resolve_bin cliclick)"
  if [ -n "$cliclick" ]; then
    (
      while :; do
        now=$(date +%s)
        [ "$now" -ge "$WINDOW_END_EPOCH" ] && break
        if should_jiggle "$now" "$LUNCH_S_EPOCH" "$LUNCH_E_EPOCH" "$CONTROLFILE"; then
          px=$(rand_between "$JIGGLE_MIN_PIXELS" "$JIGGLE_MAX_PIXELS")
          [ $((RANDOM % 2)) -eq 0 ] && sign=+ || sign=-
          [ "$sign" = + ] && back=- || back=+
          if [ $((RANDOM % 2)) -eq 0 ]; then
            "$cliclick" "m:${sign}${px},+0" "m:${back}${px},+0" >/dev/null 2>&1
          else
            "$cliclick" "m:+0,${sign}${px}" "m:+0,${back}${px}" >/dev/null 2>&1
          fi
          sleep "$(rand_between "$JIGGLE_MIN_SECONDS" "$JIGGLE_MAX_SECONDS")"
        else
          sleep "$PAUSE_POLL_SECONDS"
        fi
      done
    ) >>"$LOG" 2>&1 &
    echo "$!" >>"$PIDFILE"
    log "Activity loop started (pid $!) via $cliclick (${JIGGLE_MIN_PIXELS}-${JIGGLE_MAX_PIXELS}px every ${JIGGLE_MIN_SECONDS}-${JIGGLE_MAX_SECONDS}s)."
  else
    log "WARNING: cliclick not found (brew install cliclick); jiggle skipped - Slack/Teams may show away."
  fi

  # 2. Open the apps: the Slack/Teams toggles plus any extra OPEN_APPS. The
  #    empty-array-safe expansion keeps this working under 'set -u' on macOS
  #    bash 3.2 even when the lists are empty.
  local app apps=()
  [ "$FEAT_SLACK" = 1 ] && apps+=("Slack")
  [ "$FEAT_TEAMS" = 1 ] && apps+=("Microsoft Teams")
  apps+=(${OPEN_APPS[@]+"${OPEN_APPS[@]}"})
  for app in ${apps[@]+"${apps[@]}"}; do
    if app_installed "$app"; then
      open -a "$app" >>"$LOG" 2>&1
      log "Opened $app."
    else
      log "WARNING: $app.app not found; skipped."
    fi
  done

  # 3. Ping the enabled CLIs to start their usage windows (headless, read-only:
  #    they only return text -- no file changes, no commands -- but the request
  #    starts a session, which begins the usage/rate-limit window).
  local codex claude
  if [ "$FEAT_CODEX" = 1 ]; then
    codex="$(resolve_bin codex)"
    if [ -n "$codex" ]; then
      "$codex" exec --sandbox read-only "$CODEX_PROMPT" >>"$LOG" 2>&1 &
      log "Codex '$CODEX_PROMPT' dispatched via $codex."
    else
      log "WARNING: codex CLI not found via login shell PATH; skipped."
    fi
  fi
  if [ "$FEAT_CLAUDE" = 1 ]; then
    claude="$(resolve_bin claude)"
    if [ -n "$claude" ]; then
      "$claude" -p "$CLAUDE_PROMPT" >>"$LOG" 2>&1 &
      log "Claude '$CLAUDE_PROMPT' dispatched via $claude."
    else
      log "WARNING: claude CLI not found via login shell PATH; skipped."
    fi
  fi

  # 4. Good-morning message, once the apps are up (no-op unless configured).
  send_good_morning "$GM_TEXT" "$GM_PLATFORM"

  log "==== run done ===="
}

# ---- doctor ---------------------------------------------------------------
# Surface the failures that are otherwise silent (most importantly: cliclick
# no-ops without an Accessibility grant, so the jiggle "runs" but you still go
# Away). Prints OK/WARN/FAIL lines; returns non-zero if a HARD check failed.
# 'set' also runs this in warn mode. Takes the same feature flags as run/set.
cmd_doctor() {
  parse_feature_flags "$@"
  rotate_log
  local hard_fail=0
  say "== alibi-to-5 doctor =="

  # (a) Accessibility ACTUALLY works: move the cursor and read it back. cliclick
  #     exits 0 without the grant but never moves, so movement is the only proof.
  local cliclick pos1 pos2
  cliclick="$(resolve_bin cliclick)"
  if [ -z "$cliclick" ]; then
    say "FAIL  cliclick not found (brew install cliclick) -- the jiggle can't run."
    hard_fail=1
  else
    pos1="$("$cliclick" p: 2>/dev/null)"
    "$cliclick" "m:+10,+0" >/dev/null 2>&1
    pos2="$("$cliclick" p: 2>/dev/null)"
    "$cliclick" "m:-10,+0" >/dev/null 2>&1        # restore the cursor
    if [ -n "$pos1" ] && [ "$pos1" != "$pos2" ]; then
      say "OK    Accessibility: cursor moved ($pos1 -> $pos2); grant is active."
    else
      say "FAIL  Accessibility: cursor did NOT move -- the jiggle will no-op and you"
      say "      will go Away. Grant your terminal/shell access in System Settings"
      say "      -> Privacy & Security -> Accessibility, then re-run 'doctor'."
      hard_fail=1
    fi
  fi

  # (b) Enabled CLI integrations resolve on the login-shell PATH.
  if [ "$FEAT_CODEX" = 1 ]; then
    if [ -n "$(resolve_bin codex)" ]; then say "OK    codex CLI resolves."
    else say "FAIL  codex enabled but not found on the login-shell PATH."; hard_fail=1; fi
  fi
  if [ "$FEAT_CLAUDE" = 1 ]; then
    if [ -n "$(resolve_bin claude)" ]; then say "OK    claude CLI resolves."
    else say "FAIL  claude enabled but not found on the login-shell PATH."; hard_fail=1; fi
  fi

  # (c) Good-morning webhook config -- PRESENCE ONLY, never a POST (no channel noise).
  if [ -n "$GM_TEXT" ]; then
    local var url
    case "$GM_PLATFORM" in teams) var=TEAMS_WEBHOOK_URL ;; *) var=SLACK_WEBHOOK_URL ;; esac
    if [ ! -f "$SECRETS_FILE" ]; then
      say "FAIL  good-morning set but $SECRETS_FILE is missing."; hard_fail=1
    else
      # shellcheck disable=SC1090
      url=$(. "$SECRETS_FILE" >/dev/null 2>&1; printf '%s' "${!var:-}")
      if [ -n "$url" ]; then say "OK    good-morning webhook ($var) is set."
      else say "FAIL  good-morning platform '$GM_PLATFORM' has no $var in $SECRETS_FILE."; hard_fail=1; fi
    fi
  fi

  # (d) Schedule + agent actually armed.
  if pmset -g sched 2>/dev/null | grep -q wake; then say "OK    repeating wake is registered (pmset)."
  else say "WARN  no repeating wake found -- run 'set'."; fi
  if launchctl list 2>/dev/null | grep -qi alibi-to-5; then say "OK    LaunchAgent is loaded."
  else say "WARN  LaunchAgent not loaded -- run 'set'."; fi

  # (e) Power source -- a ~9h caffeinate on battery is rough (warning only).
  if pmset -g batt 2>/dev/null | grep -q "'AC Power'"; then say "OK    on AC power."
  else say "WARN  on battery -- a full-day caffeinate will drain it."; fi

  # (f) Holiday lookup reachable, when enabled.
  if [ "$FEAT_HOLIDAYS" = 1 ] && [ -n "$FEAT_COUNTRY" ]; then
    if ensure_holiday_cache; then say "OK    holiday list cached for $FEAT_COUNTRY ($(date +%Y))."
    else say "WARN  holiday lookup for $FEAT_COUNTRY unavailable (fail-open: still runs)."; fi
  fi

  say
  if [ "$hard_fail" = 0 ]; then say "doctor: all hard checks passed."
  else say "doctor: one or more HARD checks FAILED (see FAIL lines above)."; fi
  return "$hard_fail"
}

# ---- test -----------------------------------------------------------------
cmd_test() {
  say "Running the routine now... (this starts the real ~9h caffeinate + jiggle)"
  cmd_run "$@"
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
  say "== Routine =="
  local pid running=0
  if [ -f "$PIDFILE" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && running=1
    done <"$PIDFILE"
  fi
  if [ "$running" = 1 ]; then
    say "running (caffeinate holding the Mac awake). Use 'unset' to stop it now."
  else
    say "not running."
  fi
  # Today's resolved window + lunch (written by the last 'run').
  if [ -f "$STATEFILE" ]; then
    local k v we="" ls="" le="" mbs mbe mblines="" now; now=$(date +%s)
    while IFS='=' read -r k v; do
      case "$k" in
        window_end) we=$v ;;
        lunch_start) ls=$v ;;
        lunch_end) le=$v ;;
        microbreak)
          mbs=${v%%-*}; mbe=${v##*-}
          mblines+="micro-break $(date -r "$mbs" '+%H:%M')-$(date -r "$mbe" '+%H:%M')$(in_window "$now" "$mbs" "$mbe" && echo ' (now)')"$'\n' ;;
      esac
    done <"$STATEFILE"
    [ -n "$we" ] && [ "$we" -gt 0 ] && say "active window until $(date -r "$we" '+%H:%M')."
    if [ -n "$ls" ] && [ "$ls" -gt 0 ]; then
      say "lunch gap $(date -r "$ls" '+%H:%M')-$(date -r "$le" '+%H:%M')$(in_window "$now" "$ls" "$le" && echo ' (now)')."
    fi
    [ -n "$mblines" ] && printf '%s' "$mblines"
  fi
  # Manual pause state.
  if is_paused "$CONTROLFILE" "$(date +%s)"; then
    local u; u=$(cat "$CONTROLFILE" 2>/dev/null)
    if [ "${u:-0}" -le 0 ]; then
      say "PAUSED (indefinite) - run 'resume' to come back."
    else
      say "PAUSED until $(date -r "$u" '+%H:%M') - or run 'resume'."
    fi
  fi
  say
  say "== Recent log =="
  tail -n 15 "$LOG" 2>/dev/null || say "(no log yet)"
}

# ---- dispatch -------------------------------------------------------------
main() {
  case "${1:-help}" in
    set)            shift; cmd_set "$@" ;;
    unset)          cmd_unset ;;
    run)            shift; cmd_run "$@" ;;   # internal: invoked by the LaunchAgent
    test)           shift; cmd_test "$@" ;;
    doctor)         shift; cmd_doctor "$@" ;;
    pause)          shift; cmd_pause "${1:-}" ;;
    resume)         cmd_resume ;;
    status)         cmd_status ;;
    help|-h|--help) usage ;;
    *) say "Unknown command: $1"; say; usage; exit 1 ;;
  esac
}

# Run only when executed directly (launchd does `bash <this> run`); skip when the
# file is sourced, so the functions above can be tested in isolation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
