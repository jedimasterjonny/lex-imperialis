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

Subjects use the scoped form **`type(scope): summary`**, where `scope` is the role or component the commit touches — e.g. `feat(common): add tmux to the baseline package set`, `fix(motd): …`, `chore(lint): …`. Omit the scope only for genuinely cross-cutting changes with no single subject (`chore: …`); never use an issue identifier as the scope. The older two-colon `feat: common: …` form is retired.

- **`feat:`** — anything that changes what ships in the collection (roles, playbooks, plugins, `galaxy.yml` content, `meta/runtime.yml`, antsibull config, collection README/LICENSE). Initial scaffolding of collection content is also `feat:`.
- **`fix:`** — bug fix in collection content.
- **`docs:`** — any documentation change, inside or outside the collection (collection READMEs, top-level `README`, `CLAUDE.md`, `.claude/` guidance).
- **`refactor:` / `test:`** — standard meanings. `refactor:` applies inside or outside the collection; `test:` to collection content.
- **`ci:`** — anything that touches CI (workflow definitions, CI config, pipeline scripts).
- **`chore:`** — dev-tooling and repo plumbing only: lint configs, pre-commit, Makefile, `.editorconfig`, `.envrc`, `.gitignore`, `requirements-dev.txt`, top-level `ansible.cfg`.
- **`release:`** — version bump + regenerated changelog. Used only by the single release commit at PR end.

Test: "is this changing what ships to consumers of `jedimasterjonny.lex`, or is this changing how we develop on the repo?" Ships → `feat:` family. Develop → `chore:`. Documentation, CI, and refactors take their own noun (`docs:` / `ci:` / `refactor:`) by what the change touches, regardless of which side of that split it falls on.

Breaking changes are recorded via `breaking_changes` changelog fragments — that fragment is what `pr-finalisation` reads to compute the major bump, and is the source of truth. A `!` before the colon (`feat(common)!: …`) or a `BREAKING CHANGE:` footer is optional subject-level signalling, not a substitute for the fragment.

## Reference

**Paths:**
- Collection root: `collections/ansible_collections/jedimasterjonny/lex/`
- Fragments dir: `collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/`
- Changelog config: `collections/ansible_collections/jedimasterjonny/lex/changelogs/config.yaml`
- Inventory: `inventory/`

**Makefile targets:** `make help`, `make lint`, `make lint-yaml`, `make lint-ansible`.

**Lint configs:** `.yamllint.yml`, `.ansible-lint.yml`, `.pre-commit-config.yaml`.

**Environment:** `.envrc` (direnv) activates `.venv` and exports `ANSIBLE_COLLECTIONS_PATH` and `ANSIBLE_CONFIG`. `ansible.cfg` sets repo-wide defaults.

**Collections install path:** All collections — third-party deps *and* the built `jedimasterjonny.lex` — install to `~/.ansible/collections`, the sole entry in `ANSIBLE_COLLECTIONS_PATH` (set by `.envrc`). The repo's `collections/` dir holds **only** the tracked `ansible_collections/jedimasterjonny/lex/` source; nothing else belongs there.

- **Never point `ANSIBLE_COLLECTIONS_PATH` at `$PWD/collections`.** `ansible-compat` (under both `ansible-lint` and `molecule`) installs the collection-under-test's dependencies into the var's first writable path. If that is `$PWD/collections`, the deps (`ansible/`, `community/`, `hetzner/`, the `*.info` dirs) land in the repo tree as untracked clutter that breaks repo-wide `make lint` — and it can wipe the source. In a shell without direnv, export the `.envrc` value explicitly: `export ANSIBLE_COLLECTIONS_PATH="$HOME/.ansible/collections"`.
- **Re-sync before `molecule`.** The home-installed collection is a *copy*, not a symlink, so a new or changed role is invisible until reinstalled: `ansible-galaxy collection install ./collections/ansible_collections/jedimasterjonny/lex -p ~/.ansible/collections --force`.
- **Clean leaked deps by name — never a blanket `git clean collections/`,** which would also delete a brand-new untracked role/fragment: `rm -rf collections/ansible_collections/{ansible,community,hetzner} collections/ansible_collections/*.info`.

**Project skills:** see `.claude/skills/`.

- `changelog-fragments` — writes the antsibull-changelog fragment that must accompany every user-visible commit.
- `pr-finalisation` — computes the version bump from accumulated fragments and writes the closing `release:` commit.
- `ansible-authoring` — routes role/playbook authoring through the bundled Red Hat best-practice guidance and the Ansible design aphorisms (ansible MCP server).

**Ansible gotchas reference:** [`.claude/ansible-good-practices.md`](.claude/ansible-good-practices.md) — distilled checklist of non-obvious items from the Red Hat Ansible good-practices guide that `ansible-lint` does not catch (variable-precedence traps, `register` persistence, host-group anti-pattern, etc.). Consult when reviewing or authoring role/playbook content.

## MCP servers

The repo ships a project-scoped `.mcp.json` configuring the `ansible` MCP server.

- **Linting is owned by the repo, not the MCP.** Always use `make lint-ansible` (or `ansible-lint` directly) for linting. Do not invoke the ansible MCP server's `ansible_lint` tool — `.ansible-lint.yml` in this repo is the source of truth, and the MCP tool may apply different rules or auto-fixes that bypass our config.
- **Running plays requires explicit per-invocation permission.** The `ansible_navigator` tool runs playbooks against whatever inventory it can find, and its description encourages it to fire on any "run X" phrasing from the user. Never invoke it autonomously. Always confirm with the user before each run, and prefer check mode (`--check`) unless a real run was explicitly requested — `inventory/` may target real infrastructure.
- **Do not let the MCP touch the dev environment or project scaffold.** The venv (`.venv` + direnv + `requirements-dev.txt`) and the collection layout under `collections/ansible_collections/jedimasterjonny/lex/` are hand-crafted. Do not call `ade_setup_environment`, `adt_check_env`, or `create_ansible_projects` — they install global tooling, create new venvs, or scaffold over existing structure. New roles go inside the existing collection following established conventions, not via the MCP.
- **`.mcp.json` runs the ansible MCP server via `npx`** (`npx -y @ansible/ansible-mcp-server --stdio`), resolving the package by name so the config is cross-platform. It requires Node >= 24 on `PATH`; the lab box gets that from the dev role's `dev_install_node` gate. The `_comment` block at the top of `.mcp.json` records the now-fixed upstream packaging bug (v26.5.0) that previously forced a hardcoded `node dist/cli.cjs` workaround.

For authoring or restructuring collection content, the MCP's `ansible_content_best_practices` and `zen_of_ansible` tools carry the relevant guidance — routed through the `ansible-authoring` skill, which loads on demand.
