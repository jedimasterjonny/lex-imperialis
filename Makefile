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
	. .venv/bin/activate && cd roles/motd && molecule test

test-vm:
	. .venv/bin/activate && cd roles/motd && molecule test -s libvirt

# --destroy=always: this tier bills a real VM, so tear it down even on failure.
test-hetzner:
	. .venv/bin/activate && cd roles/motd && molecule test -s hetzner --destroy=always

# Tear down a leaked VM after an interrupted run; the CI teardown backstop calls it.
destroy-hetzner:
	. .venv/bin/activate && cd roles/motd && molecule destroy -s hetzner
