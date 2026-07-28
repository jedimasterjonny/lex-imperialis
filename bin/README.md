# bin

Scripts backing the pre-commit hooks (`.pre-commit-config.yaml`, run by `make
pre-commit` in the lint CI gate) and the Makefile.

## check-role-test-coverage.sh

Enforces the test-coverage contract over `roles/`: every role ships a
`molecule/default` (incus) or `molecule/libvirt` scenario; a `libvirt` scenario
requires a `molecule/hetzner` one (its real-VM CI form); and each role in the
hardcoded Leap-16 subset (`leap_roles`) ships a `molecule/leap` scenario. Exits
non-zero listing every gap; runs on every commit, ignoring filenames.

## check-jinja-syntax.py

Parses every `*.j2` handed to it, failing on a Jinja syntax error that would
otherwise surface only when Ansible templates the file — a converge, or a
`gitops_reconcile` apply. The usual cause is a bare `{#` outside a `{% raw %}`
fence, which bash's `${#array[@]}` supplies; `shellcheck-jinja.sh` rewrites
`{% … %}` and `{{ … }}` but not comment tags, so it cannot catch one. Parsing
resolves no variables and looks up no filters, so Ansible-only filters do not
trip it. Needs the venv (jinja2, via ansible-core).

## check-renovate-coverage.py

Fails when a renovate custom manager reaches nothing, or a pinned digest sits
outside every manager's reach: each `managerFilePatterns` entry must match a
tracked file, each manager's `matchStrings` must match at least once across those
files, and every `@sha256:` must be a well-formed `currentDigest` capture.
`renovate-config-validator` exits 0 on a manager matching zero files, so nothing
else can see one die.

Scoring the capture rather than the file or the match span is the point. Nearly
every digest is in `roles/*/vars/main.yml`, which one manager matches by
construction, so a file-level check is near-vacuous; and a tagless `repo@sha256:…`
has its name group eat up to the digest's colon, so renovate extracts no digest
at all while any span check reads as covered. Likewise check 1 is only as sharp as
the patterns are specific, hence one entry per file rather than an alternation
covering several.

Anything it cannot reason about is refused rather than guessed — a non-`regex`
`customType`, a `matchStringsStrategy` other than `any`, a glob or negated file
pattern. A digest owned by a renovate *built-in* manager would read as unreachable;
nothing in the tree is in that shape. Runs on every commit ignoring filenames, since
a digest can be added anywhere and a rename can strand a manager without touching
`renovate.json`. Stdlib only.

## gen-fixture-hostvars.py

Projects each fleet play's `vars:` block into
`roles/fleet/molecule/default/inventory/group_vars/<group>.yml`, the fixtures the
composed-fleet scenario converges against, and holds that scenario's `converge.yml`
role list to the play's. Backs the `gen-fixture-hostvars` hook, which regenerates
and fails the commit on drift, so neither can become a second source of truth.
Extend `PLAYS` alongside the instance that converges the shape. Needs the venv
(PyYAML).

## shellcheck-jinja.sh

Shellchecks the shell-in-Jinja templates the plain `shellcheck` hook skips —
`identify` tags them jinja, not shell: every `*.sh.j2`, plus the
extensionless-bash `wp`/`wp-db-dump` templates. Rewrites Jinja to valid shell
first (`{% … %}` → `:`, `{{ … }}` → `X`), then pipes the result through
shellcheck.

## tofu-validate.sh

Validates `terraform/` offline: `tofu init -backend=false` (skips the GCS state
backend, so no cloud credentials are needed) then `tofu validate`. Backs the
`tofu-validate` hook.

## vault-var.sh

Prints one top-level variable's value from the ansible-vault, bridging a vault
secret into a `TF_VAR_` (Terraform can't read the vault). Backs the
`tofu-plan`/`tofu-apply` make targets and the `terraform.yml` plan workflow.
Needs the venv and `.vault_pass`.
