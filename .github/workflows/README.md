# GitHub Actions workflows

The workflows guarding PRs pin actions by commit SHA (version in a trailing
comment) and request a read-only `contents` token by default: **lint** runs the
pre-commit hook set plus a push-time secret scan on all changes; **molecule**
runs the role tests, gated to the tiers and roles a PR actually touches;
**firebase** builds, gates, and deploys the `jonnyoc-site` website. **terraform**
(documented in `terraform/README.md`) plans and gates the OpenTofu tree.

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

Runs on every PR (no path filter) and `workflow_dispatch` — so the
`molecule-gate` check (below) is always reported. No `push: main`; the `--no-ff`
merge tree equals the validated PR tree. A `discover` job reads the PR diff and
emits one role matrix per tier; each tier job runs only when its matrix is
non-empty, with `fail-fast: false`. Concurrency is per-ref and cancels
superseded PR runs (the hetzner teardown backstop still fires on cancel).

### discover

Checks out with `fetch-depth: 0` — the `base...head` diff needs full history; a
genuine `git diff` failure aborts the job rather than yielding an empty diff.
Drops `*.md` (a doc-only change runs no tier), then splits the rest into changed
roles and shared infra — a fixed allowlist of the non-role paths that affect a
molecule run (`molecule/`, the vault, the requirements files, the `Makefile`,
the coverage script, and this workflow). A PR touching only paths outside that
set (e.g. `terraform/`, `jonnyoc-site/`) yields no tiers, so `molecule-gate`
reports green without running one:

- A changed role runs whichever tiers it ships — the matrix includes a role
  only when it carries that tier's scenario directory (`molecule/default` for
  incus, `molecule/leap`, `molecule/hetzner`).
- Shared infra is exercised through the `motd` harness, which carries all three
  tiers.
- A `requirements-dev.txt`- or `Makefile`-only change stays on the free incus
  tiers and skips the billable hetzner VM.
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

### molecule-gate

A fixed-name summary job (`if: always()`, `needs:` `discover` plus the three
tiers) that fails if `discover` or any tier failed or was cancelled, and passes
when tiers skip. The per-role matrix job names vary per PR and can't be named
as required checks, and a required check that never reports blocks the merge —
so this one stable, always-reported check is what the `main` branch ruleset
requires, alongside `pre-commit`, `secret-scan`, and the `terraform-gate` and
`site-gate` checks the terraform and firebase workflows report the same way.

## firebase

Two workflows deploy the `jonnyoc-site` Hugo site to Firebase Hosting (project
`jonnyoc-website`). Both set up Go (for the Hugo Module theme fetch) and a pinned
Hugo, authenticate keylessly via Workload Identity Federation (the deploy SA in
`terraform/`) so no Firebase secret is needed, and run a pinned `firebase-tools`;
`firebase-tools` and `hugo-version` are renovate-tracked.

**firebase (merge)** fires on a push to `main` under `jonnyoc-site/**`, builds
`hugo --minify` (honouring `buildFuture=false`/`expiryDate`), and deploys the live
channel.

**firebase (preview)** runs on every PR (no path filter, like molecule) so its
`site-gate` check is always reported. A `discover` job scopes it to PRs touching
`jonnyoc-site/` or this workflow — `*.md` is kept, unlike terraform's discover,
since the site's content is markdown. In scope, it splits into a **build** job
that builds exactly as the merge deploy does (`hugo --minify`, no secret, so it
runs for fork PRs too) and a best-effort **preview** job that rebuilds with
`hugo -E -F --minify` (future and expired content included for review),
authenticates, and deploys a 30-day `preview-<PR#>` channel — same-repo PRs only,
since forks can't reach WIF. A Firebase flake fails only the preview, never the gate.

### site-gate

A fixed-name summary job (`if: always()`, `needs:` `discover` and `build`) that
fails if either failed or was cancelled and passes when the build skips (a
non-site PR). It reflects the secret-free build — which runs on every in-scope PR,
forks included — not the preview, so a preview-deploy flake can't redden it and it
gates exactly the content the live deploy builds. This is the required check the
`main` ruleset uses so a build-breaking hugo or theme bump can't automerge.
