# Lex Imperialis — top-level Makefile.

.DEFAULT_GOAL := help
.PHONY: help setup hooks lint lint-yaml lint-ansible

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## One-shot dev setup: venv, dev deps, pre-commit hooks.
	test -d .venv || python3 -m venv .venv
	.venv/bin/pip install --upgrade pip wheel
	.venv/bin/pip install -r requirements-dev.txt
	.venv/bin/pre-commit install

hooks: ## (Re)install pre-commit hooks (run after .pre-commit-config.yaml changes).
	.venv/bin/pre-commit install

lint: lint-yaml lint-ansible ## Run all linters.

lint-yaml: ## Run yamllint across the repo.
	yamllint .

lint-ansible: ## Run ansible-lint across the repo.
	ansible-lint
