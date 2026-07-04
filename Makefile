# ROLE selects which role's molecule scenarios to drive; override per role,
# e.g. make test ROLE=foo. MOLECULE_RUN_ID is interpolated into instance names
# so concurrent runs never collide; CI overrides it with a per-run value.
ROLE ?= motd
MOLECULE_RUN_ID ?= local
export MOLECULE_RUN_ID

# PLAY selects which playbook in playbooks/ to run, e.g. make check PLAY=solar.
PLAY ?= scholam

.PHONY: lint ansible-lint yamllint hooks pre-commit test test-leap test-vm test-hetzner destroy-hetzner check apply tofu-fmt tofu-validate tofu-lint tofu-plan tofu-apply

lint: yamllint ansible-lint

yamllint:
	. .venv/bin/activate && yamllint .

ansible-lint:
	. .venv/bin/activate && ansible-lint

hooks:
	. .venv/bin/activate && pre-commit install

pre-commit:
	. .venv/bin/activate && pre-commit run --all-files

test:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test

# Free incus tier on the openSUSE Leap 16 image, for the LEAP_ROLES subset.
test-leap:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test -s leap

test-vm:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test -s libvirt

# --destroy=always: this tier bills a real VM, so tear it down even on failure.
test-hetzner:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test -s hetzner --destroy=always

# Tear down a leaked VM after an interrupted run; the CI teardown backstop calls it.
destroy-hetzner:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule destroy -s hetzner

# Dry run against the live fleet: --check --diff (check mode is best-effort —
# unguarded command/shell tasks still run). .vault_pass decrypts vault vars;
# roles that render secrets set no_log so --diff stays clean.
check:
	. .venv/bin/activate && ansible-playbook playbooks/$(PLAY).yml --vault-password-file .vault_pass --check --diff

# Real apply to the live fleet — the operator's call, not part of any automated flow.
apply:
	. .venv/bin/activate && ansible-playbook playbooks/$(PLAY).yml --vault-password-file .vault_pass

# OpenTofu (terraform/); tofu and tflint are on PATH, no venv. fmt/validate/lint
# are the local forms of the pre-commit gates (fmt writes, unlike the -check hook).
tofu-fmt:
	tofu fmt -recursive terraform

tofu-validate:
	bin/tofu-validate.sh

tofu-lint:
	tflint --chdir=terraform

# plan/apply run against HCP Terraform Cloud, so they need a prior `tofu init` and
# its credentials (TF_CLOUD_ORGANIZATION, TF_WORKSPACE, tofu login, and
# TF_VAR_hcloud_token for local execution) — see terraform/README.md.
tofu-plan:
	tofu -chdir=terraform plan

tofu-apply:
	tofu -chdir=terraform apply
