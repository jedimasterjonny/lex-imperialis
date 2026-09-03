# GitHub Actions workflows

The workflows pin actions by commit SHA (version in a trailing comment) and
request a read-only `contents` token by default: **lint** runs the pre-commit
hook set plus a push-time secret scan on all changes; **molecule** runs the role
tests, gated to the tiers and roles a PR actually touches; **firebase** (two
workflows) builds, gates, and deploys the `jonnyoc-site` website; **terraform**
plans and gates the OpenTofu tree on a PR and applies it to live cloud infra on
merge; **hugo go.sum autofix** completes Renovate's Blowfish-bump `go.sum` in
place; **claude review** posts an advisory code review on a PR you label. Most
guard PRs; **firebase** and **terraform** also act on a merge to `main`.

A **draft PR runs only lint**. The other PR workflows guard their work (molecule
tiers, the site build/preview, the terraform plan, the `go.sum` amend) behind the
PR's non-draft state, so a draft costs no billable VM, plan, or deploy; their
always-reporting gate checks (`molecule-gate`, `site-gate`, `terraform-gate`)
stay green off the skipped work in the meantime. `ready_for_review` is added to
each `pull_request` trigger's types, so leaving draft re-triggers the workflow
and runs — and re-reports the gate on — the ready PR.

## lint

Fires on every PR and every push to `main`. Two jobs. **pre-commit** builds the
venv from `requirements-dev.txt`, installs the pinned OpenTofu, tflint, promtool,
packer (its plugins cached on the template hash) and butane the binary-dependent
hooks need, then runs `make pre-commit` (`pre-commit run --all-files`) —
yamllint, ansible-lint, shellcheck plus shellcheck-jinja (the `*.sh.j2` templates
the shell hook skips, typed jinja) and jinja-syntax (every `*.j2` and `*.bu`
parsed), codespell (British English — flags American spellings via
`.codespell-en-GB.txt`), ruff (every rule on over the Python scripts, and its
formatter), actionlint (these very workflow files: Actions
semantics plus shellcheck over every `run:` step), markdownlint (every `*.md`),
check-toml, editorconfig-checker, renovate-config-validator (schema-checks
`renovate.json`), promtool over the static Prometheus alert rules plus
`promtool test` and `check-alert-test-coverage.py` over the cases behind them,
tofu fmt/validate, tflint, packer fmt/validate, butane, `detect-private-key`, the
file-hygiene hooks, and `check-role-test-coverage.sh`.
`setup-uv` caches the wheels the venv is built from, keyed on the requirements
files; the pre-commit environment cache keys on `.pre-commit-config.yaml`.

**secret-scan** is the push-time gitleaks backstop. The `gitleaks` hook scans the
staged index, which is empty on CI's fresh checkout, so it passes vacuously; this
job downloads the pinned gitleaks — version tracked from `.pre-commit-config.yaml`,
the single source of truth — and scans the checked-out commit's content instead.

A re-push cancels the superseded PR run; `main` runs finish, so every commit on
`main` carries a check.

## molecule

Runs on every PR (no path filter) and `workflow_dispatch` — so the
`molecule-gate` check (below) is always reported. No `push: main`: a post-merge
tier would bill a Hetzner VM on every merge. Since the required checks are loose
(see **Branch protection**), a break that shows only against a moved `main`
surfaces as a failed `arbites` apply rather than a red check. A `discover` job
reads the PR diff and emits one role matrix per tier; each tier job runs only
when its matrix is non-empty, with `fail-fast: false`. Concurrency is per-ref
and cancels superseded PR runs (the hetzner teardown backstop still fires on
cancel).

### discover

Checks out with `fetch-depth: 0` — the `base...head` diff needs full history; a
genuine `git diff` failure aborts the job rather than yielding an empty diff.
Drops `*.md` (a doc-only change runs no tier), then splits the rest into changed
roles and shared infra — a fixed allowlist in two groups: the fleet code an apply
executes (`playbooks/`, all of `inventory/` including the vault, `bootstrap/`,
`ansible.cfg`) and the harness and toolchain the tiers run on (`molecule/`,
`bin/*.sh`, the requirements files, the `Makefile`, `.pre-commit-config.yaml`,
`.github/actions/`, and this workflow). A PR touching only paths outside that
set (e.g. `terraform/`, `jonnyoc-site/`, `packer/`) yields no tiers, so
`molecule-gate` reports green without running one:

- A changed role runs whichever tiers it ships — the matrix includes a role
  only when it carries that tier's scenario directory (`molecule/default` for
  incus, `molecule/hetzner` for hetzner).
- A changed role drags in the roles that consume it through `include_role`
  (`bin/expand-role-consumers.sh`), transitively. An engine role is exercised by
  its consumers' scenarios, not its own, so `restic_backup` also runs
  `home_backup` and `podman_backup`, and `stow` also runs `common` and `dev`.
  The graph is read out of the tree, not listed anywhere.
- Shared infra is exercised through the `motd` harness, which carries both CI
  tiers.
- A change confined to the toolchain — `requirements-dev.txt`, the `Makefile`,
  `.pre-commit-config.yaml`, or a `bin/` script only the hook set runs — stays on
  the free incus tier and skips the billable hetzner VM. The scripts a real
  path runs still book it: `expand-role-consumers.sh` (this job),
  `fleet-apply.sh` (`arbites`' root apply), `container-refresh.sh` and
  `container-swap.sh` (its container fast path), and `vault-var.sh` (the
  hetzner tier's own token lookup).
- `workflow_dispatch` ignores the diff and tests every role.

Molecule tests only the scenarios a role ships; that the required ones *exist*
is enforced separately by `check-role-test-coverage.sh` in the lint gate.

### Tiers

Every tier job has a 20-minute timeout, except incus at 30 — room for its
retry, below.

| Job | Scenario | Make target | Runner |
| --- | --- | --- | --- |
| `incus` | `default` (Tumbleweed) | `make test` | free, on the runner |
| `hetzner` | `hetzner` | `make test-hetzner` | a real, billable Hetzner VM |

The libvirt tier is local-only; CI realises it as `hetzner`, since Hetzner
Cloud cannot nest KVM. The incus job installs and inits incus on the runner (dir
storage; `FORWARD ACCEPT` and IPv6 off to clear the runner's Docker/network
defaults) and runs molecule under the `incus-admin` group, retrying a red run
once — the transient openSUSE mirror and image-server flakes outlast a single
run's in-play retries. The `hetzner` job passes
`HCLOUD_TOKEN` from the `MOLECULE_HCLOUD_TOKEN` secret — a token scoped to a
throwaway Hetzner project with no production server — so it never decrypts the
vault (the one PR-triggered path that otherwise would). It sets `MOLECULE_RUN_ID`
per run so concurrent VM and SSH-key names never collide, and carries an
`if: cancelled()` teardown so a killed run never orphans a billable VM.

### molecule-gate

A fixed-name summary job (`if: always()`, `needs:` `discover` plus both CI
tiers) that fails if `discover` or any tier failed or was cancelled, and passes
when tiers skip. The per-role matrix job names vary per PR and can't be named
as required checks, and a required check that never reports blocks the merge —
so this one stable, always-reported check is what the `main` branch ruleset
requires, alongside `pre-commit`, `secret-scan`, and the `terraform-gate` and
`site-gate` checks the terraform and firebase workflows report the same way.

## Branch protection

The `main` ruleset takes its five gate checks **loose** — a branch does not have
to be up to date with `main` to merge. It allows only merge commits and blocks
force-push and deletion; `docs/disaster-recovery.md` carries the payload to
recreate it, and the repository merge-method settings that must be restored
alongside it.

Strict would make every merge to `main` invalidate every open branch, costing a
rebase and a full CI re-run, hetzner tier included, on a branch that was already
green. Loose buys that back at the price of a PR's checks being green against
the base it was cut from, not the base it lands on.

`rebaseWhen: auto` resolves to `behind-base-branch` **only** where `automerge`
is true, so Renovate does refresh its own automerging branches — but only when a
later run catches one behind, and platform automerge lands them the moment they
go green, usually first. Everything else resolves to `conflicted` and is never
refreshed: operator branches, and every dependency held off automerge in
`renovate.json`, which is the highest-reach set in the repo.

Strict also blocked merging a stale branch, which `unattended-author` was
silently relying on: it applies the branch tree to the fleet and then merges,
carrying no up-to-date step of its own, so a `main` that moved during the apply
now lands unapplied and untested — and `arbites` puts it on the fleet within 15
minutes regardless. The guard belongs in that skill's own merge phase; it is not
there yet and nothing tracks it. GitHub's merge queue would fix this and is not
available: it is limited to organisation-owned repositories, and this one is
owned by a user account.

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
can't mutate), while the write tokens live in the main-only `Segmentum Obscurus`
environment, reached only on a push — the push plan bakes them into the saved plan
the apply replays, so no PR can read one. No workflow holds a vault password: the
Ansible vault is operator-only. State (GCS) and GCP are keyless via Workload Identity Federation —
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

The amend is force-pushed with a short-lived token from the `lexographer` **GitHub
App** (`AUTOFIX_APP_ID` / `AUTOFIX_APP_KEY`), not `GITHUB_TOKEN`: a `GITHUB_TOKEN`
push wouldn't re-trigger the required `site-gate` check and would hang the PR. It
can't loop — the push only happens when `go.sum` is incomplete, which the pushed
fix clears. Fork PRs are skipped (read-only token, unpushable branch).

## claude review

Runs `anthropics/claude-code-action` against a PR and posts a Claude Code
review. Advisory, so it is not a required check and needs no always-reporting
gate job.

Opt-in: add the **`review`** label. Renovate's arrives as its own `labeled`
event, since neither the REST nor the GraphQL create-PR call accepts labels;
`opened` covers the browser's create form, which attaches them as part of
creation. Fork PRs are skipped, GitHub withholding secrets from them, and so are
drafts: label a draft and it is reviewed when it leaves draft, via
`ready_for_review`.

There is no `synchronize` trigger, and the guard ignores any label other than
`review`, because upstream declines a PR it has already commented on: a second
run spends quota to return clean. The review is therefore once per PR, which has
a consequence worth holding onto at sign-off — **when Renovate force-pushes a
major to a newer version in the same range, the review on the page is of the
superseded diff**, not of what would merge. Re-adding `synchronize` would not
fix it, since upstream would decline that run too. Two gestures do re-run: a
reviewed PR pushed back to draft and marked ready, and a close-and-reopen. Both
usually cost only that decline — but upstream's test is whether Claude has
already commented, so if the first run errored or posted nothing, the second is
a full review.

Renovate applies that label to every **major** update (`renovate.json`), the one
update type nothing here automerges. Renovate is named in `allowed_bots` because
the action rejects bot actors outright — the mechanism that stops bots
triggering Claude in a loop — so without it every major would be refused before
the review began. Named rather than `*`, which on a public repo would let any
external app invoke the action.

The label gate exists because the run is metered in people, not money.
`CLAUDE_OAUTH_TOKEN` is a subscription token, so a review costs no API
billing but draws on the owner's own Claude Code allowance — and reviewing every
PR would spend it on bumps that automerge unread.

`request-signoff` then requests review from the owner, so the PR reaches the
inbox already read rather than as a raw diff. A separate job so that only it
holds `pull-requests: write`; the review job comments with the Claude App token
its `id-token: write` mints, so it needs none. It skips the owner's own PRs,
since GitHub refuses a review request from the PR's author, and deliberately
fires even when the review failed or returned early. The request
means "a human is needed here", not "Claude approved this" — whether Claude got
there is carried by the check status and by `review-outcome` below. Gating it
on a successful review would drop an unreviewed major out of the review queue,
which is the one case that most needs to stay in it.

`review-outcome` closes the gap that leaves. Upstream posts its summary at its
own discretion — #497 got a "no issues found" comment, while #485 and #491 got
nothing from runs that spent four minutes doing the work — and an empty PR reads
exactly like a review that never fired. So when the review succeeds and the
Claude App left neither an issue comment nor an inline one, this job says so in
a line of its own. It checks both lists, since findings land on the diff and the
summary does not, and matches `claude` and `claude[bot]` because GraphQL and
REST disagree on a bot's login. It holds `pull-requests: write` for the same
reason `request-signoff` does, and for the same reason is a job the agent's
shell never enters. Unlike sign-off it is not gated on the PR's author: the
ambiguity is identical on the owner's own labelled PRs. It stays silent after a
failed review — that is what the check status is for, and "no findings" would be
a claim nobody verified.

Two inputs here are unpinned, against the discipline everything else follows.
The model is deliberate — the action takes Claude Code's own default, and a
model string is not a datasource renovate can bump. The plugin marketplace is
not: `plugin_marketplaces` takes a bare git URL and resolves it at run time, so
the skill deciding whether a review happens is whatever is on that repo's HEAD,
and nothing in the action accepts a ref for it. That reaches further than the
prose — the skill's own `allowed-tools` frontmatter is where the review's `gh`
grants come from, since `claude_args` names only the MCP tool, so an upstream
edit moves what the reviewer may do and not just what it is told to do.
Vendoring the command locally would close that properly; `install-plugins.ts`
accepts a path.

It reaches further still because the review reads text nobody here controls. A
Renovate major carries the upstream release notes verbatim in its body — 6 KB
on #540, 20 KB on #491 — and the skill fetches that body with its own
`gh pr view`, so the action's sanitiser never sees it. Whoever writes a release
note for a dependency tracked here, the indirect gomod deps included, gets prose
in front of the reviewer.

Three things bound what that prose reaches, in the order they bite. The action
drives the Agent SDK with no `permissionMode` and no permission callback, so the
SDK default holds and a call matching no allow rule is denied rather than
prompted: the rules in force are the skill's seven `gh` prefixes plus
`--allowedTools`, and there is no general shell behind them. The SDK loads the
`user`, `project` and `local` setting sources, so this repo's own
`.claude/settings.json` is read on the runner too — it carries only `ask` rules,
which cannot widen anything, but an `allow` added there for workstation
convenience would widen CI with it. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` then keeps
`CLAUDE_OAUTH_TOKEN` and the Actions secrets out of every subprocess environment
the agent can open; the action sets it itself only alongside
`allowed_non_write_users`, but reads the caller's `env` ahead of that, so the job
opts in directly. Last, `--disallowedTools` is the floor under an upstream
widening, and deny beats allow. It names families rather than commands — `git`
entire, so `git -c … push` is covered and not just `git push`, then `gh api`,
`curl`, `wget`, `WebFetch` and `WebSearch` — plus `gh pr merge` and
`gh pr review`, the two `gh pr` subcommands that would change what lands or what
"approved" means. Families are the point: a widening upstream to `Bash(gh:*)`
would still leave nothing that reaches `main`, which is what matters when
`arbites` applies `main` to the fleet as root within ~15 minutes.

The OIDC-minted App token stays write-scoped (`contents`, `pull_requests` and
`issues`, per the action's `DEFAULT_PERMISSIONS`) and still reaches the agent.
That is a trade, not an oversight: passing `github_token` mints no App token and
leaves a `pull-requests: write` `GITHUB_TOKEN` in its place, but it returns
before the OIDC exchange and so drops the workflow-file check below with it, and
it moves the review's comments to `github-actions[bot]` — the author
`review-outcome` keys on, and an identity this repo already disambiguates with
markers elsewhere, as the Firebase preview comment does. Denying the primitives
costs neither.

That skill stops before reviewing when the PR "does not need code review (e.g.
automated PR ...)" — which is every Renovate PR, the entire class this exists to
review, and it exits cleanly enough to still look reviewed.
The override answers that — both the automated leg and the "trivial change that
is obviously correct" one, which a one-line pin bump would otherwise trip — and
points the review at the release notes in the PR body, as far as the skill's own
allowed tools reach, while naming that body untrusted so the notes are read as
evidence rather than instruction. It is deliberately in **both** `prompt` and
`--append-system-prompt`: the skill delegates that decision to a subagent, which
inherits the user turn but not the session system prompt, so the `prompt` copy
is the one that reaches it. `--allowedTools` duplicates the same tool the skill's own frontmatter
names, because the action starts the inline-comment MCP server only when
`claude_args` names it.

The action also refuses to run when the workflow file differs from the copy on
the default branch: a PR cannot run a workflow it just edited. So a PR changing
this file gets a green, eleven-second `review` job that reviewed nothing, and
the change only takes effect once merged — which also means Renovate's own
majors bumping `claude-code-action` or `actions/checkout` *in this file* are
systematically the ones that never get reviewed. Sign-off is still requested, so
the PR stays in the queue, and `review-outcome` stays silent — it gates on the
action's `conclusion` output, which is empty when the action short-circuits
without starting Claude, precisely so it cannot report "no findings" about a
review that never ran.
