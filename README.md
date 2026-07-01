# alibi-to-5

*Your nine-to-five alibi.* Wake your Mac on weekdays at a time you choose, and on wake automatically keep
it awake, **keep your status "active" in Slack/Teams** (via a real mouse
jiggle), open your apps, start Codex/Claude usage windows, and optionally post a
good-morning message — all from **one script**.

It's for people who deliver their work on a **shifted schedule** and just need
presence monitoring not to flag the difference. So the activity is built to look
**human, not robotic**: randomized nudge cadence and distance, a random morning
start, an optional **lunch gap** where you naturally show "Away", a real
**end-of-day**, and on-demand **`pause`/`resume`** for breaks.

```
alibi-to-5.sh set 07:45      # arm it once
```

That's the only command you normally type. macOS handles the rest every weekday.

Every integration is an independent **toggle** — a config default at the top of
the script, plus a `--flag` / `--no-flag` you can pass to `set`. Defaults keep
Slack and the Codex ping on, Teams and Claude off, and no greeting, so a bare
`set 07:45` behaves exactly as before.

## Why a mouse jiggle?

Keeping the Mac *awake* (with `caffeinate`) is **not** enough to stay "active"
in Slack or Teams. Those apps mark you **Away** based on **OS idle time** — the
number of seconds since your last real mouse/keyboard (HID) event. `caffeinate`
generates no input, so the idle timer keeps climbing and you still go Away.

The only thing that resets it is an actual input event. So the routine uses
[`cliclick`](https://github.com/BlueM/cliclick) to nudge the cursor a few pixels
and move it straight back on a short interval. Two facts worth knowing:

- **Distance doesn't matter.** Any HID event resets the idle timer to zero, so a
  3px nudge works exactly like a 300px one. The cursor returns to where it was.
- **Cadence matters.** The nudge must fire more often than the Away threshold —
  Teams flips to Away after ~5 min, Slack after ~10 min.

To avoid a metronome-like footprint, both are **randomized per nudge**: a random
distance (default **1–8px**, random axis/direction) at a random interval
(default **45–120s**, comfortably under both Away thresholds). The ranges are
editable (`JIGGLE_MIN_PIXELS`/`JIGGLE_MAX_PIXELS`,
`JIGGLE_MIN_SECONDS`/`JIGGLE_MAX_SECONDS`) at the top of the script.

## Commands

| Command | What it does |
|---------|--------------|
| `alibi-to-5.sh set [HH:MM] [flags]` | **Arm it:** schedule the Mon–Fri wake and install the LaunchAgent. Prompts for the time if you omit it. Re-run to change the time or flags. |
| `alibi-to-5.sh unset` | **Disarm it:** cancel the schedule and remove the agent. |
| `alibi-to-5.sh test [flags]` | Run the wake routine right now (with the given flags), then print the recent log. |
| `alibi-to-5.sh pause [DURATION]` | **Take a break:** stop looking active now (you go "Away"). No `DURATION` = until `resume`; else `30m` / `1h` / `90s` / a plain number of minutes. |
| `alibi-to-5.sh resume` | End a pause and pick activity back up. |
| `alibi-to-5.sh status` | Show the schedule, agent state, today's window/lunch, pause state, and recent log. |
| `alibi-to-5.sh help` | Usage. |

You only ever type `set` (and later `unset`), plus `pause`/`resume` when you want
a break. When the Mac wakes, macOS calls the script back internally to run the
routine — you never invoke that yourself.

## Feature flags

Pass these to `set` (or `test`). Each overrides its config default, and the
resolved choice is **baked into the LaunchAgent**, so it applies on every wake
without editing the script:

| Flag | Effect | Default |
|------|--------|---------|
| `--slack` / `--no-slack` | Open `Slack.app` on wake | on |
| `--teams` / `--no-teams` | Open `Microsoft Teams.app` on wake | off |
| `--codex` / `--no-codex` | Ping the Codex CLI to start its usage window | on |
| `--claude` / `--no-claude` | Ping the Claude CLI to start its usage window | off |
| `--good-morning "TEXT"` | Post `TEXT` to a Slack/Teams webhook after apps open | off |
| `--gm-platform slack\|teams` | Which webhook the greeting uses | slack |
| `--until HH:MM` | End the active window at this time (else ~9h duration) | off |
| `--lunch HH:MM[/MIN]` | Idle lunch gap, `MIN` minutes long (default 45), jittered daily | off |
| `--no-lunch` | Disable the lunch gap | — |

```
alibi-to-5.sh set 09:40 --teams --claude --until 17:00 --lunch 13:00 \
              --good-morning "Online {day} {time}"
```

The greeting text supports `{time}`, `{date}`, and `{day}` tokens, filled in at
wake. Prefer editing the defaults instead? They're plain constants
(`ENABLE_SLACK`, `ENABLE_TEAMS`, `ENABLE_CODEX`, `ENABLE_CLAUDE`,
`GOOD_MORNING_TEXT`, `GOOD_MORNING_PLATFORM`) at the top of the script.

## Good-morning message

When a greeting is configured, the routine POSTs it to a **Slack or Teams
incoming webhook** after your apps open. The webhook URL is a secret, so it
lives **outside the repo** in `~/.config/alibi-to-5/secrets` — a shell file that
the routine sources at wake:

```
mkdir -p ~/.config/alibi-to-5
cp secrets.example ~/.config/alibi-to-5/secrets   # then edit in your real URL(s)
chmod 600 ~/.config/alibi-to-5/secrets
```

```sh
# ~/.config/alibi-to-5/secrets
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
# TEAMS_WEBHOOK_URL="https://…/IncomingWebhook/…"
```

If the file or the relevant URL is missing, the greeting is skipped with a
logged warning — the rest of the wake routine is never blocked by it.

> **Slack:** create an [Incoming Webhook](https://api.slack.com/messaging/webhooks)
> for the channel you want; it posts a simple `{"text": …}` payload.
>
> **Teams:** classic Office 365 *Incoming Webhook* connectors accept the same
> `{"text": …}` payload, but Microsoft is retiring them in favor of **Workflows**,
> which expect an Adaptive Card payload instead. If you use a Workflows URL, a
> plain-text post may not render — check Teams' current webhook docs.

## Looking human: workday shape & breaks

A perfectly regular signal — same wake minute, same nudge every 60s, active for
exactly 9h straight — is itself a tell. So beyond the randomized nudges, the
routine shapes itself like a real workday:

- **Random morning start.** `caffeinate` starts immediately (so the Mac doesn't
  re-sleep), but the visible activity waits a random **0–10 min**
  (`START_JITTER_MAX_SECONDS`), so your "came online" time drifts day to day.
- **End of day.** `--until 17:00` (config `WORK_END`) ends the active window at a
  real time; otherwise it falls back to the ~9h duration.
- **Lunch gap.** `--lunch 13:00` (optionally `13:00/45` for length; config
  `LUNCH_START` / `LUNCH_MINUTES`) makes the jiggle **pause** mid-day, with a few
  minutes of random jitter on the start and length each day. During lunch your
  idle timer climbs and you show **Away** — like a real person — then you resume.
  `--no-lunch` turns it off.

### Taking a break

Step away whenever you want, without tearing anything down:

```
alibi-to-5.sh pause 30m     # go "Away" for 30 minutes, then auto-resume
alibi-to-5.sh pause         # go "Away" until you come back
alibi-to-5.sh resume        # ...come back now
```

`pause` just stops the jiggle so your status naturally goes Away; the running
routine notices within ~30s (`PAUSE_POLL_SECONDS`). `status` shows whether you're
paused and until when. A pause never carries into the next day — each wake starts
fresh.

## How it works

1. `set 07:45` runs `pmset repeat wake MTWRF 07:45:00` so macOS **wakes the Mac**
   every weekday at that time, and installs a **LaunchAgent** that runs the wake
   routine on each of those wakes.
2. The wake routine (each step gated by its toggle):
   - **`caffeinate`** holds the Mac awake until the window end (`--until`, else
     ~9h) so the session stays alive.
   - After a **random start delay**, the **activity loop** begins: each cycle,
     if you're not at lunch and not paused, it does one randomized `cliclick`
     nudge and waits a random interval; otherwise it lets you show Away.
   - **Opens the enabled apps** — Slack and/or Teams (per toggle), plus anything
     you add to `OPEN_APPS`.
   - **Pings Codex** — `codex exec --sandbox read-only "are you there"` to start
     its usage window. Read-only, so it just returns text.
   - **Pings Claude** — `claude -p "are you there"` (headless) to start its usage
     window, when `--claude` is enabled.
   - **Posts the good-morning message** to a webhook, when configured.

   Any CLI/app that isn't installed is skipped with a logged warning — a missing
   piece never blocks the rest of the routine.
3. `unset` cancels the wake, removes the agent, and stops a running routine.

Logs go to `~/Library/Logs/alibi-to-5.log`.

## Requirements

- **macOS** (uses `pmset`, `caffeinate`, `launchctl`, `open`).
- **[`cliclick`](https://github.com/BlueM/cliclick)** for the mouse jiggle.
- *(optional)* the **Codex CLI** and/or **Claude CLI** for the usage-window pings.
- *(optional)* a **Slack/Teams incoming webhook URL** for the good-morning
  message (`curl` ships with macOS).

Install the dependencies with [Homebrew](https://brew.sh):

```
brew bundle      # reads the Brewfile in this folder; installs cliclick
```

> **Accessibility permission:** macOS may require a one-time **Accessibility**
> grant before synthetic mouse events take effect (System Settings → Privacy &
> Security → Accessibility). Because the jiggle runs under a LaunchAgent, if you
> notice the cursor isn't moving on wake, grant Accessibility to the controlling
> process and re-run `set`.

## Setup

1. **Install dependencies:** `brew bundle`
2. **Make the script executable:** `chmod +x alibi-to-5.sh`
3. **Arm it:** `./alibi-to-5.sh set 07:45` (asks for your admin password, for
   `pmset`).
4. **Get past the lock screen while keeping FileVault on.** FileVault only asks
   for a password at a full power-on. On **wake from sleep** the disk is already
   unlocked, so you only face the normal lock screen. To pass it:
   - Keep the Mac **asleep, not shut down**.
   - System Settings → **Lock Screen** → "Require password after screen saver
     begins or display is turned off" → **Never**.

   (FileVault and automatic login can't both be on — macOS blocks it — so use
   this sleep route rather than auto-login.)

## Daily use

Just put the Mac to **sleep** (Apple menu → Sleep, or close the lid) — don't
shut it down. On the next weekday wake, the routine handles the mouse jiggle and
opens your apps automatically. No manual toggling needed.

## Test it now (no waiting)

```
./alibi-to-5.sh test
```

This runs the real routine immediately (so it starts the ~9h caffeinate + the
jiggle loop) and prints the log. Your apps should open and the cursor should
jiggle. To stop the lingering caffeinate/jiggle from a test, log out/in or
`pkill caffeinate` / `pkill cliclick`.

## Change the time

Re-run `./alibi-to-5.sh set 08:15`.

## Remove everything

```
./alibi-to-5.sh unset
```

(Lock Screen / FileVault settings you changed by hand must be reverted manually
in System Settings.)

## Notes

- Wake uses `pmset repeat wake MTWRF HH:MM`; check it with `pmset -g sched`.
  Because it's a *wake* (not a power-on), the Mac must be **asleep** — not shut
  down — at that time. Laptops should be plugged in.
- The LaunchAgent uses `StartCalendarInterval` (Mon–Fri at the wake time), so it
  fires on wake-from-sleep even while you're already logged in.
- All tunables (wake days, fallback duration, jiggle cadence/distance ranges,
  start-jitter, pause poll interval, workday end + lunch start/length/jitter, the
  feature toggles, the extra app list, the Codex/Claude prompts, the greeting and
  its platform, the secrets path) are plain constants at the top of
  `alibi-to-5.sh`.
- Feature choices are stored **in the LaunchAgent** (as the arguments it passes
  to `run`), not in a separate state file — so the schedule keeps its flags even
  if you later change the config defaults. Re-run `set` to change them.
