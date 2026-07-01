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

# ---- parse_feature_flags: defaults ----------------------------------------
parse_feature_flags
check "defaults: slack on"     1        "$FEAT_SLACK"
check "defaults: teams off"    0        "$FEAT_TEAMS"
check "defaults: codex on"     1        "$FEAT_CODEX"
check "defaults: claude off"   0        "$FEAT_CLAUDE"
check "defaults: gm text empty" ''      "$GM_TEXT"
check "defaults: gm platform"  slack    "$GM_PLATFORM"

# ---- parse_feature_flags: overrides ---------------------------------------
parse_feature_flags --no-slack --teams --no-codex --claude --good-morning 'hi {day}' --gm-platform teams
check "override: slack off"    0            "$FEAT_SLACK"
check "override: teams on"     1            "$FEAT_TEAMS"
check "override: codex off"    0            "$FEAT_CODEX"
check "override: claude on"    1            "$FEAT_CLAUDE"
check "override: gm text"      'hi {day}'   "$GM_TEXT"
check "override: gm platform"  teams        "$GM_PLATFORM"

# ---- canonical serialization round-trips ----------------------------------
parse_feature_flags --no-slack --teams --claude --good-morning 'morning {time}' --gm-platform teams
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

# ---- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
