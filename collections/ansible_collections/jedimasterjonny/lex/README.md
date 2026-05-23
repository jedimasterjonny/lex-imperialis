# jedimasterjonny.lex

Ansible collection for a SUSE-based home lab.

As it is written in the Lex Imperialis, so shall it be deployed.

## Requirements

Ansible core >= 2.19.

## Roles

| Role | Description |
|------|-------------|
| [`common`](roles/common/) | Install baseline packages and enable sshd. |
| [`dev`](roles/dev/) | Install developer and Ansible-author tooling; depends on `common`. |
| [`motd`](roles/motd/) | Manage `/etc/motd` from a single overridable `motd_text` var. |

## Installation

```bash
ansible-galaxy collection install jedimasterjonny.lex
```

## Development

See the [project repository](https://github.com/jedimasterjonny/lex-imperialis) for dev setup, lint, and the Molecule test workflow.
