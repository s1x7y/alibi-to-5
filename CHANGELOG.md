# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Config file `~/.config/alibi-to-5/.env` (see `.env.example`): override any
  default — feature toggles, workday shape, webhook URLs — without editing the
  script. Precedence: flags > `.env` > script defaults.

### Changed
- **Breaking:** every feature toggle now defaults to OFF (Slack, Teams, Codex,
  Claude, holiday skip). Opt in per feature via flags or the `.env` file.
- **Breaking:** the separate secrets file (`~/.config/alibi-to-5/secrets`) is
  replaced by the `.env` file; move your webhook URL(s) there.

### Fixed
- The wake-time Codex ping never opened a usage window: `codex exec` refused to
  run from the LaunchAgent's untrusted cwd and waited on stdin. Now runs with
  `--skip-git-repo-check` and stdin closed (Claude ping got the same stdin
  guard).
- Slack/Teams could silently fail to open on a fresh wake (`open -a` reporting
  success even though the app never stayed running) with no trace in the log.
  Now checks `open`'s exit code and confirms the app is still running 2s
  later, logging a `WARNING` either way instead of a blind "Opened".

## [1.0.0] - 2026-07-02

First public release.

### Added
- Weekday wake scheduling via `pmset`, installed as a `launchd` agent (`set` / `unset`).
- Keep-awake routine: `caffeinate` plus a real `cliclick` mouse jiggle so Slack/Teams
  stay active on OS idle time (randomized cadence and distance).
- Humanized workday: morning start drift, an end time (`--until`), a jittered lunch
  gap (`--lunch` / `--no-lunch`), and short random micro-breaks.
- Public-holiday / PTO skipping via the Nager.Date API (`--holidays`, `--country`,
  `EXTRA_SKIP_DATES`).
- App launching for Slack (`--slack`) and Teams (`--teams`); Codex (`--codex`) and
  Claude (`--claude`) CLI usage-window pings.
- Optional good-morning webhook post (`--good-morning`, `--gm-platform`) with a
  secret URL kept out of the repo.
- On-demand `pause` / `resume`, a `status` view, a `doctor` preflight, and a
  `test` runner.

[Unreleased]: https://github.com/s1x7y/alibi-to-5/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/s1x7y/alibi-to-5/releases/tag/v1.0.0
