# alibi-to-5 — backlog (brainstorm + plan next session)

These are queued for a `superpowers:brainstorming` → `superpowers:writing-plans`
pass before any implementation. Each has open questions to resolve during
brainstorming.

## Shipped 2026-07-02 — humanize + workday shape + break controls
Randomized jiggle cadence/distance, random morning start delay, explicit
end-of-day (`--until`), jittered lunch gap (`--lunch`/`--no-lunch`), and on-demand
`pause [DURATION]` / `resume`. The activity loop is now one predicate
(`should_jiggle` = not lunch, not paused). Design:
`docs/superpowers/specs/2026-07-01-humanize-schedule-breaks-design.md`.
**To confirm on a real wake:** the loop honors lunch/pause transitions live, and
Away actually shows during lunch/pause. Deferred: time-shift work delivery (its
own tool), keystroke input, per-day distinct schedules.

## 0. Codex ping under launchd — FIXED, verify on next real wake
On the 2026-07-01 wake the Codex ping was skipped ("codex CLI not found via login
shell PATH"); the usage window did not start at wake (reset drifted to first manual
use). Root cause: `resolve_bin` used `/bin/zsh -lc` (login, non-interactive), but
`~/.local/bin` (where `codex` lives) is added in `~/.zshrc`, which zsh sources only
for *interactive* shells — so under launchd's minimal env the binary was never on
PATH. Fixed by switching to an interactive login shell (`-ilc`) + stdin from
/dev/null. Verified in a simulated clean/tty-less env; **still to confirm on a real
scheduled wake** — check `~/Library/Logs/alibi-to-5.log` shows "Codex '...'
dispatched" (not the "not found" warning) and that the usage window resets 5h after
wake time.

## 1. Linux support
Today the script is macOS-only. Map each piece to a Linux equivalent and decide
how to keep one script vs. split by OS.
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
