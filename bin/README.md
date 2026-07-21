# bin

Scripts backing the pre-commit hooks (`.pre-commit-config.yaml`, run by `make
pre-commit` in the lint CI gate) and the Makefile.

## check-role-test-coverage.sh

Enforces the test-coverage contract over `roles/`: every role ships a
`molecule/default` (incus) or `molecule/libvirt` scenario; a `libvirt` scenario
requires a `molecule/hetzner` one (its real-VM CI form); and each role in the
hardcoded Leap-16 subset (`leap_roles`) ships a `molecule/leap` scenario. Exits
non-zero listing every gap; runs on every commit, ignoring filenames.

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
