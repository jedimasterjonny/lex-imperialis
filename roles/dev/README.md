# dev

Developer tooling for the workstation, on top of common (the owner account
must exist). npm is gated on `dev_npm` for hosts that do no Node work; git
and nvim dotfiles deploy via the stow role.

Claude Code installs once per user through the native installer, guarded by
`creates:` — the binary self-updates in the background, so the role never
reruns the script.

The installer is an unpinned `curl … | bash` against a rolling URL with no
published checksum or datasource, so a hand-bumped hash would break converge on
every upstream tweak (YAGNI); the trust anchor is `claude.ai` over TLS, accepted
knowingly on the host that holds `.vault_pass` and fleet-wide NOPASSWD root.

## Remote Control

`dev_remote_control` (default `true`) installs a `claude-remote-control.service`
system unit that runs `claude remote-control` as `dev_user` at boot, so the host
is steerable from claude.ai/code or the Claude app the moment it is up. Server
mode makes outbound HTTPS only — no inbound port, no firewall change. The session
is auto-named after the machine's hostname; `dev_remote_control_workdir` is its
working directory (default the owner's home).

The unit is enabled for boot but never started by the role: Remote Control needs
the owner's claude.ai credentials, which the role cannot provision. One-time, on
the host as `dev_user`:

1. `claude` then `/login` (claude.ai OAuth — a Pro or Max plan; API keys and
   `setup-token`/`CLAUDE_CODE_OAUTH_TOKEN` are rejected).
2. Run `claude` once in `dev_remote_control_workdir` to accept workspace trust.

`Restart=always` with no start-limit recovers it after the ~10-minute
network-outage timeout. Unit edits apply at the next restart or boot — there is
no restart handler, so a converge never drops a live session.
