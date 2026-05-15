# Lex Imperialis

Ansible roles for a SUSE-based home lab.

As it is written in the Lex Imperialis, so shall it be deployed.

## Repo layout

- `collections/ansible_collections/jedimasterjonny/lex/` — the [`jedimasterjonny.lex`](collections/ansible_collections/jedimasterjonny/lex/README.md) Ansible collection (roles, playbooks).
- `inventory/` — environment inventories (production homelab, lab box itself).

## Hosts

- **`scholam`** — lab box

## Quickstart

After cloning, with Python 3.12+ and direnv installed:

```bash
make setup
direnv allow .
```

## Development

- `make lint` — runs yamllint and ansible-lint.
- `make hooks` — reinstalls pre-commit hooks after `.pre-commit-config.yaml` changes.

See `make help` for all targets.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
