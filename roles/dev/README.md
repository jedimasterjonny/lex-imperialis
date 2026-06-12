# dev

Developer tooling for the workstation, on top of common (the owner account
must exist). npm is gated on `dev_npm` for hosts that do no Node work; git
and nvim dotfiles deploy via the stow role.

Claude Code installs once per user through the native installer, guarded by
`creates:` — the binary self-updates in the background, so the role never
reruns the script.
