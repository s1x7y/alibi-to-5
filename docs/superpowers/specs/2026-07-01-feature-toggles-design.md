# alibi-to-5 — feature toggles design (2026-07-01)

Add four backlog features to the single `alibi-to-5.sh` script as uniform,
independent toggles, and convert the two existing hard-coded behaviors (Slack,
Codex) into toggles too — so every wake integration is opt-in/opt-out and the
tool is fully adaptable. Linux support (backlog item 1) is explicitly out of
scope and stays in `BACKLOG.md` for its own spec.

## Toggle model

Every integration is a toggle with a **config default** (constant at the top of
the script) that can be **overridden by a CLI flag** on `set`. The resolved
choices are baked into the LaunchAgent plist so they apply on every scheduled
wake without any separate state file.

| Feature      | Config default             | Enable / disable flag        | Effect at wake                    |
|--------------|----------------------------|------------------------------|-----------------------------------|
| Slack        | `ENABLE_SLACK=1`           | `--slack` / `--no-slack`     | open `Slack.app`                  |
| Teams        | `ENABLE_TEAMS=0`           | `--teams` / `--no-teams`     | open `Microsoft Teams.app`        |
| Codex        | `ENABLE_CODEX=1`           | `--codex` / `--no-codex`     | headless Codex usage-window ping  |
| Claude       | `ENABLE_CLAUDE=0`          | `--claude` / `--no-claude`   | headless Claude usage-window ping |
| Good-morning | `GOOD_MORNING_TEXT=""`     | `--good-morning "TEXT"`      | post TEXT to a Slack/Teams webhook|
|              | `GOOD_MORNING_PLATFORM=slack` | `--gm-platform slack\|teams` | selects which webhook             |

Defaults reproduce today's behavior exactly: **Slack on, Codex on**, Teams and
Claude off, no greeting. A bare `set 09:40` therefore behaves as it does now.

`OPEN_APPS` remains the escape hatch for *any other* app (default now empty,
since Slack graduated to its own toggle). Effective apps at wake =
`OPEN_APPS` + Slack (if on) + Teams (if on).

## Flag flow (set → plist → run)

- One shared parser, `parse_feature_flags`, initializes the `FEAT_*` / `GM_*`
  runtime vars from the config-constant defaults, then applies any flags.
- `cmd_set` parses `[HH:MM]` first, then the feature flags, then **re-emits the
  fully resolved choices as canonical, explicit flags** into the plist
  `ProgramArguments` (e.g. `run --slack --no-teams --codex --no-claude
  --good-morning "..." --gm-platform slack`). The plist is thus self-describing
  and independent of later edits to the config defaults.
- `cmd_run` (invoked by launchd) parses those same flags; `cmd_test` accepts the
  same flags so a config can be tried before scheduling.

## Per-feature behavior

- **Slack / Teams:** append the app name to the effective open list when enabled;
  reuse the existing `app_installed` + `open -a` path (warn-and-skip if missing).
  No new keep-active logic — the 60s jiggle already beats the Teams ~5 min away
  threshold.
- **Codex / Claude:** resolved via the existing `resolve_bin` (`-ilc`) helper and
  fired headless in the background to start the usage window. Codex:
  `codex exec --sandbox read-only "$CODEX_PROMPT"` (unchanged). Claude:
  `claude -p "$CLAUDE_PROMPT"` in print mode; confirm the exact no-side-effects
  permission flag during implementation. Warn-and-skip if the binary is absent.
- **Good-morning message:** when the greeting text is non-empty, after the apps
  open, POST it to an incoming webhook via `curl`.
  - **Secret:** webhook URLs live in a gitignored, sourced shell file
    `~/.config/alibi-to-5/secrets` providing `SLACK_WEBHOOK_URL` and/or
    `TEAMS_WEBHOOK_URL`. Never committed; ship a `secrets.example`. If the file or
    the relevant URL is missing, warn-and-skip.
  - **Content:** literal text supplied by the user on `set`, with optional
    `{time}` / `{date}` / `{day}` tokens interpolated at wake.
  - **Payload:** `{"text": "<escaped>"}` (Slack, and the Teams legacy connector).
    Text is JSON-escaped by a small dependency-free helper. README notes the
    Teams Workflows / Adaptive-Card caveat.

## Testing

The script is already sourceable (bottom guard runs `main` only when executed
directly), so the pure helpers are unit-testable. `test/alibi-to-5.test.sh`
sources the script and asserts:

- `json_escape` handles quotes, backslashes, newlines, tabs.
- `interpolate` replaces `{time}`/`{date}`/`{day}` and leaves other text intact.
- `parse_feature_flags` resolves defaults and each flag (including `--no-*` and
  `--good-morning`/`--gm-platform`) into the expected `FEAT_*` / `GM_*` values.
- `cmd_set`'s canonical-flag serialization round-trips through
  `parse_feature_flags` to the same resolved state.

Launchd/webhook/`open -a` paths can't be unit-tested without a real wake and are
verified manually via `test` and by inspecting the emitted plist.

## Out of scope

Linux support (own spec), API-token transport, DM-to-self, generated/LLM
greetings, and any change to the wake-scheduling / caffeinate / jiggle core.
