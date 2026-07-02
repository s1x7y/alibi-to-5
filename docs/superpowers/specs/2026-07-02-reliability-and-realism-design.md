# alibi-to-5 — reliability & realism (backlog items 5 + 6)

Design for the next batch of work: surface silent-failure modes (item 5,
"Reliability & operability") and further humanize the footprint (item 6, "More
realism"). Item 1 (Linux support) is *not* implemented here — it is recorded as a
Roadmap section in the README.

Constraints carried from the project: single script + subcommands, behavior stays
config-driven (constants at top), dependency-free where practical, pure predicates
unit-tested via the sourceable suite, side-effecting paths verified on a real wake.
Nothing needing secrets is committed (the repo is intended to go public).

## 1. `doctor` / preflight (item 5)

New `doctor` subcommand that surfaces the failures which are silent today. `set`
runs the same checks automatically after scheduling: it warns loudly on any
problem but still completes (so a missing grant never blocks arming). Standalone
`doctor` exits non-zero if any hard check fails.

Checks:

- **(a) Accessibility actually works** — the most important silent failure:
  `cliclick` no-ops without an Accessibility grant, so the jiggle "runs" but the
  cursor never moves and you still go Away. Test by *moving and reading back*:
  record the cursor position (`cliclick p:`), issue a small relative nudge, read
  the position again, compare, then **restore the cursor to its original
  position**. Movement proves the grant; a no-grant `cliclick` exits 0 but the
  position is unchanged. Only run when `cliclick` resolves.
- **(b) Binaries resolve** — for each *enabled* integration, confirm the binary
  resolves via `resolve_bin` (`cliclick` when jiggle is needed; `codex`/`claude`
  when their toggles are on).
- **(c) Webhook config (presence only, no POST)** — when good-morning is enabled,
  confirm `SECRETS_FILE` exists and the chosen `SLACK_WEBHOOK_URL` /
  `TEAMS_WEBHOOK_URL` is non-empty. No network call, so `doctor` never posts to
  the channel.
- **(d) Schedule armed** — `pmset -g sched` shows the repeating wake and
  `launchctl list` shows the agent loaded.
- **(e) On AC power** — `pmset -g batt`; warn if on battery (a ~9h caffeinate on
  battery is rough). Warning, not a hard failure.

Output is a checklist of `OK` / `WARN` / `FAIL` lines. Hard failures (a, b, and c
when good-morning is on) set a non-zero exit for standalone `doctor`; power (e) is
always a warning. `set` prints the same lines and proceeds regardless.

## 2. Log rotation (item 5)

`~/Library/Logs/alibi-to-5.log` grows unbounded over months. New constant
`LOG_MAX_BYTES` (~5 MB). At the top of `run` (and cheaply at the top of `doctor`),
if the log exceeds the cap, move it to a single `.log.1` backup (overwriting the
previous backup) and start a fresh log. In-script, size-based, no external config
— matches the single-script ethos. The size decision is a pure predicate
(`log_needs_rotation <bytes> <cap>`), unit-tested; the file move itself is trivial
and side-effecting.

## 3. Holiday / PTO skip (item 6)

Don't look active on public holidays or PTO — a mid-week, all-day-active machine on
a holiday is a red flag.

Config:

- `ENABLE_HOLIDAY_SKIP=1` — master toggle; `--no-holidays` on `set` disables it for
  a given schedule (baked into the agent like the other flags).
- `COUNTRY_CODE=""` — ISO-3166 alpha-2 (e.g. `US`, `PT`). Empty = holiday lookup
  disabled (only `EXTRA_SKIP_DATES` apply).
- `EXTRA_SKIP_DATES=()` — manual `YYYY-MM-DD` list for PTO / one-offs an API can't
  know. (A public-holiday API covers holidays only; PTO must be manual.)

Source: the [Nager.Date](https://date.nager.at) public API (no key required):
`GET https://date.nager.at/api/v3/PublicHolidays/<year>/<COUNTRY_CODE>` returns a
JSON array of `{"date":"YYYY-MM-DD", ...}`. Dates are extracted with a hand-rolled
grep (dependency-free, like `json_escape`) and cached to
`~/.config/alibi-to-5/holidays-<YYYY>.json`, so the network is hit ~once per year.

Behavior:

- Early in `run` (before caffeinate), if today ∈ (cached holidays ∪
  `EXTRA_SKIP_DATES`), log the reason and **exit immediately** — no caffeinate, no
  jiggle. The machine returns to sleep and you look genuinely offline, which is the
  correct footprint for a holiday/PTO day.
- **Fail-open:** if `ENABLE_HOLIDAY_SKIP=0`, `COUNTRY_CODE` is empty, the cache is
  absent and the fetch fails, or the network is unreachable, **do not skip** — run
  normally. A false skip (looking offline on a real workday) is the exact failure
  this tool exists to prevent, and is worse than being active on a holiday.

Units: `is_skip_day <today-ymd> <dates…>` is a pure predicate (unit-tested), as is
the JSON date extraction (`extract_holiday_dates` over a fixture string). The
network fetch + caching is side-effecting and verified manually, like the webhook
path.

## 4. Micro-breaks (item 6)

Occasional short "Away" periods sprinkled through the day (coffee/bathroom),
beyond the single lunch gap.

Config:

- `MICROBREAK_MAX_COUNT=3` — up to N micro-breaks per day (0 disables).
- `MICROBREAK_MIN_MINUTES=4` / `MICROBREAK_MAX_MINUTES=12` — each break's length is
  random in this range, kept **under** the Slack away threshold (~10m) so they read
  as brief natural gaps, not a disconnect. (Max should stay ≤ ~10.)

`resolve_schedule` rolls a random count (0..`MICROBREAK_MAX_COUNT`) of
non-overlapping micro-break windows placed within the active window, avoiding the
lunch gap, and records them in the state file for `status`. The activity loop's
`should_jiggle` gains an `in_microbreak` check (looping the resolved windows) so
you naturally show Away during each, then resume — same predicate-composition style
as lunch and pause. `in_microbreak` is a pure predicate over the resolved windows
(unit-tested); the random placement is exercised via `resolve_schedule`'s existing
manual/real-wake verification plus a sanity unit check that windows stay within the
day and don't overlap lunch.

## 5. Wake-time jitter (item 6)

Already satisfied by the existing `START_JITTER_MAX_SECONDS` (a random 0..N-second
delay before visible activity begins, caffeinate already holding the machine). This
keeps the "set once" model — `pmset repeat wake` is a single fixed time, and
re-arming the next day's hardware wake on every run to jitter it would break that
model, require sudo/pmset on each run, and add real failure surface for little
gain. No new code; documented as the intentional approach.

## 6. Linux support (item 1) — Roadmap only

Not implemented in this pass. Added as a **Roadmap** section in the README so the
mapping isn't lost:

- Wake scheduling: `pmset repeat wake` → `rtcwake` / `wakealarm` (RTC wake is a
  single alarm, so a cron/systemd job must re-arm the next weekday's wake).
- Scheduler/agent: `launchd` → `systemd --user` timer or `cron`.
- Keep awake: `caffeinate` → `systemd-inhibit` / GNOME inhibitor.
- Mouse jiggle: `cliclick` → `xdotool` (X11) / `ydotool` (Wayland — the hard case).
- Open apps: `open -a` → `xdg-open` / direct binary launch.

## Testing & style

- New pure predicates — `is_skip_day`, `extract_holiday_dates`,
  `log_needs_rotation`, `in_microbreak` — get unit tests in
  `test/alibi-to-5.test.sh`, sourced via the existing `BASH_SOURCE` guard.
- Side-effecting paths — the holiday fetch/cache, `doctor`'s live cursor/pmset/
  launchctl checks — are verified on a real wake or by running `doctor`, matching
  how the webhook and launchd paths are handled today.
- Everything stays single-script, config-constants-at-top, with a `--flag` only
  where a per-schedule toggle is meaningful (`--no-holidays`).

## Real-wake / manual verifications this adds

- `doctor` correctly reports FAIL when Accessibility is revoked, OK when granted,
  and restores the cursor.
- On a configured holiday (or an `EXTRA_SKIP_DATES` entry), a real wake logs the
  skip and the machine does not stay awake.
- Micro-break windows actually produce short Away periods and then resume.
- Log rotation triggers once the log crosses `LOG_MAX_BYTES` (a single `.log.1`
  backup appears).
