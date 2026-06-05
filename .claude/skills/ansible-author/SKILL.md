---
name: ansible-author
description: >-
  Write new or changed Ansible content — roles, playbooks, tasks — to
  good-practice standard the first time, leaning on the ansible MCP server and
  the redhat-cop good practices, then lint it clean and hand off to `refine`.
  Produces a sound, lint-clean draft; it does not run the design/review/molecule
  loop — that is `refine`'s job. Use whenever you are creating or extending
  Ansible code — triggers include "write an ansible role", "scaffold a
  playbook", "add a task that …", "author this role", "write a play to …", even
  when the skill is not named explicitly.
---

# Ansible author

Write Ansible content that is idempotent, check-mode-safe, and good-practice by
construction, then lint it clean and hand it to `refine`. This is the forward
pass — getting the first draft right — not the review loop. The flow, in order:

1. **Establish scope and load repo principles.**
2. **Consult good practices** — the binding checklist below, enriched live from
   the MCP server and the guide for anything situational.
3. **Scaffold or locate** the target structure.
4. **Write** the content to the checklist, matching any surrounding idiom.
5. **Lint** until clean — `ansible_lint` while writing, `make lint` before handoff.
6. **Hand off to `refine`** and report.

## Scope

Name what is being authored: a new role, a new playbook or block of tasks, or an
edit to existing content. That target is the work; keep it that — resist
authoring adjacent roles or speculative variables nobody asked for (YAGNI).

If the request is to *refine* or *review* existing code rather than write new
content, this is the wrong skill — use `refine`.

## Repo principles

Read `CLAUDE.md` (root, plus any nested `CLAUDE.md` on the target path) before
writing. It binds and overrides anything here or any MCP suggestion. Do not
restate its rules in the code; the ones that most shape authoring:

- **No plaintext secrets.** A task that renders a secret sets `no_log: true`,
  else `--diff` prints it. Secrets come from the one vault-encrypted file.
- **No sensitive topology** in roles, plays, or inventory — no public IPs,
  external hostnames, or exposed ports. The repo is public; this maps the
  attack surface.
- **Every task idempotent**, and check-mode-safe — molecule's idempotence check
  enforces it.
- **Live hosts get `--check`/`--diff` only**, never apply. Authoring never runs
  against the fleet.
- **KISS / YAGNI / DRY, single operator** — no generality, configurability, or
  abstraction the homelab will not use.

## MCP server

The project-scoped `ansible` MCP server (`.mcp.json`) is the primary toolset.
It must be loaded and approved in the session (Node 24). If it is absent, fall
back to the equivalent CLIs noted below.

- **`ansible_content_best_practices`, `zen_of_ansible`** — pull live guidance
  before writing; they carry the full, current good practices the checklist
  only distils.
- **`ansible_create_playbook`** — scaffold a new playbook. For a new role, use
  the standard role skeleton (`ansible-galaxy role init`) directly under
  `roles/`. **Do not** use `ansible_create_collection`: this repo is loose
  `roles/` at the root with no collection wrapper (CLAUDE.md), and a role does
  not justify wrapping the repo in one.
- **`ansible_lint`** (`filePath`, optional `fix`) — per-file linting while
  writing; fix findings at their root, never silence a rule. CLI fallback:
  `ansible-lint`. The draft must pass the `make lint` gate before handoff.
- **`ansible_navigator`** executes plays, so it is out of this skill's flow —
  running and verifying belong to molecule under `refine`. If ever invoked, it
  is molecule/ephemeral or `--check` only, never the live fleet.

## Binding checklist

The stable, high-failure-rate core. `CLAUDE.md` owns the repo bindings (secrets,
idempotency, check/diff, KISS); this adds the Ansible craft on top:

- **FQCN for every module and action** — `ansible.builtin.copy`, never `copy`.
- **snake_case everywhere** — variables, files, roles, dict keys; no special
  characters beyond `_`. Descriptive, not abbreviated.
- **Role variables prefixed with the role name.** `defaults/main.yml` holds what
  a caller may override; `vars/main.yml` holds internal constants.
- **Every task a `name:`** — descriptive and imperative.
- **Idempotent by construction** — prefer a module over `command`/`shell`; when
  one is unavoidable, set `changed_when:` (and `failed_when:` where needed) and
  make it check-mode-safe.
- **Handlers and `notify`** for restarts — never restart inline.
- **Thin playbooks** — delegate logic to roles; a playbook wires roles to hosts.

For anything beyond this core — collections, plugins, inventory and variable
modelling, multi-distribution support — defer to the live authority rather than
guessing: the MCP `ansible_content_best_practices` tool and
<https://redhat-cop.github.io/automation-good-practices/>.

## What this skill does not do

- It does not review. The design loop, `simplify`, `code-review`, molecule, and
  the docs pass are `refine` — hand off, do not reimplement them here.
- It does not run plays against live hosts.
- It does not commit. It leaves a lint-clean draft for the operator to refine
  and commit.

## Handoff

When the draft lints clean, summarise what was authored — the files created or
changed and the good-practice decisions worth noting — and point to `refine` as
the next step.
