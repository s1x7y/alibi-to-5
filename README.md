<p align="center">
  <img src="assets/banner.png" alt="alibi-to-5 — Presence Assurance System. Always online, never here." width="100%">
</p>

# alibi-to-5

<p align="center">
  <a href="https://github.com/s1x7y/alibi-to-5/actions/workflows/ci.yml"><img src="https://github.com/s1x7y/alibi-to-5/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="Platform: macOS">
  <img src="https://img.shields.io/badge/made%20with-bash-1f425f.svg?logo=gnubash&logoColor=white" alt="Made with Bash">
  <img src="https://img.shields.io/badge/status-always%20online-brightgreen" alt="Status: always online">
</p>

*Your Mac clocks in so you can catch the tide.*

Built by a surfer. Good waves don't check whether standup is at 9 — some mornings
the tide's up at seven, other days not until two. I've never missed a meeting or a
deadline, and every manager I've had called me a great employee. But a few of them
policed the green dot like a time card: *"why weren't you online at 9?"* This keeps
that dot green so those managers stay happy, while you're out on the water, chasing
your own hobby, or just sleeping in.

One script wakes your Mac on weekdays and, on wake, keeps it awake, keeps your
Slack/Teams status green (a real mouse jiggle), opens your apps, starts your
Codex/Claude usage windows, and optionally posts a good-morning message. It even
takes a jittered lunch, sprinkles in short coffee breaks, and skips public holidays
— because a machine active nine hours straight, 365 days a year, fools nobody.

Do the work on your own clock; let the dot handle the optics.

## Run it

```
brew bundle                 # installs cliclick
chmod +x alibi-to-5.sh
./alibi-to-5.sh set 07:45   # arm it (asks for your admin password, for pmset)
```

That's the only command you type. Put the Mac to **sleep** (not shut down) and
macOS runs the routine every weekday. Two one-time macOS settings:

- **Lock Screen → require password: Never**, so wake-from-sleep skips the login
  screen (FileVault stays on; auto-login can't).
- **Accessibility** grant for your terminal (Privacy & Security → Accessibility),
  or the jiggle silently no-ops and you go Away anyway. Run
  `./alibi-to-5.sh doctor` to confirm it actually moves the cursor.

## Commands

| Command | What it does |
|---------|--------------|
| `set [HH:MM] [flags]` | Arm the weekday wake + routine. Prompts for the time if omitted. Re-run to change it. |
| `unset` | Cancel the schedule and stop a running routine. |
| `test [flags]` | Run the routine right now. |
| `doctor [flags]` | Preflight: Accessibility, CLIs, webhook, schedule, power. `set` runs it too. |
| `pause [DURATION]` / `resume` | Go Away for a bit (`30m` / `1h` / `90s`, or until `resume`), then come back. |
| `status` | Show the schedule, today's window/lunch/breaks, and recent log. |
| `help` | Usage. |

## Flags

Pass to `set` (or `test`). Each is baked into the schedule, so it sticks on every
wake. **Every feature is off by default** — opt in per feature, either with a flag
or in the config file (below).

| Flag | What it does | Default |
|------|--------------|---------|
| `--slack` / `--no-slack` | Open Slack | off |
| `--teams` / `--no-teams` | Open Microsoft Teams | off |
| `--codex` / `--no-codex` | Ping the Codex CLI usage window | off |
| `--claude` / `--no-claude` | Ping the Claude CLI usage window | off |
| `--until HH:MM` | End the active day at this time | ~9h |
| `--lunch HH:MM[/MIN]` / `--no-lunch` | Idle lunch gap, `MIN` min long, jittered daily | off |
| `--holidays` / `--no-holidays` | Skip public-holiday / PTO days entirely | off |
| `--country CC` | ISO-3166 country for the holiday lookup (e.g. `US`, `PT`) | — |
| `--good-morning "TEXT"` | Post `TEXT` to a webhook after apps open (`{time}` / `{date}` / `{day}` tokens) | off |
| `--gm-platform slack\|teams` | Which webhook the greeting uses | slack |

```
./alibi-to-5.sh set 09:40 --teams --until 17:00 --lunch 13:00 --country PT \
              --good-morning "Online {day} {time}"
```

## Config file

Anything the flags cover — plus finer knobs (jiggle cadence/distance, start
jitter, micro-break count/length, `EXTRA_SKIP_DATES` for PTO, log-size cap) —
can be set once in `~/.config/alibi-to-5/.env` instead, so you never edit the
script or retype flags:

```
mkdir -p ~/.config/alibi-to-5
cp .env.example ~/.config/alibi-to-5/.env   # then uncomment what you want
chmod 600 ~/.config/alibi-to-5/.env
```

Precedence: flags on `set`/`test` > `.env` > script defaults. The `.env` also
holds the webhook URLs, so keep it `chmod 600` and out of any repo (`.gitignore`
already excludes `.env`).

## Why the mouse jiggle

`caffeinate` keeps the Mac awake but generates no input, and Slack/Teams mark you
Away on **OS idle time** (seconds since your last HID event). Only a real event
resets it. So `cliclick` nudges the cursor a few pixels and back, more often than
the Away threshold (Teams ~5 min, Slack ~10 min). Distance is irrelevant; cadence
is everything. Both are randomized so it isn't a metronome.

## Looking human

Nothing fires like clockwork: randomized nudge timing/distance, a 0–10 min morning
start drift, a jittered lunch, and a few short "away" micro-breaks. On holidays and
PTO dates it doesn't run at all. Any app or CLI that isn't installed is skipped
with a log line, never a crash.

## Good-morning webhook

Needs a URL kept out of the repo — set `SLACK_WEBHOOK_URL` (or
`TEAMS_WEBHOOK_URL`) in `~/.config/alibi-to-5/.env` (see the Config file section).

Missing URL → the greeting is skipped and the rest of the wake runs fine.
(Teams is retiring classic incoming webhooks in favor of Workflows, which want an
Adaptive Card payload — a plain-text post may not render there.)

## Use responsibly

alibi-to-5 nudges *your own* mouse on *your own* Mac. It doesn't bypass security,
touch your employer's systems, or exfiltrate anything. It's for people who deliver
their work and would rather presence indicators reflect that than a 9-o'clock green
dot. Check your organization's acceptable-use policy, and don't use it to bill
hours you didn't work or dodge real obligations — how you use it is on you.

## License

[MIT](LICENSE).

## Acknowledgments

alibi-to-5 builds on tools it doesn't bundle — you install them separately:

- **[cliclick](https://github.com/BlueM/cliclick)** by Carsten Blüm (BSD-3-Clause) —
  the scriptable cursor movement behind the jiggle.
- **[Nager.Date](https://date.nager.at)** — the public-holiday API used to skip
  holidays (one cached lookup per country per year).

It also leans on macOS built-ins (`caffeinate`, `pmset`, `launchctl`, `open`, `curl`)
and, optionally, the Codex and Claude CLIs.

## Notes

- macOS only (`pmset` / `caffeinate` / `launchctl` / `open`). Laptops should be
  plugged in. Logs go to `~/Library/Logs/alibi-to-5.log` (rotated at ~5 MB).
- **Linux** is on the roadmap — the mapping (`rtcwake`, `systemd`/`cron`,
  `systemd-inhibit`, `xdotool`/`ydotool`) lives in `BACKLOG.md`.
