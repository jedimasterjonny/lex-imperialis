# bin

Scripts backing the pre-commit hooks (`.pre-commit-config.yaml`, run by `make
pre-commit` in the lint CI gate), the Makefile, the molecule workflow, and the
`arbites` reconciler.

## ansible-lint-scoped.sh

Runs `ansible-lint --strict` over the lint targets the changed paths map to — a
role directory, a playbook, a molecule tier — rather than the whole repo. The gate
costs one `ansible-playbook --syntax-check` subprocess per role, playbook and
scenario file, ~107s of them, and the hook paid all of it on every commit whatever
the diff held; a one-role commit is now ~6s. With no arguments it lints everything,
which is what `make ansible-lint` and pre-commit's `--all-files` (so CI) do. Paths
under `inventory/` and `bootstrap/` map to the directory, since `.ansible-lint`'s
`exclude_paths` apply while walking one but not to a file named outright, and a
change to `.ansible-lint`, `ansible.cfg` or the requirements files widens to the
whole repo. Also drops the duplicate-collection warnings a venv's `lib64 -> lib`
symlink provokes — 92 lines per run, every other warning kept. What scoping gives
up is a cross-file break the diff does not name: a role deleted without the play
that runs it being edited in the same commit. `make lint` and CI still lint whole.

## check-role-test-coverage.sh

Enforces the test-coverage contract over `roles/`: every role ships a
`molecule/default` (incus) or `molecule/libvirt` scenario, and a `libvirt`
scenario requires a `molecule/hetzner` one (its real-VM CI form). Exits
non-zero listing every gap; runs on every commit, ignoring filenames.

## check-alert-test-coverage.py

Holds `roles/prometheus`'s alert rules and their promtool cases to what `promtool`
cannot see: every rule has a case, every case names a live rule (promtool passes a
case naming a dead rule whenever it expects no alerts), and `SystemdUnitFailed`'s
exclusion roster, `ScheduledJobMetricMissing`'s clauses and the case driving them
name the same units — a unit excluded from the catch-all but absent from
`ScheduledJobMetricMissing` is monitored by neither rule. Both rosters are read out
of the rules' own expressions, so neither can drift from what ships. Parses every
file as YAML: a rule comment already contains the string `alert:`. Globs
`tests/*_test.yml` rather than naming one, so a case moved between them for its
evaluation grid stays counted. Backs the `alert-test-coverage` hook, on a change to
the rules or the tests. Needs the venv (PyYAML).

## check-jinja-syntax.py

Parses every `*.j2` handed to it, failing on a Jinja syntax error that would
otherwise surface only when Ansible templates the file — a converge, or a
`arbites` apply. The usual cause is a bare `{#` outside a `{% raw %}`
fence, which bash's `${#array[@]}` supplies; `shellcheck-jinja.sh` rewrites
`{% … %}` and `{{ … }}` but not comment tags, so it cannot catch one. Parsing
resolves no variables and looks up no filters, so Ansible-only filters do not
trip it. Needs the venv (jinja2, via ansible-core).

## check-csp-hashes.py

Compares the CSP `script-src` hashes in `jonnyoc-site/firebase.json` against the
inline scripts a built site serves, failing either way round — a served script
with no pin (the live breakage) or a pin nothing serves (its stale remnant).
Takes the build directory and `firebase.json`; needs a fresh `make hugo-build`,
so it runs in the site gate's build job, not a pre-commit hook. Counts only
executable scripts: a non-JavaScript `type` is a data block that script-src never
applies to, which is why the theme's `application/ld+json` is ignored.

## expand-role-consumers.sh

Expands a set of changed role names, read on stdin, to the closure molecule must
converge: a role's consumers come with it, transitively. `restic_backup` and
`stow` are engines rather than plays' roles, and an engine's own scenario tests
the engine — so a PR touching only `restic_backup` runs green while `home_backup`
and `podman_backup`, whose scenarios assert the units, timers and metrics it
renders for them, are never converged, and `arbites` applies main to the fleet
within ~15 min. The edge list is derived from the tree's own `include_role` calls
rather than kept here, and a shape it cannot read aborts the run instead of
silently narrowing the matrix. Backs the discover job in
`.github/workflows/molecule.yml`; the `patrol` and `refine` skills call it to
pick the scenarios a change has to be tested against.

## shellcheck-jinja.sh

Shellchecks the shell-in-Jinja templates the plain `shellcheck` hook skips —
`identify` tags them jinja, not shell: every `*.sh.j2`, plus the
extensionless-bash `wp`/`wp-db-dump` templates. Rewrites Jinja to valid shell
first (`{% … %}` → `:`, `{{ … }}` → `X`), then pipes the result through
shellcheck.

## butane-lint.sh

Compiles each `*.bu` with `butane --strict --check`, discarding the output — the
compiled Ignition is never committed, so the check is the whole point. One file
per invocation, because butane takes a single input and exits 2 on a batch.
Backs the `butane` hook; needs `butane` on PATH (`roles/dev`).

## packer.sh

Everything that runs HashiCorp packer, behind one binary guard: `fmt` (writes)
and `fmt-check` (the `packer-fmt` hook), `validate` (the `packer-validate` hook),
and `build` (`make image`). The guard is there because openSUSE's cracklib owns
`/usr/sbin/packer` and that binary hangs rather than failing; set `PACKER` to
point at the real one. `build` also requires the version
`.github/workflows/lint.yml` pins — the one verb CI never re-runs at it.

`validate` and `build` activate the venv, since packer's ansible provisioner
needs `ansible-playbook`, and generate a throwaway ed25519 pair — packer parses
the private half even to validate. Only `build` reaches Hetzner: it uploads the
public half, which is why the pair cannot be one of yours, sources the API token
through `vault-var.sh`, and bills real servers. See `packer/README.md`.

## tofu-validate.sh

Validates `terraform/` offline: `tofu init -backend=false` (skips the GCS state
backend, so no cloud credentials are needed) then `tofu validate`. Backs the
`tofu-validate` hook.

## vault-var.sh

Prints one top-level variable's value from the ansible-vault, bridging a vault
secret into a `TF_VAR_` (Terraform can't read the vault). Backs the
`tofu-plan`/`tofu-apply` make targets, and nothing in CI: the workflows hold
their provider tokens as GitHub secrets and never decrypt the vault. Needs the
venv and `.vault_pass`.

## fleet-apply.sh

Applies `playbooks/site.yml` to the whole fleet, sharding it by host with
`--limit` so the remote hosts converge at once and `this_host` goes last. Backs
`make apply PLAY=site` and `make check PLAY=site` as well as the `arbites`
reconcile; every argument is passed through to each `ansible-playbook`, and
ansible is taken off `PATH` so the reconciler's venv wins. Four single-host
plays leave ansible's forks nothing to parallelise, so running them in series
costs their sum — ~11 minutes, the controller idle for 77% of it on serial SSH
round trips. Concurrently the remote hosts cost what the slowest of them does:
measured, the three together took 307s against 557s in series, and none was
slower for the other two running beside it.

The host list is read from the inventory, so a host joining the fleet needs no
edit here, and one not yet in `site.yml` matches no play and costs a no-op.
Output is prefixed per host to stay attributable once the plays interleave, in a
terminal and in the reconciler's journal alike. Each host is attempted even when
another has failed — unlike a plain `site.yml` run, where a host that loses its
play aborts every play imported after it — and any failure still exits non-zero.
