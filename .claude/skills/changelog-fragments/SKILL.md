---
name: changelog-fragments
description: Use whenever editing, creating, or staging files under collections/ansible_collections/jedimasterjonny/lex/ that ship to consumers of jedimasterjonny.lex — roles, playbooks, plugins, galaxy.yml content, meta/runtime.yml, collection README/LICENSE, antsibull config that ships. Writes the antsibull-changelog fragment (YAML in changelogs/fragments/) that must accompany every user-visible commit. Trigger when adding a role, fixing a bug in collection code, deprecating behaviour, changing a default, adding a task, or otherwise making a change a consumer would notice. Do NOT trigger for files outside the collection root, for changelogs/config.yaml, or for the changelogs themselves.
---

# Changelog fragments

Every commit that makes a user-visible change to the collection ships with a changelog fragment in the same commit. Antsibull-changelog consumes these fragments at release time and assembles them into `CHANGELOG.md`.

A "user-visible change" is anything a consumer of `jedimasterjonny.lex` would notice: a new role, a behaviour change, a new variable, a deprecation, a removal, a bug fix, a security fix, a doc change to a shipped role's README. Internal refactors, dev tooling, lint configs, and repo-level docs are **not** user-visible — those commits get no fragment.

## Where the fragment goes

Path: `collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/`

Filename: a short kebab-case slug describing the change, ending in `.yml`. Examples:

- `add-baseline-role.yml`
- `fix-baseline-timezone-idempotency.yml`
- `deprecate-legacy-firewall-vars.yml`

The slug is for human scanning; antsibull doesn't parse it.

## Format

YAML with one or more sections. Each section is a list of strings. Most fragments have one section with one bullet:

```yaml
---
minor_changes:
  - "baseline - add support for configuring the system timezone."
```

Multiple bullets are fine if a single commit genuinely touches several user-visible things in the same category:

```yaml
---
bugfixes:
  - "baseline - fix idempotency when /etc/timezone is a symlink."
  - "baseline - handle missing tzdata package on minimal images."
```

Multiple sections are fine if a commit spans categories (e.g., a deprecation paired with the new behaviour):

```yaml
---
minor_changes:
  - "baseline - add new firewall_rules variable replacing firewall_legacy_rules."
deprecated_features:
  - "baseline - deprecate firewall_legacy_rules in favour of firewall_rules."
```

## Choosing the section

The available sections (defined in `collections/ansible_collections/jedimasterjonny/lex/changelogs/config.yaml`):

| Section               | When to use                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------- |
| `security_fixes`      | Any fix with security implications. Use this even for small fixes if security is the reason.      |
| `bugfixes`            | Non-security bug fixes. Idempotency fixes belong here.                                            |
| `breaking_changes`    | Removed or renamed variables, changed defaults that alter behaviour, removed roles or tasks.      |
| `deprecated_features` | Feature still works but is marked for future removal. Pair with the replacement in `minor_changes` if applicable. |
| `removed_features`    | Feature actually removed (typically after a deprecation cycle).                                   |
| `minor_changes`       | New roles, new tasks, new variables with safe defaults, behaviour improvements without breakage. The default for additive work. |
| `major_changes`       | Large user-visible reworks that aren't strictly breaking. Rare — when in doubt, prefer `minor_changes`. |
| `known_issues`        | Documented limitations not yet fixed.                                                             |
| `trivial`             | Escape hatch — fragment is parsed and consumed but excluded from the published changelog and does not contribute to the version bump. Almost never the right choice here: if a change isn't user-visible, the rule above says skip the fragment entirely. |

If a change is genuinely not user-visible but you've ended up here anyway, don't write a fragment — reconsider whether the change belongs in this commit.

## Style of the entry

- **Prefix with the role or component** when the change is scoped to one (`baseline - ...`, `firewall - ...`). Omit the prefix for cross-cutting changes.
- **Imperative present tense**, lowercase after the prefix: `"add support for X"`, `"fix idempotency on Y"`, `"deprecate Z"`.
- **End with a period.**
- **No PR or issue references.** Antsibull picks up release context from the version bump; the fragment just describes the change.
- **Describe the user-visible effect**, not the implementation. "Fix idempotency when /etc/timezone is a symlink" is good. "Refactor symlink handling in tz module" is not — that's the *what*, not the *why-it-matters*.

## Workflow

When you've made a user-visible change to the collection:

1. Decide the section based on the table above.
2. Write the fragment as a new file in `collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/<slug>.yml`.
3. Stage the fragment in the **same commit** as the change it describes:
   ```
   git add path/to/changed/file path/to/changelogs/fragments/<slug>.yml
   ```
4. Commit normally. The pre-commit hooks will lint the YAML.

One fragment per user-visible commit. If a PR has multiple user-visible commits, each commit gets its own fragment.

## When NOT to write a fragment

Skip the fragment for:

- Anything outside `collections/ansible_collections/jedimasterjonny/lex/`.
- `chore:` commits — dev tooling, lint configs, pre-commit, Makefile, `.envrc`, `.gitignore`, top-level `ansible.cfg`.
- Changes to `changelogs/config.yaml` itself, or to `CHANGELOG.md` / `changelogs/changelog.yaml` (those are regenerated).
- Pure-internal refactors of collection code that produce no behaviour change a consumer can observe.

When in doubt, apply the test from `CLAUDE.md`: *would a consumer of `jedimasterjonny.lex` notice?* If yes, write a fragment. If no, don't.
