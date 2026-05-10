# CLAUDE.md

Repo-specific instructions. These override default behaviour and apply to every session.

## Non-negotiables

1. **Clean commits.** Each commit contains only the changes that belong to it. No incidental whitespace, formatting, or unrelated edits — ever.
2. **Lint passes on every commit.** `make lint` must succeed at every commit, not just the branch tip.
3. **Tests pass on every commit.** Every `make test*` target that exists must succeed at every commit.
4. **Every role has Molecule scenarios.** No exceptions. A role lands only when it ships with at least a `default` Molecule scenario that exercises its core path, and `molecule test` for that role passes before the commit that introduces or modifies the role.
5. **Every commit works in isolation.** No half-finished or broken intermediate states on a branch. A future bisect must land on a working revision.
6. **Public-repo safe.** This repo is public on GitHub. Nothing committed may contain secrets or identify real infrastructure.
7. **Release at PR end is the default.** A PR that touches the collection normally ends with a release commit (version bump + regenerated antsibull changelog). The `pr-finalisation` skill applies a deferral gate where Claude proposes "release now" or "defer to a later PR" with reasoning; the user decides. Deferral is the exception.

## Commit hygiene

- Stage explicit paths (`git add path/to/file`). Never `git add -A` or `git add .` — they sweep in unrelated edits and pre-commit auto-fixes.
- Pre-commit hooks (`trailing-whitespace`, `end-of-file-fixer`, `mixed-line-ending`) may auto-fix files outside the change. Review the working tree after the hook runs and revert any hunks that aren't part of the commit's purpose. If those fixes are genuinely needed, they belong in their own `chore:` commit.
- If you reformatted a file as a side effect of editing it, revert the unrelated hunks (`git checkout -p`) before staging.

## Public-repo safety

**IMPORTANT — public repo:** This repository is public. Sanitise everything before committing.

**Never commit:**
- Secrets, tokens, API keys, passwords, private keys, vault passwords.
- Public IPs of real infrastructure (Hetzner Cloud servers, anything internet-routable).
- MAC addresses or SSH host key fingerprints from real machines.

**Use placeholders:**
- Public IPs: TEST-NET ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- MACs: documentation range `00:00:5E:00:53:xx`.

Internal hostnames, LAN/RFC1918 IPs, and internal usernames are fine to commit as-is.

Pre-commit's `detect-private-key` and `check-added-large-files` are backstops, not the gate. Sanitise at write-time. When unsure, ask before committing.

## Conventional commit prefixes

- **`feat:`** — anything that changes what ships in the collection (roles, playbooks, plugins, `galaxy.yml` content, `meta/runtime.yml`, antsibull config, collection README/LICENSE). Initial scaffolding of collection content is also `feat:`.
- **`fix:`** — bug fix in collection content.
- **`refactor:` / `docs:` / `test:`** — standard meanings, applied to collection content.
- **`chore:`** — dev-tooling and repo plumbing only: lint configs, pre-commit, Makefile, `.editorconfig`, `.envrc`, `.gitignore`, `requirements-dev.txt`, top-level `ansible.cfg`.
- **`release:`** — version bump + regenerated changelog. Used only by the single release commit at PR end.

Test: "is this changing what ships to consumers of `jedimasterjonny.lex`, or is this changing how we develop on the repo?" Ships → `feat:` family. Develop → `chore:`.

## Reference

**Paths:**
- Collection root: `collections/ansible_collections/jedimasterjonny/lex/`
- Fragments dir: `collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/`
- Changelog config: `collections/ansible_collections/jedimasterjonny/lex/changelogs/config.yaml`
- Inventory: `inventory/`

**Makefile targets:** `make help`, `make lint`, `make lint-yaml`, `make lint-ansible`.

**Lint configs:** `.yamllint.yml`, `.ansible-lint.yml`, `.pre-commit-config.yaml`.

**Environment:** `.envrc` (direnv) activates `.venv` and exports `ANSIBLE_COLLECTIONS_PATH` and `ANSIBLE_CONFIG`. `ansible.cfg` sets repo-wide defaults.

**Project skills:** see `.claude/skills/`.

- `changelog-fragments` — writes the antsibull-changelog fragment that must accompany every user-visible commit.
- `pr-finalisation` — computes the version bump from accumulated fragments and writes the closing `release:` commit.
