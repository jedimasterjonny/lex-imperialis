# Ansible good practices — non-obvious gotchas

Distilled from <https://redhat-cop.github.io/automation-good-practices/>.

This is a checklist of the items that are **easy to get wrong even when you know Ansible** — gotchas that `ansible-lint` does not catch. The full Red Hat guidance is bundled in the `ansible_content_best_practices` MCP tool (consult via the `ansible-authoring` skill); this file pins the high-leverage points so a reviewer can spot violations quickly.

## Naming

- **Prefix every role-public variable with the role name.** `motd_text`, not `text`. Ansible has no namespaces; collisions across roles silently win or lose by precedence.
- **Prefix role-internal variables with `__rolename_`** (double underscore). Marks them as not part of the public interface. Applies to names you create with `set_fact` or `register` inside a role.
- **No dashes in role names.** Breaks collection import.
- **Custom modules inside a role and tags scoped to a role also get the role-name prefix.**
- **Prefix tasks in sub-task files with `<filename> | …`** so log lines (`TASK [motd : sub | Render template]`) say where the task lives.

## Vars vs defaults

- **`vars/main.yml` is high precedence — callers cannot easily override it.** Anything a user might tune goes in `defaults/main.yml`. Reserve `vars/main.yml` for role constants and large internal lists ("magic values").
- **Don't invent a default for a variable that has no safe default.** Better to fail fast than to do something dangerously wrong. Comment the entry out in `defaults/main.yml` so the variable surface is still documented.
- **List every caller-settable variable in `defaults/main.yml`.** Don't sprinkle `| default()` filters across tasks — the default belongs in `defaults/`.

## Idempotency and check mode

- **Roles must work in check mode.** They must not fail and must not falsely report changes.
- **`command:` and `shell:` always report changed.** Add `changed_when:` to give them real change semantics, or pick a dedicated module (`slurp` instead of `command: cat`, etc.).
- **`register:` variables are global and persistent across runs.** If a task is skipped (e.g. in check mode) but later code references the registered variable, you get stale or missing data. Plan registers around possible skips.
- **Use `ansible_facts['name']` (bracket form), not `ansible_facts.name` or `ansible_name`.** The dotted forms are subject to fact-injection issues.

## Multi-distribution support

- **Don't branch on distribution inside tasks.** Add a file under `vars/` per distro and load it via `lookup('first_found')`. Adding a new distro then means "drop a file in".
- **Search order, least to most specific:** `os_family.yml`, `distribution.yml`, `distribution_{major_version}.yml`, `distribution_{version}.yml`. Use `skip: true` if you don't want to require a fallback `default.yml`.
- **Always anchor `first_found` and `include_*` paths with `{{ role_path }}/…`.** Without it, Ansible's search path can resolve a file in a *calling* role and silently load the wrong one.

## Playbooks

- **Keep playbooks thin — a list of roles is the ideal shape.** Logic lives in roles or modules.
- **Don't mix `roles:` and `tasks:` in the same play.** Execution order between the two sections is not obvious.
- **Don't bake inventory group names into role logic.** Take host lists as variables. Hard-coding a group name prevents a single inventory from describing two clusters with the same shape.
- **Every tag must be safe to use in isolation.** Don't ship a tag that, run alone, leaves a host half-configured or destructive.
- **Use `verbosity:` on `debug:` tasks** so they only fire at the requested `-v` level.

## Inventory and variables

- **Inventory is a directory, not a single file.** `groups_and_hosts`, `group_vars/`, `host_vars/`, plus any dynamic-inventory plugin config. Reduces merge conflicts and surfaces the structure of the estate.
- **Rely on inventory groups for iteration; do not build a host list in a var and loop over it.** Custom lists lose `--limit`, throttling, parallelism, and group-variable inheritance.
- **Extra vars are not state.** Use them for debug toggles, runtime safety prompts, or fact simulation only. Desired state goes in inventory — extra vars vanish with job history, leaving no audit trail.
- **Distinguish As-Is (facts) from To-Be (variables).** Never let a fact name collide with a desired-state variable.

## Templates and file management

- **Top every template with `{{ ansible_managed | comment }}`** so a human knows not to hand-edit it.
- **No `Last modified: {{ now() }}`-style timestamps.** They make the file appear changed on every run and break idempotent change reporting.
- **Default `backup: true`** on file-modifying modules until a user asks for it to be tunable.

## Role README and argument validation

- **The role README declares idempotency and (where applicable) atomicity** explicitly as True/False, alongside inputs, outputs, and a worked example playbook.
- **Every role with caller-settable variables ships `meta/argument_specs.yml`.** Inputs are validated at role entry, so a wrong type or a misspelled key fails fast instead of surfacing as a confusing error at task N. `ansible-lint` validates a spec it finds but does not require one to exist — a new role won't be flagged for missing it.
- **Declare the contract — type, structure, requiredness — not default values.** `defaults/main.yml` stays the single source of truth; restating defaults in the spec is a second copy to drift. The trade-off is that `ansible-doc` shows types and descriptions but not concrete defaults.
- **Leave semantic rules to gated asserts in `tasks/main.yml`.** Conditional-required (X only when Y is set), subset relationships, and "this shape only when the feature is enabled" aren't expressible as a type contract. `argument_specs` is the type layer beneath those asserts, not a replacement.

## YAML / Jinja2 niceties

- **Fold long lines with `>-`, not `>`.** Plain `>` keeps a trailing newline that surprises shell commands and `content:` values.
- **Break a long `when:` `and`-chain into a list.** Each condition on its own line — the implicit join is `and`.
- Example IPs in docs use RFC 5737 / 7042 / 3849 ranges (already covered under public-repo safety in `CLAUDE.md`).
