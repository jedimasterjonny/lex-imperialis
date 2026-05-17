# Lex Imperialis

Ansible roles for a SUSE-based home lab.

As it is written in the Lex Imperialis, so shall it be deployed.

## Repo layout

- `collections/ansible_collections/jedimasterjonny/lex/` — the [`jedimasterjonny.lex`](collections/ansible_collections/jedimasterjonny/lex/README.md) Ansible collection (roles, playbooks).
- `bootstrap/` — setup for a fresh openSUSE box.
- `playbooks/` — top-level playbooks.
- `inventory/` — environment inventories (production homelab, lab box itself).

## Hosts

- **`scholam`** — lab box

## Bringing up a lab box

See [`bootstrap/README.md`](bootstrap/README.md).

1.  **Stage 1** — `bootstrap/stage1.sh`, off-box.
2.  **Stage 2** — `playbooks/lab-bootstrap.yml`, on-box via `make lab-bootstrap`.

## Quickstart

After cloning, with Python 3.12+ and direnv installed:

```bash
make setup
direnv allow .
```

## Development

- `make lint` — runs yamllint, ansible-lint, and shellcheck.
- `make lab-bootstrap` — runs `playbooks/lab-bootstrap.yml` against `ansible@localhost`. Pass extra `ansible-playbook` flags via `ARGS`, e.g. `make lab-bootstrap ARGS='--check --diff'`.
- `make hooks` — reinstalls pre-commit hooks after `.pre-commit-config.yaml` changes.
- `make collections` — reinstalls Galaxy collections after `requirements.yml` changes.

See `make help` for all targets.

### Testing

All driven by Molecule with the `default` (delegated) driver:

| Tier | Scenario | Backend | When |
|------|----------|---------|------|
| 1 | `default` | Incus containers on the lab box | dev loop |
| 2 | `full` | libvirt/KVM VMs on the lab box | VM-only behaviour |

- `make test ROLE=<name>` — runs Tier 1 for one role.
- `make test-full ROLE=<name>` — runs Tier 2 for one role (requires a `full` scenario).
- `make test-all` — sweeps every role with a default scenario.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
