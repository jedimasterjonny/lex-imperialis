#!/usr/bin/env bash
# Swap pinned container image refs in place on this host and bounce the quadlet
# units that carried them. The per-host half of arbites's container fast path,
# run as root by playbooks/container-refresh.yml; arguments are old/new ref
# pairs. Prints `matched <old-ref>` for a pair found in some file — the
# playbook's coverage assert and changed state read these — and
# `refreshed <unit>` for each unit bounced. A pair this host does not carry is
# a silent no-op: not every host runs every container.
set -euo pipefail

if [ $# -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
    echo "usage: $0 <old-ref> <new-ref> [<old-ref> <new-ref> ...]" >&2
    exit 64
fi

# Everywhere a renovate-pinned ref renders (the roles/CLAUDE.md contract):
# quadlet units, and rendered wrapper scripts (wordpress's wp and wp-db-dump).
# /usr/local/sbin is swept as a tripwire only — nothing may render a pin
# there, and a match has no restart mapping below, so it bails to the full
# apply instead of leaving a stale copy silently. CONTAINER_SWAP_ROOT
# relocates the roots for bin/check-container-refresh.sh; unset in production.
quadlet_dir="${CONTAINER_SWAP_ROOT:-}/etc/containers/systemd"
script_dir="${CONTAINER_SWAP_ROOT:-}/usr/local/bin"
search_paths=("$quadlet_dir" "$script_dir" "${CONTAINER_SWAP_ROOT:-}/usr/local/sbin")

# Pre-swap content of every file touched. Any exit before the bounce completes
# restores all of it: a swapped quadlet left over an old container would make
# the fallback full apply see nothing to change and never fire the role's
# restart handler, so failure must put the files back — then the fallback's
# template task sees the stale pin and bounces as it always has. The trap is
# disarmed only once every unit is up on its new image.
declare -A orig=()
units=()
revert() {
    # Survive our own failures (set +e): restore every file we can, then start
    # the touched units back on whatever the files now say — the old image is
    # still local — best-effort, so a failed bounce is down for seconds rather
    # than the minutes the full-apply fallback takes to reach its role.
    set +e
    if [ ${#orig[@]} -gt 0 ]; then
        local f
        for f in "${!orig[@]}"; do
            printf '%s\n' "${orig[$f]}" >"$f"
        done
        systemctl daemon-reload
        [ ${#units[@]} -eq 0 ] || systemctl start "${units[@]}"
        echo "reverted ${#orig[@]} file(s) for the full-apply fallback" >&2
    fi
}
trap revert EXIT

while [ $# -ge 2 ]; do
    old=$1
    new=$2
    shift 2
    mapfile -t files < <(grep -rlF -- "$old" "${search_paths[@]}" 2>/dev/null || true)
    [ ${#files[@]} -gt 0 ] || continue
    echo "matched $old"
    # Fixed-string search, then a replacement with only the dots escaped: the
    # gate (container-refresh.sh) admits only digest-pinned refs in the OCI
    # charset, where nothing else is regex- or sed-active with a | delimiter.
    old_re=${old//./\\.}
    for f in "${files[@]}"; do
        [[ -v orig[$f] ]] || orig[$f]=$(<"$f")
        sed -i "s|$old_re|$new|g" "$f"
    done
done

# Nothing matched: this host runs none of the bumped containers.
if [ ${#orig[@]} -eq 0 ]; then
    trap - EXIT
    exit 0
fi

# Map each touched quadlet to its unit for the bounce. A swapped file with no
# restart mapping — a quadlet drop-in, a .pod or .image unit, anything nested,
# an sbin tripwire hit — must not be left in place: exiting makes the trap
# revert it, and the full apply converges it properly, rather than ratifying a
# swapped file whose container never bounced. Assoc-array key order is
# unspecified, so sort just to keep the journal lines stable.
while IFS= read -r f; do
    case $f in
        "$script_dir"/*) continue ;;
        "$quadlet_dir"/*/*) ;; # `*` matches `/`, so nested tests first
        "$quadlet_dir"/*.container)
            unit=${f##*/}
            units+=("${unit%.container}.service")
            continue
            ;;
    esac
    echo "no restart mapping for $f" >&2
    exit 1
done < <(printf '%s\n' "${!orig[@]}" | LC_ALL=C sort)

# One systemd transaction: the units' own Requires=/After= data orders the
# starts, and PartOf propagates the restart to any container sharing a bounced
# owner's netns — exactly as the roles' handlers rely on it.
if [ ${#units[@]} -gt 0 ]; then
    systemctl daemon-reload
    systemctl restart "${units[@]}"
    printf 'refreshed %s\n' "${units[@]}"
fi
trap - EXIT
