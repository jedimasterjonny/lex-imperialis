# lex-imperialis

Ansible code for a homelab.

Single owner, single user, single operator. No team, no external consumers, no multi-tenancy. Assume the owner is the only person who will ever run or maintain this — optimise for that, not for collaboration, onboarding, or generality.

## Public repository

This repo is public: every commit is world-readable and permanent, including git history and forks. The code is infrastructure, so a leak is an attack surface.

- NEVER commit secrets in plaintext — no passwords, tokens, private keys, or certificates. Encrypt them with `ansible-vault`, and keep vault password files and host secrets out of tracked files.
- Secrets live in one `ansible-vault`-encrypted file, encrypted whole — no inline `!vault` strings, one vault id.
- Keep sensitive topology out of the repo — public IPs, external hostnames, exposed ports, and anything that maps the attack surface.
- A secret that reaches a commit is compromised: rotate it, don't just delete it. Scrubbing history does not undo exposure.

## Writing code

Favour the simplest solution that meets current needs; hold to KISS, YAGNI, and DRY. Flag scope creep, unnecessary complexity, and premature optimisation as they appear.

## Layout

Loose `roles/` at the repo root — no collection wrapper. Single operator with nothing to publish; revisit only if custom plugins or modules appear.

## Commit hygiene

Every commit MUST be 100% clean: it contains **only** the changes required for its stated purpose, and nothing else.

- No whitespace changes — no trailing whitespace, re-indentation, or blank-line churn.
- No formatting or style changes unrelated to the commit.
- No incidental edits, reordering, renames, or "while I was here" fixes.
- If the diff shows a line you did not intend to touch, revert that line before committing.

Spot an unrelated problem? Leave it alone and flag it separately — never fold it into an unrelated commit.

Name branches `type/short-desc` — `type` is the Conventional Commits type, `short-desc` a kebab-case summary.

Before merge, reshape the branch into a sequence of logical, self-contained commits — squash fixups, split unrelated changes, reorder as needed. Each resulting commit must stay clean and green.

Integrate with a merge commit — always `--no-ff`, never fast-forward or squash — so each branch lands as one attributable unit. Per-branch history stays linear and clean; the default branch is deliberately not linear, carrying one merge commit per branch.

## Commit messages

Conventional Commits. Two project specifics:

- `scope` is the role name — mandatory except for cross-cutting changes, never an issue identifier.
- Extra type `ops` (infrastructure, deployment, CI/CD, backups, monitoring, recovery), distinct from `build` (build tooling, dependencies, version).

## Bisect safety

The git tree MUST be bisect-safe at all times: every commit — on every branch, work in progress included — passes lint and tests, so `git bisect` is always reliable. Never commit red.

- Splitting work across commits is fine — add a feature in one commit, its tests in the next — provided each commit is itself green.

## Verifying changes

Run the gates yourself before presenting or committing — never hand back unverified work.

- `pre-commit run --all-files` for lint; `molecule test` for the role(s) you touched.
- Every task must be idempotent — molecule's idempotence check (a second converge reporting zero changed) enforces it.
- Fix failures at the root, don't suppress them. Show the command output as evidence.
- Formatting is owned by the linters — don't hand-format or override them.

## Running plays

Write and `molecule`-test code. Against live hosts, only `--check`/`--diff` dry runs — never apply. Applying to the real fleet is the operator's call. Tasks that render secrets set `no_log: true` — otherwise `--diff` prints them in plaintext.

## Documentation style

READMEs must be terse and direct. The reader is a senior engineer who thoroughly understands the domain — skip background, drop illustrative parentheticals, and don't restate what they already know.

Comments follow the same rule: add one only where a particularly complex piece of code genuinely needs explaining, never to narrate the obvious. When you do, keep the language terse and direct.
