# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
