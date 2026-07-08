#!/bin/bash
#
# Unit tests for alibi-to-5.sh pure helpers. Sources the script (its bottom
# guard means main() does NOT run on source) and asserts on the functions that
# have no side effects: JSON escaping, greeting token interpolation, feature
# flag parsing, and the canonical-flag serialization that set() bakes into the
# plist. The launchd / webhook / `open -a` paths need a real wake and are
# verified manually, not here.
#
# Run: bash test/alibi-to-5.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Pin the .env path so a real ~/.config/alibi-to-5/.env can't skew the
# default-value assertions below.
export ALIBI_ENV_FILE=/dev/null
# shellcheck disable=SC1091
source "$HERE/../alibi-to-5.sh"

pass=0
fail=0
check() { # check <desc> <expected> <actual>
  local desc="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then
    pass=$((pass + 1)); printf 'ok   - %s\n' "$desc"
  else
    fail=$((fail + 1)); printf 'FAIL - %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$exp" "$act"
  fi
}

# ---- json_escape ----------------------------------------------------------
check "json_escape: plain text untouched" 'hello world' "$(json_escape 'hello world')"
check "json_escape: double quotes escaped" 'say \"hi\"' "$(json_escape 'say "hi"')"
check "json_escape: backslash doubled" 'a\\b' "$(json_escape 'a\b')"
check "json_escape: newline -> \\n" 'a\nb' "$(json_escape "$(printf 'a\nb')")"
check "json_escape: tab -> \\t" 'a\tb' "$(json_escape "$(printf 'a\tb')")"
check "json_escape: backslash before quote (order)" '\\\"' "$(json_escape '\"')"

# ---- xml_escape (for baking greeting text into the plist) -----------------
check "xml_escape: plain untouched" 'hello' "$(xml_escape 'hello')"
check "xml_escape: ampersand" 'a &amp; b' "$(xml_escape 'a & b')"
check "xml_escape: angle brackets" '&lt;tag&gt;' "$(xml_escape '<tag>')"
check "xml_escape: ampersand before entity (order)" '&amp;lt;' "$(xml_escape '&lt;')"

# ---- interpolate ----------------------------------------------------------
check "interpolate: no tokens untouched" 'plain morning' "$(interpolate 'plain morning')"
check "interpolate: {day}" "$(date '+%A')" "$(interpolate '{day}')"
check "interpolate: {date}" "$(date '+%Y-%m-%d')" "$(interpolate '{date}')"
check "interpolate: unknown token left as-is" 'hi {nope}' "$(interpolate 'hi {nope}')"
check "interpolate: mixed" "online $(date '+%A')" "$(interpolate 'online {day}')"

# ---- parse_feature_flags: defaults (every feature off) ---------------------
parse_feature_flags
check "defaults: slack off"    0        "$FEAT_SLACK"
check "defaults: teams off"    0        "$FEAT_TEAMS"
check "defaults: codex off"    0        "$FEAT_CODEX"
check "defaults: claude off"   0        "$FEAT_CLAUDE"
check "defaults: gm text empty" ''      "$GM_TEXT"
check "defaults: gm platform"  slack    "$GM_PLATFORM"

# ---- .env file: overrides defaults, flags still win ------------------------
envtmp=$(mktemp)
printf 'ENABLE_CODEX=1\nSLACK_WEBHOOK_URL="https://example.invalid/hook"\n' >"$envtmp"
env_out=$(ALIBI_ENV_FILE="$envtmp" bash -c '
  source "'"$HERE"'/../alibi-to-5.sh"
  parse_feature_flags
  codex_env=$FEAT_CODEX
  parse_feature_flags --no-codex
  echo "$codex_env $FEAT_CODEX $SLACK_WEBHOOK_URL"')
rm -f "$envtmp"
check ".env: overrides default, flag wins, webhook sourced" \
  "1 0 https://example.invalid/hook" "$env_out"

# ---- parse_feature_flags: overrides ---------------------------------------
parse_feature_flags --no-slack --teams --no-codex --claude --good-morning 'hi {day}' --gm-platform teams
check "override: slack off"    0            "$FEAT_SLACK"
check "override: teams on"     1            "$FEAT_TEAMS"
check "override: codex off"    0            "$FEAT_CODEX"
check "override: claude on"    1            "$FEAT_CLAUDE"
check "override: gm text"      'hi {day}'   "$GM_TEXT"
check "override: gm platform"  teams        "$GM_PLATFORM"

# ---- canonical serialization round-trips ----------------------------------
parse_feature_flags --no-slack --teams --codex --claude --good-morning 'morning {time}' --gm-platform teams
build_canonical_flags   # fills CANON=(...)
parse_feature_flags "${CANON[@]}"
check "roundtrip: slack off"   0                "$FEAT_SLACK"
check "roundtrip: teams on"    1                "$FEAT_TEAMS"
check "roundtrip: codex on"    1                "$FEAT_CODEX"
check "roundtrip: claude on"   1                "$FEAT_CLAUDE"
check "roundtrip: gm text"     'morning {time}' "$GM_TEXT"
check "roundtrip: gm platform" teams            "$GM_PLATFORM"

# canonical output omits the greeting flags when no greeting is set
parse_feature_flags --no-good-morning
build_canonical_flags
case " ${CANON[*]} " in
  *" --good-morning "*) check "canonical: no gm flag when empty" yes no ;;
  *)                    check "canonical: no gm flag when empty" yes yes ;;
esac

# ---- rand_between ----------------------------------------------------------
check "rand_between: lo==hi" 7 "$(rand_between 7 7)"
check "rand_between: hi<lo returns lo" 5 "$(rand_between 5 2)"
rb_ok=yes
for _ in $(seq 1 200); do
  v=$(rand_between 3 9)
  { [ "$v" -ge 3 ] && [ "$v" -le 9 ]; } || rb_ok=no
done
check "rand_between: 200 draws stay in [3,9]" yes "$rb_ok"

# ---- in_window (0=inside) --------------------------------------------------
in_window 150 100 200 && iw=in || iw=out; check "in_window: inside"      in  "$iw"
in_window 100 100 200 && iw=in || iw=out; check "in_window: start incl." in  "$iw"
in_window 200 100 200 && iw=in || iw=out; check "in_window: end excl."   out "$iw"
in_window  50 100 200 && iw=in || iw=out; check "in_window: before"      out "$iw"
in_window 150 0   0   && iw=in || iw=out; check "in_window: zero window" out "$iw"
in_window 150 ''  ''  && iw=in || iw=out; check "in_window: empty window" out "$iw"

# ---- is_paused (0=paused) --------------------------------------------------
CF="$(mktemp)"; rm -f "$CF"
is_paused "$CF" 1000 && p=y || p=n; check "is_paused: missing file -> no" n "$p"
printf '0\n'    >"$CF"; is_paused "$CF" 1000 && p=y || p=n; check "is_paused: 0 = indefinite" y "$p"
printf '2000\n' >"$CF"; is_paused "$CF" 1000 && p=y || p=n; check "is_paused: before until"   y "$p"
printf '2000\n' >"$CF"; is_paused "$CF" 3000 && p=y || p=n; check "is_paused: after until"    n "$p"
rm -f "$CF"

# ---- parse_duration -> seconds --------------------------------------------
check "parse_duration: 30m" 1800 "$(parse_duration 30m)"
check "parse_duration: 90s" 90   "$(parse_duration 90s)"
check "parse_duration: 1h"  3600 "$(parse_duration 1h)"
check "parse_duration: bare = minutes" 2700 "$(parse_duration 45)"
parse_duration abc >/dev/null 2>&1 && d=ok || d=rej; check "parse_duration: junk rejected" rej "$d"

# ---- hm_to_epoch (light) ---------------------------------------------------
e1=$(hm_to_epoch 09:00); e2=$(hm_to_epoch 17:00)
case "$e1" in ''|*[!0-9]*) hm=bad ;; *) hm=num ;; esac
check "hm_to_epoch: numeric epoch" num "$hm"
[ "${e2:-0}" -gt "${e1:-0}" ] && ord=ok || ord=bad
check "hm_to_epoch: later time is larger" ok "$ord"

# ---- parse_once_datetime (set-once validation) -----------------------------
FUTURE_DATE=$(date -v+1y +%Y-%m-%d)   # always in the future, regardless of when tests run
resolved=$(parse_once_datetime "$FUTURE_DATE" "09:30") && pod=ok || pod=rej
check "parse_once_datetime: valid future date accepted" ok "$pod"
read -r y _ _ ho mi ep <<<"$resolved"
check "parse_once_datetime: year field"   "${FUTURE_DATE%%-*}" "$y"
check "parse_once_datetime: hour field"   9  "$ho"
check "parse_once_datetime: minute field" 30 "$mi"
case "$ep" in ''|*[!0-9]*) check "parse_once_datetime: epoch is numeric" num bad ;; *) check "parse_once_datetime: epoch is numeric" num num ;; esac

parse_once_datetime "2020-01-01" "09:30" >/dev/null 2>&1 && pod=ok || pod=rej
check "parse_once_datetime: past date rejected" rej "$pod"
parse_once_datetime "not-a-date" "09:30" >/dev/null 2>&1 && pod=ok || pod=rej
check "parse_once_datetime: malformed date rejected" rej "$pod"
parse_once_datetime "$FUTURE_DATE" "25:99" >/dev/null 2>&1 && pod=ok || pod=rej
check "parse_once_datetime: malformed time rejected" rej "$pod"
parse_once_datetime "2026-02-30" "09:30" >/dev/null 2>&1 && pod=ok || pod=rej
check "parse_once_datetime: invalid calendar date rejected" rej "$pod"

# ---- resolve_next_hm (set-once auto-date) ----------------------------------
FUTURE_HM="23:59"   # last minute of the day: still ahead of "now" except in that minute itself
resolved=$(resolve_next_hm "$FUTURE_HM") && rn=ok || rn=rej
check "resolve_next_hm: future-today time accepted" ok "$rn"
read -r ds _ _ _ _ _ _ <<<"$resolved"
check "resolve_next_hm: future-today time picks today" "$(date +%F)" "$ds"

PAST_HM="00:01"   # first minute of the day: already passed except in that minute itself
resolved=$(resolve_next_hm "$PAST_HM") && rn=ok || rn=rej
check "resolve_next_hm: past-today time accepted" ok "$rn"
read -r ds _ _ _ _ _ _ <<<"$resolved"
check "resolve_next_hm: past-today time picks tomorrow" "$(date -v+1d +%F)" "$ds"

resolve_next_hm "25:99" >/dev/null 2>&1 && rn=ok || rn=rej
check "resolve_next_hm: malformed time rejected" rej "$rn"

# ---- schedule flags: parse + canonical round-trip -------------------------
parse_feature_flags --until 17:00 --lunch 13:00/40
check "flags: until"        17:00 "$FEAT_UNTIL"
check "flags: lunch start"  13:00 "$FEAT_LUNCH_START"
check "flags: lunch length" 40    "$FEAT_LUNCH_MIN"
parse_feature_flags --no-lunch
check "flags: no-lunch clears start" '' "$FEAT_LUNCH_START"

parse_feature_flags --until 16:30 --lunch 12:45/50
build_canonical_flags
parse_feature_flags "${CANON[@]}"
check "roundtrip: until"        16:30 "$FEAT_UNTIL"
check "roundtrip: lunch start"  12:45 "$FEAT_LUNCH_START"
check "roundtrip: lunch length" 50    "$FEAT_LUNCH_MIN"

# ---- holiday-skip flag: parse, default, canonical round-trip --------------
parse_feature_flags
check "holidays: default off" 0 "$FEAT_HOLIDAYS"
parse_feature_flags --no-holidays
check "holidays: --no-holidays off" 0 "$FEAT_HOLIDAYS"
parse_feature_flags --no-holidays --holidays
check "holidays: --holidays back on" 1 "$FEAT_HOLIDAYS"
# canonical is fully explicit either way, and round-trips
parse_feature_flags --no-holidays; build_canonical_flags
case " ${CANON[*]} " in *" --no-holidays "*) hz=y ;; *) hz=n ;; esac
check "holidays: canonical emits --no-holidays" y "$hz"
parse_feature_flags "${CANON[@]}"
check "holidays: round-trip off" 0 "$FEAT_HOLIDAYS"

# ---- country flag: parse, default, canonical round-trip -------------------
parse_feature_flags
check "country: default matches config" "$COUNTRY_CODE" "$FEAT_COUNTRY"
parse_feature_flags --country PT
check "country: --country sets code" PT "$FEAT_COUNTRY"
# canonical emits --country when set, and round-trips
parse_feature_flags --country US; build_canonical_flags
case " ${CANON[*]} " in *" --country US "*) cf=y ;; *) cf=n ;; esac
check "country: canonical emits --country US" y "$cf"
parse_feature_flags "${CANON[@]}"
check "country: round-trip" US "$FEAT_COUNTRY"
# empty country emits no --country flag (holiday lookup simply disabled)
parse_feature_flags --country ''; build_canonical_flags
case " ${CANON[*]} " in *" --country "*) cf=y ;; *) cf=n ;; esac
check "country: canonical omits --country when empty" n "$cf"

# ---- resolve_schedule: micro-break placement invariants -------------------
# Nondeterministic (like the lunch jitter), so assert the invariants that must
# ALWAYS hold across many rolls: parallel arrays stay in step, count <= max,
# every break sits inside the active window, has positive length, and never
# overlaps the lunch gap.
mb_ok=yes
for _ in $(seq 1 60); do
  parse_feature_flags --until 23:59 --lunch 13:00/45   # wide window so breaks can fit
  resolve_schedule
  [ "${#MB_S_EPOCHS[@]}" -eq "${#MB_E_EPOCHS[@]}" ] || mb_ok=no
  [ "${#MB_S_EPOCHS[@]}" -le "$MICROBREAK_MAX_COUNT" ] || mb_ok=no
  for i in "${!MB_S_EPOCHS[@]}"; do
    bs=${MB_S_EPOCHS[$i]}; be=${MB_E_EPOCHS[$i]}
    [ "$be" -gt "$bs" ] || mb_ok=no                                   # positive length
    [ "$be" -le "$WINDOW_END_EPOCH" ] || mb_ok=no                     # inside the window
    # not overlapping the lunch gap
    if [ "$LUNCH_S_EPOCH" -gt 0 ] && [ "$bs" -lt "$LUNCH_E_EPOCH" ] && [ "$be" -gt "$LUNCH_S_EPOCH" ]; then
      mb_ok=no
    fi
  done
done
check "resolve_schedule: micro-break invariants hold over 60 rolls" yes "$mb_ok"

# ---- write_plist: launchd survival + shape --------------------------------
# The agent backgrounds long-lived work (caffeinate, the jiggle loop) and the
# CLI pings, then run() exits. Without AbandonProcessGroup launchd flushes the
# job's process group on that exit and kills every backgrounded child, so the
# machine sleeps, you go Away, and the codex/claude usage-window ping never
# lands. The plist MUST opt out of the process-group flush.
PLIST_PATH="$(mktemp)"
write_plist 9 30 --slack --no-teams --codex
grep -q '<key>AbandonProcessGroup</key>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist: sets AbandonProcessGroup key" y "$wp"
# the key must actually be true (a <false/> would still kill the children)
awk '/<key>AbandonProcessGroup<\/key>/{getline; print}' "$PLIST_PATH" | grep -q '<true/>' && wp=y || wp=n
check "write_plist: AbandonProcessGroup is true" y "$wp"
grep -q '<string>run</string>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist: still invokes run" y "$wp"
grep -q '<key>Weekday</key>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist: weekly schedule uses Weekday" y "$wp"
grep -q '<key>Year</key>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist: weekly schedule has no Year key" n "$wp"
rm -f "$PLIST_PATH"

# ---- write_plist_once: single guaranteed-once fire -------------------------
# Year (not just Month/Day/Hour/Minute) must be baked in, or launchd would
# refire this same wake next year -- that's the whole point of 'set-once'.
PLIST_PATH="$(mktemp)"
write_plist_once 2026 7 9 9 30 --codex
grep -q '<key>AbandonProcessGroup</key>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist_once: sets AbandonProcessGroup key" y "$wp"
grep -q '<key>Year</key><integer>2026</integer>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist_once: bakes in the Year" y "$wp"
grep -q '<key>Month</key><integer>7</integer>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist_once: bakes in the Month" y "$wp"
grep -q '<key>Day</key><integer>9</integer>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist_once: bakes in the Day" y "$wp"
grep -q '<key>Weekday</key>' "$PLIST_PATH" && wp=y || wp=n
check "write_plist_once: no recurring Weekday key" n "$wp"
rm -f "$PLIST_PATH"

# ---- log_needs_rotation (0 = rotate) --------------------------------------
log_needs_rotation 100 200 && r=y || r=n; check "log_needs_rotation: under cap"      n "$r"
log_needs_rotation 200 200 && r=y || r=n; check "log_needs_rotation: exactly at cap" n "$r"
log_needs_rotation 201 200 && r=y || r=n; check "log_needs_rotation: over cap"        y "$r"
log_needs_rotation '' 200  && r=y || r=n; check "log_needs_rotation: empty size (no file)" n "$r"
log_needs_rotation 0 0     && r=y || r=n; check "log_needs_rotation: zero cap disables"     n "$r"

# ---- is_skip_day (0 = skip) -----------------------------------------------
is_skip_day 2026-07-04 2026-01-01 2026-07-04 2026-12-25 && s=y || s=n
check "is_skip_day: date in list"      y "$s"
is_skip_day 2026-07-03 2026-01-01 2026-07-04 && s=y || s=n
check "is_skip_day: date not in list"  n "$s"
is_skip_day 2026-07-04 && s=y || s=n
check "is_skip_day: empty list -> no"  n "$s"
# a substring must not false-match (whole-token compare)
is_skip_day 2026-07-0 2026-07-04 && s=y || s=n
check "is_skip_day: no substring match" n "$s"

# ---- extract_holiday_dates (parse Nager.Date JSON, dependency-free) --------
FIX='[{"date":"2026-01-01","localName":"New Year"},{"date":"2026-07-04","name":"x"}]'
check "extract_holiday_dates: two dates" "$(printf '2026-01-01\n2026-07-04')" "$(extract_holiday_dates "$FIX")"
check "extract_holiday_dates: empty in -> empty" '' "$(extract_holiday_dates '[]')"
# only YYYY-MM-DD shaped values, not other date-like fields
FIX2='[{"date":"2026-03-15","counties":null,"launchYear":1990}]'
check "extract_holiday_dates: ignores non-date numbers" '2026-03-15' "$(extract_holiday_dates "$FIX2")"

# ---- in_microbreak (0 = inside a resolved micro-break window) -------------
MB_S_EPOCHS=(1000 3000); MB_E_EPOCHS=(1500 3500)
in_microbreak 1200 && m=y || m=n; check "in_microbreak: inside first"  y "$m"
in_microbreak 3400 && m=y || m=n; check "in_microbreak: inside second" y "$m"
in_microbreak 2000 && m=y || m=n; check "in_microbreak: between"       n "$m"
in_microbreak 1500 && m=y || m=n; check "in_microbreak: end excl."     n "$m"
MB_S_EPOCHS=(); MB_E_EPOCHS=()
in_microbreak 1200 && m=y || m=n; check "in_microbreak: no windows"    n "$m"

# should_jiggle also honors micro-breaks (composes in_microbreak)
MB_S_EPOCHS=(1000); MB_E_EPOCHS=(1500)
NOCF="$(mktemp)"; rm -f "$NOCF"
should_jiggle 1200 0 0 "$NOCF" && j=y || j=n; check "should_jiggle: no during micro-break" n "$j"
should_jiggle 2000 0 0 "$NOCF" && j=y || j=n; check "should_jiggle: yes outside micro-break" y "$j"
MB_S_EPOCHS=(); MB_E_EPOCHS=()

# ---- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
