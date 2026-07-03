# GitHub Actions workflows

Two workflows guard every PR: **lint** runs the pre-commit hook set plus a
push-time secret scan on all changes; **molecule** runs the role tests, gated to
the tiers and roles a PR actually touches. Both pin actions by commit SHA
(version in a trailing comment) and request a read-only `contents` token.

## lint

Fires on every PR and every push to `main`. Two jobs. **pre-commit** builds the
venv from `requirements-dev.txt`, then `make pre-commit`
(`pre-commit run --all-files`) — yamllint, ansible-lint, shellcheck,
`detect-private-key`, the file-hygiene hooks, and `check-role-test-coverage.sh`.
The pip cache keys on the requirements files; the pre-commit environment cache on
`.pre-commit-config.yaml`.

**secret-scan** is the push-time gitleaks backstop. The `gitleaks` hook scans the
staged index, which is empty on CI's fresh checkout, so it passes vacuously; this
job downloads the pinned gitleaks — version tracked from `.pre-commit-config.yaml`,
the single source of truth — and scans the checked-out commit's content instead.

A re-push cancels the superseded PR run; `main` runs finish, so every commit on
`main` carries a check.

## molecule

Path-filtered to `roles/`, `molecule/`, the vault, the requirements files, the
coverage script, and the workflow itself. No `push: main` — the `--no-ff` merge
tree equals the validated PR tree. A `discover` job reads the PR diff and emits
one role matrix per tier; each tier job runs only when its matrix is non-empty,
with `fail-fast: false`. Concurrency is per-ref and cancels superseded PR runs
(the hetzner teardown backstop still fires on cancel).

### discover

Checks out with `fetch-depth: 0` — the `base...head` diff needs full history.
Drops `*.md` (a doc-only change runs no tier), then splits the rest into changed
roles and shared infra (anything outside `roles/`):

- A changed role runs whichever tiers it ships — the matrix includes a role
  only when it carries that tier's scenario directory (`molecule/default` for
  incus, `molecule/leap`, `molecule/hetzner`).
- Shared infra is exercised through the `motd` harness, which carries all three
  tiers.
- A `requirements-dev.txt`-only change stays on the free incus tiers and skips
  the billable hetzner VM.
- `workflow_dispatch` ignores the diff and tests every role.

Molecule tests only the scenarios a role ships; that the required ones *exist* —
and that the `LEAP_ROLES` subset carries a `leap` scenario — is enforced
separately by `check-role-test-coverage.sh` in the lint gate.

### Tiers

Every tier job has a 20-minute timeout.

| Job | Scenario | Make target | Runner |
| --- | --- | --- | --- |
| `incus` | `default` (Tumbleweed) | `make test` | free, on the runner |
| `leap` | `leap` (Leap 16) | `make test-leap` | free, on the runner |
| `hetzner` | `hetzner` | `make test-hetzner` | a real, billable Hetzner VM |

The libvirt tier is local-only; CI realises it as `hetzner`, since Hetzner
Cloud cannot nest KVM. The incus jobs install and init incus on the runner (dir
storage; `FORWARD ACCEPT` and IPv6 off to clear the runner's Docker/network
defaults) and run molecule under the `incus-admin` group. The `hetzner` job
writes `.vault_pass` from the `VAULT_PASSWORD` secret — the only secret CI
needs, decrypting the in-repo hcloud token — sets `MOLECULE_RUN_ID` per run so
concurrent VM and SSH-key names never collide, and carries an `if: cancelled()`
teardown so a killed run never orphans a billable VM.
