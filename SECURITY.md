# Security Policy

## Scope

`alibi-to-5` runs entirely on your own Mac. It moves your own cursor a few pixels,
schedules a wake with `pmset`, and (optionally) posts to a webhook URL you supply.
It does not touch your employer's systems, bypass any security control, or send
data anywhere except a webhook you configure.

The most sensitive thing it handles is your **webhook URL**, which lives in
`~/.config/alibi-to-5/secrets` (mode `600`) and is never committed — see
`secrets.example`.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's private reporting instead: go to the **Security** tab →
**Report a vulnerability**. That opens a private advisory visible only to the
maintainer.

Please include the version/commit, what you observed, and steps to reproduce.
You'll get an acknowledgement as soon as possible.

## Supported versions

Only the latest release on `main` is supported.
