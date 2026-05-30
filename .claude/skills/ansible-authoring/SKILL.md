---
name: ansible-authoring
description: Use whenever authoring, modifying, or restructuring Ansible role or playbook content under collections/ansible_collections/jedimasterjonny/lex/ — adding or editing tasks, defaults, handlers, vars, meta, jinja2 templates, molecule scenarios, role READMEs; creating a new role; renaming or relocating variables; deciding between two ways of structuring a play or a role. Routes that work through the Red Hat best-practice guidance and the design aphorisms bundled with the ansible MCP server so the result matches established Ansible convention. Trigger even when the user doesn't mention conventions explicitly — if they're touching collection content, this skill applies. Do NOT trigger for changes outside the collection root (lint configs, Makefile, pre-commit, `.envrc`, top-level `ansible.cfg`, `requirements-dev.txt`); those are dev tooling and don't ship.
---

# Authoring Ansible role and playbook content

Before writing or restructuring content for `jedimasterjonny.lex`, consult the guidance the ansible MCP server bundles. Two tools, two purposes — use the one that fits the moment, both if the change spans both.

The repo also ships [`.claude/ansible-good-practices.md`](../../ansible-good-practices.md) — a terse checklist of the high-leverage gotchas `ansible-lint` doesn't catch (variable precedence, multi-distribution layout, the `meta/argument_specs.yml` convention, …). It's always available, including when the MCP tools below can't be reached, so skim the relevant section whenever you author or review role/playbook content.

## ansible_content_best_practices — concrete conventions

What it is: topic-keyed Red Hat guidance covering how roles, playbooks, variables, jinja2 templates, naming, and YAML formatting should be structured. The bundled guidance is authoritative for this repo; if your draft disagrees with it, fix the draft (or be ready to explain the deviation).

When to call it: before authoring any of these — a new role scaffold, a tasks file, defaults, handlers, meta, a jinja2 template, a variable schema, a role README. Treat it as a pre-flight check, not a post-hoc review.

How to call it:

1. First call with `{}` to enumerate the available topics. The set has grown over time, so don't assume from memory.
2. Then call with `{"topic": "<topic>"}` for each section that matches what you're writing. Common topics include `"roles"`, `"playbooks"`, `"naming conventions"`, `"yaml formatting"`, `"variables"`, `"jinja2 templates"`.
3. If a change touches multiple areas (e.g., new role with a new template and a new variable), pull each relevant topic. The sections are short — there is no real cost to fetching two.

The tool's own description tells callers to consult it before authoring; that's worth honouring.

## zen_of_ansible — design philosophy

What it is: 20 aphorisms (in the style of the Zen of Python) capturing Ansible's design philosophy — readability, idempotency, preferring native modules over `shell`/`command`, simplicity over cleverness.

When to call it: when you're choosing between alternative structures and the choice isn't obviously settled by `ansible_content_best_practices`. Concrete moments:

- Two ways to model the same configuration: one role with conditionals vs. two roles with a thin wrapper.
- Push logic into a custom module/filter/plugin, or keep it in tasks.
- Expose a value in `defaults/` (user-tunable) or fix it in `vars/` (role-internal).
- Combine tasks into a `block`, or keep them flat for readability.
- Wire a long shell pipeline into a single `command:` invocation, or break it into native module calls.

Skip it for line-level edits — it's for the design moments, not routine work.

## When NOT to use this skill

- Editing dev tooling: lint configs (`.yamllint.yml`, `.ansible-lint.yml`, `.pre-commit-config.yaml`), `Makefile`, `.envrc`, `.gitignore`, top-level `ansible.cfg`, `requirements-dev.txt`.
- Editing the changelog (`CHANGELOG.md`, `changelogs/changelog.yaml`) or `changelogs/config.yaml` — those are regenerated artefacts.
- Tiny mechanical edits inside the collection where the answer is unambiguous and no design or convention decision is in play: fixing a typo in a comment, bumping a single version pin, renaming a variable across files where the new name is already chosen. The MCP guidance is overhead when the change is purely mechanical.

## Workflow

1. Identify what the change is: content add/edit, structural design choice, or both. Skim the relevant section of `.claude/ansible-good-practices.md` — the always-available baseline.
2. **Content add/edit** → call `ansible_content_best_practices` first. Enumerate topics with `{}`, then pull the topic(s) that match what you're writing.
3. **Structural design choice** → call `zen_of_ansible` and weigh the alternatives against it.
4. Write the change. If your draft disagrees with the guidance, prefer the guidance; an explicit deviation needs an explicit reason.
5. Stage and commit per the usual conventions — see `CLAUDE.md` (clean commits, conventional prefix) and the `changelog-fragments` skill (user-visible changes ship with a fragment in the same commit).
