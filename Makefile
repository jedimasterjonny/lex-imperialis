# Lex Imperialis — top-level Makefile.

.DEFAULT_GOAL := help
.PHONY: help setup hooks collections lint lint-yaml lint-ansible lint-shell lab-bootstrap

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## One-shot dev setup: venv, dev deps, Galaxy collections, pre-commit hooks.
	test -d .venv || python3 -m venv .venv
	.venv/bin/pip install --upgrade pip wheel
	.venv/bin/pip install -r requirements-dev.txt
	.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections
	.venv/bin/pre-commit install

hooks: ## (Re)install pre-commit hooks (run after .pre-commit-config.yaml changes).
	.venv/bin/pre-commit install

collections: ## (Re)install Galaxy collections (run after requirements.yml changes).
	.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections

lint: lint-yaml lint-ansible lint-shell ## Run all linters.

lint-yaml: ## Run yamllint across the repo.
	yamllint .

lint-ansible: ## Run ansible-lint across the repo.
	ansible-lint

lint-shell: ## Run shellcheck across the repo.
	find . -type f \( -name '*.sh' -o -name '*.bash' \) \
	  -not -path './.venv/*' -not -path './.git/*' -not -path './.ansible/*' \
	  -not -path './collections/ansible_collections/community*' \
	  -not -path './collections/ansible_collections/ansible*' \
	  -print0 | xargs -0 -r shellcheck

lab-bootstrap: ## Run the lab bootstrap playbook (on-box; targets ansible@localhost).
	ansible-playbook -i inventory/lab.yml playbooks/lab-bootstrap.yml $(ARGS)
