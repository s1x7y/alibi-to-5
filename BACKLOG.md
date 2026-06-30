# alibi-to-5 — backlog (brainstorm + plan next session)

These are queued for a `superpowers:brainstorming` → `superpowers:writing-plans`
pass before any implementation. Each has open questions to resolve during
brainstorming.

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

## 2. Microsoft Teams support
Mostly config + a doc note, but verify the "active" behavior.
- Add `"Microsoft Teams"` to `OPEN_APPS` (and confirm the exact .app name).
- Confirm the cliclick jiggle keeps Teams "Available" (Teams away threshold ~5 min;
  default 60s interval already clears it). Test the real status.
- **Open Qs:** does Teams need the window focused/foreground, or is idle-timer
  reset enough? Any Teams setting that overrides presence (e.g. "show as Away when
  inactive for X")?

## 3. Claude support
By analogy to the Codex usage-window ping.
- **Open Qs:** what does "Claude support" mean here — (a) ping the Claude Code CLI
  headlessly to start a usage window (like `codex exec`), (b) open the Claude
  desktop app via `OPEN_APPS`, or (c) both? If CLI: confirm the exact non-
  interactive command + a read-only/no-side-effects equivalent. Resolve the binary
  via the same `resolve_bin` login-shell trick.

## 4. "Good morning" message
Send a greeting as part of the wake routine.
- **Open Qs (need answers before design):**
  - Destination: a Slack message (DM to self? a channel?), a Teams message, a macOS
    notification, spoken via `say`, or just a log line?
  - If Slack/Teams: via the desktop app (hard to script reliably) or an API/webhook
    (needs a token/webhook URL — secret handling, and keep it out of the public repo)?
  - Content: static text, time-aware, or dynamic?
  - Timing: at wake, or slightly after apps open?
- Note: the user referenced "point 2 of the notes" — clarify which note they meant;
  current README notes don't describe a message feature.

## Cross-cutting
- Keep the single-script + subcommand shape; new behavior should stay config-driven
  (constants at top), matching the existing style.
- Anything needing secrets (webhooks/tokens) must not be committed — the repo is
  private now but intended to go public.
