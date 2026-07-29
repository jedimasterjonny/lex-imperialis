#!/usr/bin/env bash
# Packer gates and the image build, behind one binary guard: openSUSE's cracklib
# owns /usr/sbin/packer, and that binary answers `version` with "0 0" and reads
# stdin rather than failing, so an unguarded call hangs instead of erroring.
# Set PACKER to point at the real one.
#
# fmt-check and validate back the pre-commit hooks, fmt is `make packer-fmt` and
# writes, build is `make image` and bills real servers.
set -euo pipefail

PACKER=${PACKER:-packer}
TEMPLATE=packer/microos.pkr.hcl

# </dev/null matters: cracklib-packer reads stdin to EOF before printing, and
# grep -q cannot short-circuit on a non-match, so from a terminal the guard would
# deadlock on precisely the binary it exists to reject.
"$PACKER" version </dev/null 2>/dev/null | grep -q '^Packer v' || {
    echo "$PACKER is not HashiCorp Packer (openSUSE's cracklib owns /usr/sbin/packer)." >&2
    echo "Install it and re-run, or set PACKER=/path/to/packer." >&2
    exit 1
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The ansible provisioner, and validate's preparation of it, need
# ansible-playbook, which lives only in the venv. Activated here rather than
# left to the caller, as vault-var.sh does: a build that discovers this at the
# first provisioner has already created and rescue-booted a billed server. Not
# for the fmt verbs, which touch no Python and must work without a venv.
activate_venv() {
    # shellcheck source=/dev/null
    . .venv/bin/activate
}

# The template's key variables have no defaults. Packer uploads the public half
# of whatever ssh_private_key_file names, and Hetzner rejects duplicate public
# key material project-wide, so any key already registered there fails the build
# with uniqueness_error; a pair generated per run is unique by construction, and
# never outlives it. validate needs one too -- packer parses the private half
# rather than just stat-ing it.
generate_keypair() {
    keydir=$(mktemp -d)
    trap 'rm -rf "$keydir"' EXIT
    ssh-keygen -q -t ed25519 -N '' -C packer-microos -f "$keydir/key"
    PKR_VAR_ssh_public_key=$(cat "$keydir/key.pub")
    PKR_VAR_ssh_private_key_file="$keydir/key"
    export PKR_VAR_ssh_public_key PKR_VAR_ssh_private_key_file
}

case "${1:-}" in
fmt)
    "$PACKER" fmt -recursive packer
    ;;
fmt-check)
    "$PACKER" fmt -check -recursive packer
    ;;
validate)
    # validate resolves the source and provisioner blocks against their plugins,
    # so it fails with "Missing plugins" unless they are installed -- init is a
    # no-op once they are, and only reaches the network on a cold machine like a
    # CI runner. Same shape as tofu-validate.sh's init.
    activate_venv
    "$PACKER" init "$TEMPLATE" >/dev/null
    generate_keypair
    # Deliberately not a single letter: the token is a sensitive variable, and
    # packer redacts every occurrence of its value in its own output, which
    # would silently mangle unrelated error text.
    PKR_VAR_hcloud_token=validate-only-not-a-real-token \
        "$PACKER" validate "$TEMPLATE"
    ;;
build)
    activate_venv
    "$PACKER" init "$TEMPLATE" >/dev/null
    generate_keypair
    PKR_VAR_hcloud_token=$(bin/vault-var.sh hcloud_token_emmas_edit)
    export PKR_VAR_hcloud_token
    # One -only per call, in order and not in parallel: stage 2 boots stage 1's
    # snapshot. -only exits 0 when it matches nothing, so a renamed build block
    # would turn both calls into silent no-ops reporting a successful build of
    # nothing -- hence checking each name is really in the template first.
    for stage in stage1-base stage2-containerhost; do
        grep -q "name *= *\"$stage\"" "$TEMPLATE" || {
            echo "packer.sh: no build block named $stage in $TEMPLATE" >&2
            exit 1
        }
        "$PACKER" build -only="$stage.*" "$TEMPLATE"
    done
    ;;
*)
    echo "usage: packer.sh fmt|fmt-check|validate|build" >&2
    exit 1
    ;;
esac
