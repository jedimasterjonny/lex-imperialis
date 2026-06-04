.PHONY: lint ansible-lint yamllint

lint: yamllint ansible-lint

yamllint:
	. .venv/bin/activate && yamllint .

ansible-lint:
	. .venv/bin/activate && ansible-lint
