# GitHub Actions workflows

The workflows pin actions by commit SHA (version in a trailing comment) and
request a read-only `contents` token by default: **lint** runs the pre-commit
hook set plus a push-time secret scan on all changes; **molecule** runs the role
tests, gated to the tiers and roles a PR actually touches; **firebase** (two
workflows) builds, gates, and deploys the `jonnyoc-site` website; **terraform**
plans and gates the OpenTofu tree on a PR and applies it to live cloud infra on
merge; **hugo go.sum autofix** completes Renovate's Blowfish-bump `go.sum` in
place. Most guard PRs; **firebase** and **terraform** also act on a merge to
`main`.

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
defaults) and run molecule under the `incus-admin` group. The `hetzner` job passes
`HCLOUD_TOKEN` from the `MOLECULE_HCLOUD_TOKEN` secret — a token scoped to a
throwaway Hetzner project with no production server — so it never decrypts the
vault (the one PR-triggered path that otherwise would). It sets `MOLECULE_RUN_ID`
per run so concurrent VM and SSH-key names never collide, and carries an
`if: cancelled()` teardown so a killed run never orphans a billable VM.

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

## terraform

Runs OpenTofu on the runner (Local execution), state in a GCS bucket. Fires on
every PR, a push to `main` under `terraform/**` (or this workflow),
`workflow_dispatch`, and a weekly drift schedule (`cron: '41 6 * * 1'`, Mondays
06:41 UTC). No PR path filter, so the `terraform-gate` check always reports; a
`discover` job decides whether the plan runs — a non-infra PR skips it and still
passes the gate (`*.md` is dropped first, so a `terraform/README.md` edit plans
nothing).

A PR runs `tofu plan` and posts it as a single in-place PR comment; a push to
`main` applies **the saved plan file**, not a fresh re-plan, so what applies is
what was logged. The plan is scanned for a delete or replace: finding one fails
the gate on a PR (blocking an automerge) and halts before the apply on a merge, so
a destructive plan never applies unattended while a routine in-place bump flows
through — the coupling that matters, since renovate automerges minor/patch bumps
with no human reading the plan. The weekly run plans `main` against live infra
and fails on any drift.

The Cloudflare/Hetzner provider tokens split by privilege: a PR plans with
read-only counterparts held as plain repo secrets (a PR that grabbed them still
can't mutate), while the write tokens stay in the vault, reached only on a push —
the push plan decrypts them (its `VAULT_PASSWORD` lives in the main-only
`fleet-apply` environment) and bakes them into the saved plan the apply replays,
so no PR can decrypt them. State (GCS) and GCP are keyless via Workload Identity Federation —
a PR impersonates the read-only `tofu-plan` SA (which can read state but not write
it), a merge the write `tofu-apply` SA. Fork PRs skip the plan cleanly (they can't
read the repo-secret plan tokens or mint the WIF token). `terraform/README.md`
covers the OpenTofu config itself.

### terraform-gate

A fixed-name summary job (`if: always()`, `needs:` `discover` and `plan`) that the
`main` ruleset requires. It fails if the plan failed, was cancelled, or was skipped
while terraform was in scope (a fork PR that touched terraform but couldn't run the
gated plan), and passes when a non-infra PR skips the plan.

## hugo go.sum autofix

Fires on a PR touching `jonnyoc-site/go.{mod,sum}`. Blowfish (the Hugo theme) is
an indirect gomod require, so Renovate's `go get` records only its `/go.mod` hash
and leaves the superseded lines behind; only Hugo's own tooling records the
content hash, and the Mend-hosted Renovate app can't run it. This job regenerates
a complete, tidy `go.sum` (`hugo mod tidy` plus a build) and amends it into the
Renovate commit, so each bump stays one clean commit rather than growing a
checksum-fixup churn.

The amend is force-pushed with a short-lived **GitHub App token** (`AUTOFIX_APP_ID`
/ `AUTOFIX_APP_KEY`), not `GITHUB_TOKEN`: a `GITHUB_TOKEN` push wouldn't re-trigger
the required `site-gate` check and would hang the PR. It can't loop — the push only
happens when `go.sum` is incomplete, which the pushed fix clears. Fork PRs are
skipped (read-only token, unpushable branch).
