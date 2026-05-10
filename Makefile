# Lex Imperialis — top-level Makefile.

.DEFAULT_GOAL := help
.PHONY: help lint lint-yaml lint-ansible

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: lint-yaml lint-ansible ## Run all linters.

lint-yaml: ## Run yamllint across the repo.
	yamllint .

lint-ansible: ## Run ansible-lint across the repo.
	ansible-lint
