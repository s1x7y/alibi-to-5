# Contributing

Thanks for your interest. `alibi-to-5` is a single, dependency-light Bash script,
and the goal is to keep it that way.

## Before you start

- Open an issue first for anything non-trivial, so we can agree on the approach.
- Keep changes minimal. This project favors the simplest thing that works over
  new abstractions or dependencies.

## Development

Requirements: `bash`, [`shellcheck`](https://www.shellcheck.net/), and macOS to
exercise the real wake/jiggle paths (the unit tests themselves are pure Bash).

Run the two checks CI runs:

```sh
shellcheck --severity=warning alibi-to-5.sh test/alibi-to-5.test.sh
bash test/alibi-to-5.test.sh
```

Both must pass. Add a test in `test/alibi-to-5.test.sh` for any behavior you
change or add.

## Style

- POSIX-ish Bash; keep it readable and match the surrounding code.
- Quote variables. Where word-splitting is intentional, add a
  `# shellcheck disable=SCxxxx` with a one-line reason.
- New user-facing flags: wire them through parsing **and** the canonical
  round-trip, document them in the README table, and cover them with a test.

## Pull requests

- One focused change per PR.
- Update the README and `CHANGELOG.md` (under `Unreleased`) when behavior changes.
- Make sure CI is green.
