# ROLE selects which role's molecule scenarios to drive; override per role,
# e.g. make test ROLE=foo. MOLECULE_RUN_ID is interpolated into instance names
# so concurrent runs never collide; CI overrides it with a per-run value.
ROLE ?= motd
MOLECULE_RUN_ID ?= local
export MOLECULE_RUN_ID

.PHONY: lint ansible-lint yamllint hooks pre-commit test test-vm test-hetzner destroy-hetzner

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

test-vm:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test -s libvirt

# --destroy=always: this tier bills a real VM, so tear it down even on failure.
test-hetzner:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule test -s hetzner --destroy=always

# Tear down a leaked VM after an interrupted run; the CI teardown backstop calls it.
destroy-hetzner:
	. .venv/bin/activate && cd roles/$(ROLE) && molecule destroy -s hetzner
