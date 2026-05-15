# Lex Imperialis — top-level Makefile.

.DEFAULT_GOAL := help
.PHONY: help setup hooks collections lint lint-yaml lint-ansible lint-shell test test-all lab-bootstrap

ROLE ?=
ROLE_PATH := collections/ansible_collections/jedimasterjonny/lex/roles/$(ROLE)

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## One-shot dev setup: venv, dev deps, Galaxy collections, pre-commit hooks.
	test -d .venv || python3 -m venv .venv
	.venv/bin/pip install --upgrade pip wheel
	.venv/bin/pip install -r requirements-dev.txt
	.venv/bin/ansible-galaxy collection install -r requirements.yml -p ~/.ansible/collections
	.venv/bin/pre-commit install

hooks: ## (Re)install pre-commit hooks (run after .pre-commit-config.yaml changes).
	.venv/bin/pre-commit install

collections: ## (Re)install Galaxy collections (run after requirements.yml changes).
	.venv/bin/ansible-galaxy collection install -r requirements.yml -p ~/.ansible/collections

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

test: ## Run Tier 1 (Incus) for ROLE=<name>. Example: make test ROLE=motd
	@if [ -z "$(ROLE)" ]; then echo "ERROR: pass ROLE=<name> (e.g. make test ROLE=motd)"; exit 2; fi
	@if [ ! -d "$(ROLE_PATH)" ]; then echo "ERROR: role not found at $(ROLE_PATH)"; exit 2; fi
	cd $(ROLE_PATH) && molecule test -s default

test-all: ## Run Tier 1 across every role in the collection, sequentially.
	@for role in $$(ls collections/ansible_collections/jedimasterjonny/lex/roles/); do \
	  if [ -d "collections/ansible_collections/jedimasterjonny/lex/roles/$$role/molecule/default" ]; then \
	    echo "==> testing $$role"; \
	    cd collections/ansible_collections/jedimasterjonny/lex/roles/$$role && molecule test -s default || exit $$?; \
	    cd - > /dev/null; \
	  fi; \
	done

lab-bootstrap: ## Run the lab bootstrap playbook (on-box; targets ansible@localhost).
	ansible-playbook -i inventory/lab.yml playbooks/lab-bootstrap.yml $(ARGS)
