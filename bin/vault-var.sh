#!/usr/bin/env bash
# Print one top-level variable's value from the ansible-vault, for feeding a
# TF_VAR_ (Terraform can't read the vault; this bridges it). Needs the venv for
# ansible-vault and a .vault_pass to decrypt.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=/dev/null
. .venv/bin/activate
ansible-vault view inventory/group_vars/all/vault.yml --vault-password-file .vault_pass \
  | python3 -c 'import sys, yaml; d = yaml.safe_load(sys.stdin); k = sys.argv[1]; print(d[k]) if k in d else sys.exit(f"vault-var.sh: {k!r} not in the vault")' "$1"
