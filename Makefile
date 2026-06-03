.PHONY: lint

lint:
	. .venv/bin/activate && ansible-lint
