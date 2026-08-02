# bin

Scripts backing the pre-commit hooks (`.pre-commit-config.yaml`, run by `make
pre-commit` in the lint CI gate) and the Makefile.

## check-role-test-coverage.sh

Enforces the test-coverage contract over `roles/`: every role ships a
`molecule/default` (incus) or `molecule/libvirt` scenario, and a `libvirt`
scenario requires a `molecule/hetzner` one (its real-VM CI form). Exits
non-zero listing every gap; runs on every commit, ignoring filenames.

## check-jinja-syntax.py

Parses every `*.j2` handed to it, failing on a Jinja syntax error that would
otherwise surface only when Ansible templates the file — a converge, or a
`gitops_reconcile` apply. The usual cause is a bare `{#` outside a `{% raw %}`
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
point at the real one.

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
`tofu-plan`/`tofu-apply` make targets and the `terraform.yml` plan workflow.
Needs the venv and `.vault_pass`.
