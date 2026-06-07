.PHONY: lint ansible-lint yamllint hooks pre-commit test test-vm test-hetzner

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
