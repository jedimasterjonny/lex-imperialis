# ROLE selects which role's molecule scenarios to drive; override per role,
# e.g. make test ROLE=foo. MOLECULE_RUN_ID is interpolated into instance names
# so concurrent runs never collide; CI overrides it with a per-run value.
ROLE ?= motd
MOLECULE_RUN_ID ?= local
export MOLECULE_RUN_ID

# SCENARIO picks the scenario the molecule targets drive; the test-* targets pin
# their own, e.g. make converge ROLE=nfs SCENARIO=libvirt.
SCENARIO ?= default

# A scenario's tier owns its provisioner config: both incus scenarios (default
# and leap) take the incus tier's. Recursive (=), not simple (:=) — the test-*
# targets set SCENARIO per target, which is only in scope once the recipe
# expands; := would pin every tier to incus.
TIER = $(if $(filter default leap,$(SCENARIO)),incus,$(SCENARIO))

BASE_CONFIG = molecule/$(TIER)/base.yml

# The hetzner tier's create/destroy read the CI test-project token from
# HCLOUD_TOKEN, not the vault, so a PR-triggered CI run never decrypts the vault.
# CI injects MOLECULE_HCLOUD_TOKEN; locally, source it from the vault. The `:-`
# default only runs bin/vault-var.sh when HCLOUD_TOKEN is unset, so CI (which has
# no .vault_pass) never calls it. Runs before the cd, so bin/vault-var.sh resolves
# from the repo root.
HCLOUD_TOKEN_PREP = $(if $(filter hetzner,$(SCENARIO)),export HCLOUD_TOKEN="$${HCLOUD_TOKEN:-$$(bin/vault-var.sh hcloud_token)}" &&,)

# -c is a global option, so it precedes the subcommand. molecule silently ignores
# a -c path that does not exist and then skips create/destroy with only a
# warning, so assert the file is there: a typo'd SCENARIO, or a scenario whose
# tier has no base.yml, must fail loudly rather than run a no-op.
define molecule
	test -f $(BASE_CONFIG) || \
		{ echo "no such tier: $(BASE_CONFIG) (SCENARIO=$(SCENARIO))" >&2; exit 1; }
	. .venv/bin/activate && $(HCLOUD_TOKEN_PREP) cd roles/$(ROLE) && \
		molecule -c $(CURDIR)/$(BASE_CONFIG) $(1) -s $(SCENARIO)
endef

# PLAY selects which playbook in playbooks/ to run, e.g. make check PLAY=solar.
PLAY ?= scholam

.PHONY: lint ansible-lint yamllint codespell hooks pre-commit converge verify destroy test test-leap test-vm test-hetzner destroy-hetzner check apply tofu-fmt tofu-validate tofu-lint tofu-plan tofu-apply hugo-serve hugo-build

lint: yamllint ansible-lint codespell

yamllint:
	. .venv/bin/activate && yamllint --strict .

ansible-lint:
	. .venv/bin/activate && ansible-lint --strict

codespell:
	. .venv/bin/activate && git ls-files -z | xargs -0 codespell

hooks:
	. .venv/bin/activate && pre-commit install

pre-commit:
	. .venv/bin/activate && pre-commit run --all-files

# Iterate on one role without the full create->destroy lifecycle.
converge:
	$(call molecule,converge)

verify:
	$(call molecule,verify)

destroy:
	$(call molecule,destroy)

test:
	$(call molecule,test)

# Free incus tier on the openSUSE Leap 16 image, for the LEAP_ROLES subset.
test-leap: override SCENARIO := leap
test-leap:
	$(call molecule,test)

test-vm: override SCENARIO := libvirt
test-vm:
	$(call molecule,test)

# --destroy=always: this tier bills a real VM, so tear it down even on failure.
test-hetzner: override SCENARIO := hetzner
test-hetzner:
	$(call molecule,test --destroy=always)

# Tear down a leaked VM after an interrupted run; the CI teardown backstop calls it.
destroy-hetzner: override SCENARIO := hetzner
destroy-hetzner:
	$(call molecule,destroy)

# Dry run against the live fleet: --check --diff (check mode is best-effort —
# unguarded command/shell tasks are skipped, so it under-reports). .vault_pass
# decrypts vault vars; roles that render secrets set no_log so --diff stays clean.
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

# plan/apply store state in a GCS bucket (backend in main.tf), reached via your
# gcloud ADC — no state token. The Cloudflare and Hetzner provider tokens come
# from the vault via bin/vault-var.sh. See terraform/README.md.
TOFU_VAULT_TOKENS = TF_VAR_cloudflare_api_token="$$(bin/vault-var.sh terraform_cloudflare_api_token)" TF_VAR_hcloud_token="$$(bin/vault-var.sh hcloud_token_emmas_edit)"

tofu-plan:
	$(TOFU_VAULT_TOKENS) tofu -chdir=terraform plan

tofu-apply:
	$(TOFU_VAULT_TOKENS) tofu -chdir=terraform apply

# Hugo (jonnyoc-site); needs hugo and go on PATH (module theme fetch), no venv.
# serve for local preview; build mirrors the live deploy (honours buildFuture=false).
hugo-serve:
	cd jonnyoc-site && hugo server

hugo-build:
	cd jonnyoc-site && hugo --minify -d public
