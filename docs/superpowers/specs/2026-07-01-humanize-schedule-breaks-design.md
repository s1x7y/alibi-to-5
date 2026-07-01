# alibi-to-5 — humanized activity, schedule shape & break controls (2026-07-01)

Second feature pass. Goal: make the "active" alibi look **human** rather than
robotic, give it a real workday shape (end time + lunch), and add on-demand
break controls — for people who deliver their work on a shifted schedule and
just need presence monitoring not to flag the difference. Builds on the toggle
system from the first pass; keeps the single-script shape.

## A. Unified activity loop (core change)

Today's jiggle loop nudges unconditionally every 60s. It becomes a loop whose
each cycle asks **"should I look active right now?"**:

    should_jiggle = NOT in the lunch gap AND NOT manually paused

- If yes: one *jittered* nudge, then sleep a *random* interval.
- If no (lunch/paused): skip the nudge, sleep a short poll interval
  (`PAUSE_POLL_SECONDS`, default 30s) so activity resumes promptly.
- The loop exits when `now >= WINDOW_END_EPOCH`.

`caffeinate` still holds the machine awake across the whole window; only the
*jiggle* pauses, so during lunch/pause the OS idle timer climbs and you naturally
show **Away**, then come back. (caffeinate generates no HID events, so this
holds — same reasoning as the README's "why a mouse jiggle".)

## B. Humanize the footprint

- **Jittered cadence:** interval random in `[JIGGLE_MIN_SECONDS,
  JIGGLE_MAX_SECONDS]` (default **45–120s**, safely under the ~5min Teams Away
  threshold) instead of exactly 60s.
- **Jittered movement:** distance random in `[JIGGLE_MIN_PIXELS,
  JIGGLE_MAX_PIXELS]` (default 1–8), random axis (x/y) and sign, always returning
  to origin. Mouse-only — no new deps or permissions.
- **Morning start jitter:** `caffeinate` starts immediately at wake (so the Mac
  doesn't re-sleep), then a random `0..START_JITTER_MAX_SECONDS` (default 0–10min)
  delay before apps/pings/jiggle begin, so "came online" time varies day to day.

## C. Human schedule shape

- **Active window end:** `--until HH:MM` (config `WORK_END`). End-time wins;
  falls back to the existing `KEEP_AWAKE_SECONDS` duration when unset or invalid,
  or when the time has already passed. `caffeinate -t` is derived from the
  resolved end (`WINDOW_END_EPOCH - now`).
- **Jittered lunch gap:** `--lunch HH:MM` or `--lunch HH:MM/MINUTES` (config
  `LUNCH_START`/`LUNCH_MINUTES`, default length 45), `--no-lunch` to disable.
  Start and length each get ±`LUNCH_JITTER_MINUTES` (default 10), rolled once per
  run, clamped to the window. During lunch the jiggle pauses → Away → resume.

Defaults keep both **off** (`WORK_END=""`, `LUNCH_START=""`) so a bare
`set 07:45` keeps today's ~9h behavior, now just with humanized jitter.

## D. Manual break controls (new subcommands)

- **`pause [DURATION]`** — stop looking active now. `DURATION` = `30m`/`1h`/`90s`/
  bare-minutes; **no argument = indefinite**. Writes `CONTROLFILE` with a
  "paused-until" epoch (`0` = indefinite). The loop polls it each cycle.
- **`resume`** — remove `CONTROLFILE`; activity resumes within ~`PAUSE_POLL_SECONDS`.
- `run` clears any stale `CONTROLFILE` at start (a pause never carries to a new
  day). `unset` clears `CONTROLFILE` + `STATEFILE`.

## E. Flags, files & status

New flags fold into `parse_feature_flags` + `build_canonical_flags`, baked into
the plist like the rest: `--until`, `--lunch`, `--no-lunch`. Example:

    set 07:45 --teams --until 17:00 --lunch 13:00

Files (all under `~/Library/Logs/`):
- `PIDFILE` — now records the caffeinate PID **and** the loop PID. `stop_routine`
  kills by recorded PID with an identity check (`ps` command contains
  `alibi-to-5` or `caffeinate -dimsu`), replacing the old fixed-`-t` pkill match
  (the `-t` value is now dynamic).
- `CONTROLFILE` (`alibi-to-5.control`) — pause state.
- `STATEFILE` (`alibi-to-5.state`) — resolved `window_end`/`lunch_start`/
  `lunch_end` epochs, so `status` can report the day's window, lunch times, and
  current active/lunch/paused state.

Jitter ranges and start-jitter stay config constants (rarely tuned).

## F. Testability

Pure helpers, unit-tested first (TDD):
- `rand_between LO HI` — result within `[LO,HI]`; `LO==HI` and `HI<LO` edge cases.
- `in_window NOW START END` — inclusive-start/exclusive-end; empty/zero/invalid
  windows are "not in window".
- `is_paused CONTROLFILE NOW` — missing file, indefinite (`0`), timed (before/
  after `until`).
- `parse_duration STR` — `30m`/`1h`/`90s`/bare-minutes → seconds; rejects junk.
- new flag parsing + canonical round-trip for `--until`/`--lunch`/`--no-lunch`.
- `hm_to_epoch HH:MM` — light check (numeric, later time → larger epoch).

`resolve_schedule`, the loop, `pause`/`resume`, and `status` compose these atop
`date`/`caffeinate`/`cliclick` and are verified with `bash -n` + targeted runs.

## Out of scope

Time-shift work delivery (its own tool), keystroke input, per-day distinct
schedules, Linux.
