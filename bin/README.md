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

## check-render-drift.py

Converges the composed-fleet scenario on a base ref and on the working tree, then
diffs the artefact roots — `/etc/containers/systemd` and `/etc/caddy/sites{,-public}`,
each a directory the repo wholly owns, so `find -type f` is an exact artefact set
and no path list is needed. No committed baseline: the comparison is
head-against-base, so an intended change is reviewed in the PR rather than
recorded. Backs the `render-drift` CI job and `make render-drift BASE=<ref>`.

Solar's play templates `ansible_facts['default_ipv4']['address']` into two
quadlets, so the instance's DHCP address is normalised before the diff; without
that, `cadvisor.container` and `node-exporter.container` differ on every run. Only
the default route's source — the addresses `prepare.yml` adds to `lo` are fixture
literals and must still compare.

`--applies BASE HEAD` prints `run`/`skip` without converging; `discover` gates the
CI job on it. Which roles reach a watched root is derived from their `dest:` paths,
so the trigger cannot drift from what it gates and Phase 3's `container_workload`
is picked up as soon as its `dest:` lands. A PR whose only relevant change is a
renovate digest bump is skipped — those automerge, and the `Image=` move is the
point of them.

`--base-capture DIR` reuses a previous run's base render from `DIR`, or writes it
there; CI caches `DIR` keyed on the base commit and this script, converging one
side instead of two. A wrong base can only produce a false red, never a false
green, since it cannot coincidentally equal a changed head.

**Two limits.** It sees solar and rogue-trader only, so the templates
`restic_backup`, `gitops_reconcile`, `incus`, `libvirt`, `prometheus`,
`blackbox_exporter`, `common`, `dev` and `docker_prune` render are gated by
nothing. And it compares head against base, so it catches a change a PR makes,
never a render that was always wrong. Needs the venv and incus.

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

Projects each fleet host's `inventory/host_vars/<host>.yml` into
`roles/fleet/molecule/default/inventory/group_vars/<group>.yml`, the fixtures the
composed-fleet scenario converges against, and holds that scenario's `converge.yml`
role list to the play's. Two invariants come with it, both enforced against
every playbook and the real inventory: no play may carry a variable in any form —
role params included, which is why `roles:` entries must be bare names — and
`inventory/host_vars/` holds exactly one non-empty `<host>.yml` per host in
`inventory/hosts.yml`. The script argues both where it enforces them. Backs the
`gen-fixture-hostvars` hook, which regenerates and fails the commit on drift, so
neither can become a second source of truth.
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
