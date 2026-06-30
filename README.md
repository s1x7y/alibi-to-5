# alibi-to-5

*Your nine-to-five alibi.* Wake your Mac on weekdays at a time you choose, and on wake automatically keep
it awake, **keep your status "active" in Slack/Teams** (via a real mouse
jiggle), open your apps, and start a Codex usage window — all from **one
script**.

```
alibi-to-5.sh set 07:45      # arm it once
```

That's the only command you normally type. macOS handles the rest every weekday.

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
  Teams flips to Away after ~5 min, Slack after ~10 min. The default interval is
  **60s**, well under both.

Both are editable (`JIGGLE_PIXELS`, `JIGGLE_INTERVAL_SECONDS`) at the top of the
script.

## Commands

| Command | What it does |
|---------|--------------|
| `alibi-to-5.sh set [HH:MM]` | **Arm it:** schedule the Mon–Fri wake and install the LaunchAgent. Prompts for the time if you omit it. Re-run to change the time. |
| `alibi-to-5.sh unset` | **Disarm it:** cancel the schedule and remove the agent. |
| `alibi-to-5.sh test` | Run the wake routine right now, then print the recent log. |
| `alibi-to-5.sh status` | Show the schedule, agent state, and recent log. |
| `alibi-to-5.sh help` | Usage. |

You only ever type `set` (and later `unset`). When the Mac wakes, macOS calls
the script back internally to run the routine — you never invoke that yourself.

## How it works

1. `set 07:45` runs `pmset repeat wake MTWRF 07:45:00` so macOS **wakes the Mac**
   every weekday at that time, and installs a **LaunchAgent** that runs the wake
   routine on each of those wakes.
2. The wake routine:
   - **`caffeinate`** holds the Mac awake (~9h) so the session stays alive.
   - **`cliclick`** jiggles the mouse so Slack/Teams stay active (see above).
   - **Opens your apps** — everything in `OPEN_APPS` (default: Slack).
   - **Pings Codex** — `codex exec --sandbox read-only "are you there"` to start
     its usage window. Read-only, so it just returns text. Optional: if `codex`
     isn't found, this step is skipped with a logged warning.
3. `unset` cancels the wake and removes the agent.

Logs go to `~/Library/Logs/alibi-to-5.log`.

## Requirements

- **macOS** (uses `pmset`, `caffeinate`, `launchctl`, `open`).
- **[`cliclick`](https://github.com/BlueM/cliclick)** for the mouse jiggle.
- *(optional)* the **Codex CLI** for the usage-window ping.

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
- All tunables (wake days, caffeinate duration, jiggle cadence/distance, the app
  list, the Codex prompt) are plain constants at the top of `alibi-to-5.sh`.
