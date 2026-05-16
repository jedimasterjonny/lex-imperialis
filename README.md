# Lex Imperialis

Ansible roles for a SUSE-based home lab.

As it is written in the Lex Imperialis, so shall it be deployed.

## Repo layout

- `collections/ansible_collections/jedimasterjonny/lex/` — the [`jedimasterjonny.lex`](collections/ansible_collections/jedimasterjonny/lex/README.md) Ansible collection (roles, playbooks).
- `inventory/` — environment inventories (production homelab, lab box itself).

## Hosts

- **`scholam`** — lab box

## Quickstart

> Fresh openSUSE box? Start with [`bootstrap/README.md`](bootstrap/README.md) for
> the one-time stage-1 setup, then come back here.

After cloning, with Python 3.12+ and direnv installed:

```bash
make setup
direnv allow .
```

## Development

- `make lint` — runs yamllint, ansible-lint, and shellcheck.
- `make lab-bootstrap` — runs the bootstrap playbook against the lab box (`scholam`).
- `make hooks` — reinstalls pre-commit hooks after `.pre-commit-config.yaml` changes.
- `make collections` — reinstalls Galaxy collections after `requirements.yml` changes.

See `make help` for all targets.

### Testing

All driven by Molecule with the `default` (delegated) driver:

| Tier | Scenario | Backend | When |
|------|----------|---------|------|
| 1 | `default` | Incus containers on the lab box | dev loop |

- `make test ROLE=<name>` — runs Tier 1 for one role.
- `make test-all` — sweeps every role with a default scenario.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
