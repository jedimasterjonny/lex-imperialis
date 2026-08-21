# dev

Developer tooling for the workstation, on top of common (the owner account
must exist). npm ships with the role; git and nvim dotfiles deploy via the
stow role.

Claude Code installs once per user through the native installer, guarded by
`creates:` — the binary self-updates in the background, so the role never
reruns the script.

The installer is an unpinned `curl … | bash` against a rolling URL with no
published checksum or datasource, so a hand-bumped hash would break converge on
every upstream tweak (YAGNI); the trust anchor is `claude.ai` over TLS, accepted
knowingly on the host that holds `.vault_pass` and fleet-wide NOPASSWD root.

## Terraform gate tools

The `terraform/` pre-commit gates need `tofu` and `tflint` on PATH, so the
workstation provisions both: OpenTofu from zypper (`opentofu` in `dev_packages`),
and tflint — which has no zypper package — via its upstream install script,
fetched at the `dev_tflint_version` tag and checksum-verifying its download. That
pin matches the CI gate (`.github/workflows/lint.yml`), kept in sync by one renovate
custom manager that bumps both. Unlike Claude Code, tflint does not self-update,
so a version check drives the install, not `creates:`.

## Butane, promtool and packer gate tools

The `butane` hook compiles every `*.bu` and the `promtool` hooks check and test
the alert rules, so the workstation takes both from zypper (`butane` and
`golang-github-prometheus-prometheus`, which provides `/usr/bin/promtool`).
Both are rolling while CI pins — butane from a digest-pinned image, promtool
from the prometheus release matching `roles/prometheus`'s image pin — so the
versions can differ. Accepted rather than pinned in both cases: a zypper package
cannot be held to a version under a rolling distro. Butane's `--strict` promotes
warnings to errors, so a `*.bu` can pass locally and fail CI; promtool's drift is
quieter, parting the local linter from the prometheus that evaluates the rules.
Neither version is asserted, unlike packer's `build` (`bin/packer.sh`) — CI's
verdict is the one that counts.

promtool ships only as part of the whole prometheus package — 187 MiB and a
`prometheus` system user for one linter binary. Accepted as the cost of not
hand-managing it. Two consequences the role handles: it removes any
`/usr/local/bin/promtool`, which would shadow the package's `/usr/bin` copy on
PATH, and it masks the bundled `prometheus.service` — dormant by openSUSE's
preset anyway, but this makes it the role's guarantee on the host holding
`.vault_pass` and fleet-wide root.

The `packer` gates need HashiCorp packer, which has no zypper package and which
this role does not install. The tflint pattern would work — `/usr/local/bin`
outranks the cracklib `packer` openSUSE ships — but packer is needed only when
`packer/` changes, roughly twice a year, so it stays a hand install; see
`packer/README.md`.

## firebase-tools

`firebase-tools` installs as an npm global into the owner's `~/.local` at
`dev_firebase_tools_version`. There is no zypper package and the CLI does not
self-update, so the pin drives the install, as tflint's does; it matches the
version the deploy workflows `npx`, and
one renovate custom manager bumps both. The pin covers the operator's hand-run
`firebase` only — the workflows `npx` their own copy on `ubuntu-latest`, so the
site's release path never reaches the workstation.

It installs as the owner because the tree it writes is the owner's. `HOME` is what
points npm at the managed prefix, so a root-run install would resolve the same
path and leave root-owned directories under `~/.local` and `~/.npm`, breaking the
owner's own later `npm install -g`. Credentials are per-user too —
`~/.config/configstore/firebase-tools.json`, untouched by the role, so the
one-time `firebase login` stays manual.

## npm global prefix

npm reads its global prefix from the owner's `~/.npmrc`, so that file is what
decides where `firebase` — or any other global — lands. It is a precondition, not
a preference: no system npmrc exists on the fleet, and npm's built-in default is
`/usr`, which the owner cannot write. The role owns the `prefix=` line, set to
`dev_npm_prefix` (default `~/.local`), so the operator's own `npm install -g`
lands where the role's does.

The line is set with `lineinfile` on `dev_npmrc` (default `~/.npmrc`) rather than
a rendered file, because npmrc is app-managed — `npm login` and `npm config set`
write to it — so owning the whole file would revert npm's own writes and delete
any auth token added later. That is the posture the role already takes with
`~/.claude.json`, `no_log` included.

## Google Cloud CLI

`gcloud` has no openSUSE package, so the role imports Google's package-signing
key and adds Google's own repo (an el9 yum repo zypper consumes) before
installing `google-cloud-cli` from it.

## Passwordless sudo

The role grants the owner passwordless sudo on the workstation via
`/etc/sudoers.d/wheel-<owner>-nopasswd`. The name matters:
sudoers.d loads in sorted lexical order and the last match wins, so the drop-in
must sort after common's `wheel` file to override that file's own-password
`%wheel` rule. It supersedes and removes a legacy hand-rolled `wheel-nopasswd`.

This is the owner's convenience only. The `ansible` automation account escalates
via its own `/etc/sudoers.d/ansible` (fleet-standard, set by `bootstrap/host.sh`),
untouched here.

## Remote Control

The role runs `claude remote-control` as `dev_user` at boot, so the host is
steerable from claude.ai/code or the Claude app the moment it is up. Server
mode makes outbound HTTPS only — no inbound port, no firewall change. The
session is auto-named after the machine's hostname;
`dev_remote_control_workdir` is its working directory (default the owner's home).

It runs under the owner's own `systemd --user` manager, not a system unit:
Claude installs under `~/.local`, and on the SELinux-enforcing fleet PID 1
(`init_t`) cannot read or exec a binary there — a system unit restart-storms with
`203/EXEC`. The role enables lingering (`loginctl enable-linger`) so the user
manager runs without a login session, and installs the unit at
`~/.config/systemd/user/claude-remote-control.service`. `Restart=always` with no
start-limit recovers it after the ~10-minute network-outage timeout.

The role pre-seeds workspace trust for `dev_remote_control_workdir` (a per-project
key in the owner's `~/.claude.json`), so the one step it cannot automate is the
owner's claude.ai login. The unit is enabled for boot but never started by the
role. One-time, on the host as `dev_user`:

1. `claude` then `/login` (claude.ai OAuth — a Pro or Max plan; API keys and
   `setup-token`/`CLAUDE_CODE_OAUTH_TOKEN` are rejected).
2. `systemctl --user start claude-remote-control.service` to bring it up now; the
   lingering manager starts it on every subsequent boot.

Unit edits apply at the next restart or boot — there is no restart handler, so a
converge never drops a live session.
