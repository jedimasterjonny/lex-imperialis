.PHONY: lint ansible-lint yamllint hooks pre-commit

lint: yamllint ansible-lint

yamllint:
	. .venv/bin/activate && yamllint .

ansible-lint:
	. .venv/bin/activate && ansible-lint

hooks:
	. .venv/bin/activate && pre-commit install

pre-commit:
	. .venv/bin/activate && pre-commit run --all-files
