# alibi-to-5 — backlog (brainstorm + plan next session)

These are queued for a `superpowers:brainstorming` → `superpowers:writing-plans`
pass before any implementation. Each has open questions to resolve during
brainstorming.

> **Status (2026-07-02).** Items **5 (Reliability & operability)** and **6 (More
> realism)** are now **SHIPPED** — see below. Item **1 (Linux)** is captured as a
> **Roadmap** section in the README (not implemented). Design:
> `docs/superpowers/specs/2026-07-02-reliability-and-realism-design.md`.
> Still open / not queued (revisit if wanted): an **external config file**
> (`~/.config/alibi-to-5/config` so the public script stays pristine across `git
> pull`), and an **integrations/flexibility** cluster (Slack presence/status via
> API, per-day & one-off schedule overrides, CI running shellcheck + the test
> suite on push).

## Shipped 2026-07-02 — humanize + workday shape + break controls
Randomized jiggle cadence/distance, random morning start delay, explicit
end-of-day (`--until`), jittered lunch gap (`--lunch`/`--no-lunch`), and on-demand
`pause [DURATION]` / `resume`. The activity loop is now one predicate
(`should_jiggle` = not lunch, not paused). Design:
`docs/superpowers/specs/2026-07-01-humanize-schedule-breaks-design.md`.
**To confirm on a real wake:** the loop honors lunch/pause transitions live, and
Away actually shows during lunch/pause. Deferred: time-shift work delivery (its
own tool), keystroke input, per-day distinct schedules.

## 0. Codex ping under launchd — TWO bugs, both FIXED; verify on next real wake
Two separate defects, one after the other:

**Bug A (PATH) — fixed 2026-07-01.** On the 2026-07-01 wake the ping was skipped
("codex CLI not found via login shell PATH"). Root cause: `resolve_bin` used
`/bin/zsh -lc` (login, non-interactive), but `~/.local/bin` (where `codex` lives)
is added in `~/.zshrc`, which zsh sources only for *interactive* shells — so under
launchd's minimal env the binary was never on PATH. Fixed by switching to an
interactive login shell (`-ilc`) + stdin from /dev/null.

**Bug B (process-group teardown) — fixed 2026-07-02.** On the 2026-07-02 wake the
binary resolved and the log showed "Codex 'are you there' dispatched", but the
message was never actually sent (no codex output ever followed in the log; "run
done" landed the same second). Root cause: `run()` launches all persistent work as
background jobs — caffeinate, the jiggle loop, AND the `codex exec`/`claude -p`
pings — then returns immediately. The generated LaunchAgent plist did not set
`AbandonProcessGroup`, so launchd flushes the job's process group when the main
`run` process exits and kills every backgrounded child. `codex exec` needs ~4s
(measured) but got ~0. Confirmed: this morning's caffeinate pid was already DEAD,
so caffeinate and the jiggle loop were being killed too (the machine could sleep /
show Away — a latent bug beyond just codex). Verified the mechanism with a
throwaway launchd pair: child KILLED without `AbandonProcessGroup`, SURVIVES with
`<true/>`. Fixed by emitting `<key>AbandonProcessGroup</key><true/>` in
`write_plist` (regression test added: 64/64 pass). The installed plist was
regenerated + reloaded so the fix is live.

**Still to confirm on a real scheduled wake:** `~/Library/Logs/alibi-to-5.log`
shows the codex reply text appended *after* "dispatched" (proof it completed, not
just launched), and the usage window resets ~5h after wake time. NOTE: `codex exec`
reads stdin ("Reading additional input from stdin...") — under launchd stdin is
/dev/null so it gets EOF and proceeds; fine, but keep in mind if behavior changes.

## 1. Linux support — captured in README Roadmap (not implemented)
Today the script is macOS-only. The mapping below now lives as a **Roadmap**
section in the README. Map each piece to a Linux equivalent and decide how to keep
one script vs. split by OS.
- Wake scheduling: `pmset repeat wake` → `rtcwake` / `/sys/class/rtc/rtc0/wakealarm`
  (note: RTC wake usually does a single alarm, not a recurring weekday schedule —
  may need a cron/systemd job that re-arms the next wake each day).
- Scheduler/agent: `launchd` plist → `systemd --user` timer or `cron`.
- Keep awake: `caffeinate` → `systemd-inhibit` / `caffeine` / GNOME inhibitor.
- Mouse jiggle: `cliclick` → `xdotool` (X11) or `ydotool` (Wayland). Wayland is the
  hard case (no global synthetic input without a compositor-specific path).
- Open apps: `open -a` → `xdg-open` / direct binary launch.
- **Open Qs:** support X11 only or Wayland too? One cross-platform script with an
  OS switch, or `alibi-to-5-macos.sh` / `alibi-to-5-linux.sh`? Distro/init
  assumptions (systemd-only?).

## 5. Reliability & operability — SHIPPED 2026-07-02
Shipped as the `doctor` subcommand (also run by `set` in warn mode) plus in-script
log rotation. `doctor` verifies the Accessibility grant by **moving the cursor and
reading it back** (the real silent failure), that enabled CLIs resolve, the
good-morning webhook is configured (presence only, no POST), the wake + agent are
armed, and that you're on AC power; it prints OK/WARN/FAIL and exits non-zero on a
hard failure. Log rotation caps `alibi-to-5.log` at `LOG_MAX_BYTES` (~5 MB) with a
single `.log.1` backup, at the top of `run`. **To confirm on a real machine with
cliclick installed:** `doctor` reports FAIL when Accessibility is revoked, OK when
granted, and restores the cursor.

Original notes (for reference):
Today several failures are silent (most importantly: `cliclick` no-ops without an
Accessibility grant, so the jiggle "runs" but the cursor never moves and you still
go Away). Add operability that surfaces these before a real wake.
- **`doctor` / preflight check:** verify (a) `cliclick` can actually move the
  cursor — Accessibility is granted, not just installed; (b) `cliclick`/`codex`/
  `claude` resolve via `resolve_bin`; (c) the secrets file exists and the chosen
  webhook is usable; (d) the wake + LaunchAgent are actually registered; (e) the
  Mac is on AC power (a 9h caffeinate on battery is rough).
- **Verify `set` took:** after scheduling, parse `pmset -g sched` + `launchctl
  list` and confirm the repeating wake and the agent really registered (fail loud
  if not).
- **Log rotation:** `~/Library/Logs/alibi-to-5.log` grows unbounded over months;
  cap it (size- or age-based).
- **Open Qs:** how to test the Accessibility grant reliably and non-interactively
  (nudge then read cursor position back via `cliclick p:` and compare?)? Is
  `doctor` a standalone subcommand, or does `set` run the preflight automatically?
  How to test webhook reachability without spamming the channel (a one-off "test"
  post? Slack has no silent ping)? Log-rotation mechanism — in-script truncation
  vs `newsyslog.d` vs `logrotate`-style?

## 6. More realism — SHIPPED 2026-07-02
Shipped: **holiday/PTO skip** (on a skip day `run` exits before `caffeinate` — the
Mac sleeps and you look offline; public holidays pulled from the Nager.Date API
for `COUNTRY_CODE`, cached per year, dependency-free parse, plus manual
`EXTRA_SKIP_DATES`; `--no-holidays` per schedule; fail-open on any lookup trouble)
and **micro-breaks** (up to `MICROBREAK_MAX_COUNT` short 4–12m Away gaps/day,
non-overlapping, avoiding lunch, honored by `should_jiggle`, shown by `status`).
**Wake-time jitter** was decided already-satisfied by the existing
`START_JITTER_MAX_SECONDS` (keeps the "set once" model; documented, no new code).
**To confirm on a real wake:** a configured holiday / `EXTRA_SKIP_DATES` entry
skips the day, and micro-breaks actually produce short Away periods then resume.

Original notes (for reference):
Extend the humanization beyond the lunch gap and per-nudge jitter.
- **Holiday / skip-dates awareness:** don't look "active" on company holidays or
  PTO — a mid-week, all-day-active machine on a holiday is a red flag.
- **Random micro-breaks:** occasional short "Away" periods sprinkled through the
  day (coffee/bathroom breaks), beyond the single lunch gap.
- **Wake-time jitter:** vary the wake by ±N minutes so it isn't the identical
  minute every day.
- **Open Qs:** holidays — a manual skip-dates list in config, or pull from a
  calendar/API? On a skip day, don't run at all, or run but deliberately stay
  Away? Micro-breaks — frequency and length ranges (keep each under the away-
  detection window so they read as normal, not disconnected)? Wake-time jitter —
  `pmset repeat wake` is a single fixed time, so jitter means the routine must
  compute and re-arm the *next* day's wake on each run, which breaks the current
  "set once" model; decide whether that's worth it vs. jittering only the activity
  start (already done) and leaving the hardware wake fixed.

## 2. Microsoft Teams support — DONE (2026-07-01)
Shipped as the `--teams` / `--no-teams` toggle (`ENABLE_TEAMS`, default off):
appends `"Microsoft Teams"` to the effective open list. Design decision: idle-
timer reset via the existing 60s jiggle is treated as sufficient (Teams away
threshold ~5 min), no window-focus logic added. **Still to confirm on a real
wake:** that Teams actually stays "Available" with only the jiggle — if it flips
to Away, revisit (focus/foreground or a Teams presence setting) as a follow-up.

## 3. Claude support — DONE (2026-07-01)
Shipped as the `--claude` / `--no-claude` toggle (`ENABLE_CLAUDE`, default off):
headless `claude -p "$CLAUDE_PROMPT"` via the same `resolve_bin` (`-ilc`) helper,
mirroring the Codex ping. Chosen meaning: CLI usage-window ping only (not opening
the desktop app). **To confirm during first real use:** that plain `-p` is the
right no-side-effects invocation and the usage window actually starts.

## 4. "Good morning" message — DONE (2026-07-01)
Shipped as `--good-morning "TEXT"` + `--gm-platform slack|teams` (`GOOD_MORNING_TEXT`
empty = off). Decisions from brainstorming: Slack/Teams **incoming webhook**
(`curl`, `{"text":…}` payload), URL kept out of the repo in
`~/.config/alibi-to-5/secrets` (gitignored; `secrets.example` shipped), content is
user-supplied on `set` with `{time}/{date}/{day}` tokens, posted after apps open.
**To confirm on a real wake:** an actual post lands in the target channel; mind the
Teams Workflows/Adaptive-Card caveat noted in the README if using Teams.
Deferred (out of scope): API-token transport and DM-to-self.

See `docs/superpowers/specs/2026-07-01-feature-toggles-design.md` for the design.

## Cross-cutting
- Keep the single-script + subcommand shape; new behavior should stay config-driven
  (constants at top), matching the existing style.
- Anything needing secrets (webhooks/tokens) must not be committed — the repo is
  private now but intended to go public.
