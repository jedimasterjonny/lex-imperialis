#!/usr/bin/env bash
# arbites's container fast path: decide whether the newly fetched range is
# nothing but renovate image bumps and, when it is, apply them by swapping the
# pinned refs on each host (playbooks/container-refresh.yml) instead of
# re-converging the whole fleet — the bulk of merges are these bumps, and a
# swap-and-bounce costs seconds where the full apply costs minutes.
#
# Exits 0 only when every bump is applied. Any other outcome — a range that is
# more than image bumps, a bump no host carries, a failed swap or restart —
# exits non-zero with the reason in the journal, and the caller (arbites.sh)
# runs bin/fleet-apply.sh, the known-correct path. The gate is deliberately
# strict: every commit in the range authored by renovate[bot], only
# roles/*/vars/main.yml touched (plus the runbook pin renovate co-bumps),
# every changed line a digest-pinned image ref whose key and indentation are
# unchanged and whose old and new refs name the same repository. Anything else
# is someone else's change, and gets the full apply.
#
# Usage: container-refresh.sh <last-applied-sha> <target-sha>
#                             [ansible-playbook args...]
# Needs ansible-playbook on PATH (the reconciler's venv) and runs from the
# repo root, so ansible picks up ansible.cfg exactly as fleet-apply.sh does.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ $# -lt 2 ]; then
    echo "usage: $0 <last-applied-sha> <target-sha> [ansible-playbook args...]" >&2
    exit 64
fi
last=$1
target=$2
shift 2

# Without a diffable base there is no safe fast path (a first run, or a
# history rewrite that dropped the recorded SHA).
if ! git cat-file -e "$last^{commit}" 2>/dev/null; then
    echo "container-refresh: last-applied $last is not a known commit"
    exit 1
fi

# Every commit in the range must be renovate's own — the fast path trusts the
# range to be machine-authored bumps and nothing else, merge commits included.
authors=$(git log --format=%ae "$last..$target")
if [ -z "$authors" ] || grep -qv 'renovate\[bot\]' <<<"$authors"; then
    echo "container-refresh: range $last..$target is not all renovate-authored"
    exit 1
fi

# Only the files renovate's image managers write — renovate.json owns these
# shapes; keep them in step. docs/disaster-recovery.md rides along untouched:
# renovate bumps the mariadb pin it hardcodes in the same PR as the wordpress
# vars (same depName), and the runbook renders nowhere on a host, so its half
# of the bump needs no applying.
# Two steps, not a `git | grep -q` pipeline: -q closing the pipe early can
# kill git with SIGPIPE, and under pipefail that 141 would read as "nothing
# disallowed" — and the || grep needs to forgive is grep's no-match rc 1, not
# a git failure, which must abort rather than read as an empty range.
changed_files=$(git diff --name-only "$last" "$target")
disallowed=$(grep -vE '^(roles/[^/]+/vars/main\.yml|docs/disaster-recovery\.md)$' \
    <<<"$changed_files" || true)
if [ -n "$disallowed" ]; then
    echo "container-refresh: range touches more than renovate's image pins"
    exit 1
fi

# Every changed line must be an image pin — `<key>: <ref>` with the key
# `image` or `*_image` — and each removed line must pair, in order, with an
# added line whose indentation and key are identical and whose ref names the
# same repository: the value is the only thing the fast path will move. The
# ref charset is the OCI one and both a tag and a digest are required — which
# is what renovate's template always writes. That makes the refs safe to hand
# to container-swap.sh's root sed on every host (nothing in them is
# sed-active, and the 64-hex tail means no rendered ref can extend another,
# so the substring match can never rewrite a near-miss) and makes stripping
# the tag in repo_of unambiguous even for a port-qualified registry.
pin_re='^([+-])([[:space:]]*[a-z0-9_]*image):[[:space:]]+([A-Za-z0-9._/:-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64})$'
removed_keys=()
removed_refs=()
added_keys=()
added_refs=()
while IFS= read -r line; do
    if [[ ! $line =~ $pin_re ]]; then
        echo "container-refresh: not an image pin: $line"
        exit 1
    fi
    if [ "${BASH_REMATCH[1]}" = '-' ]; then
        removed_keys+=("${BASH_REMATCH[2]}")
        removed_refs+=("${BASH_REMATCH[3]}")
    else
        added_keys+=("${BASH_REMATCH[2]}")
        added_refs+=("${BASH_REMATCH[3]}")
    fi
done < <(git diff --unified=0 "$last" "$target" -- 'roles/*/vars/main.yml' \
    | grep -E '^[+-]' | grep -vE '^(--- |\+\+\+ )')

if [ ${#removed_refs[@]} -eq 0 ] || [ ${#removed_refs[@]} -ne ${#added_refs[@]} ]; then
    echo "container-refresh: removed and added pins do not pair up"
    exit 1
fi

# repository = the ref with any digest, then any tag, stripped.
repo_of() {
    local ref=${1%%@*}
    printf '%s' "${ref%:*}"
}

pairs=()
for i in "${!removed_refs[@]}"; do
    old=${removed_refs[i]}
    new=${added_refs[i]}
    if [ "${removed_keys[i]}" != "${added_keys[i]}" ] \
        || [ "$(repo_of "$old")" != "$(repo_of "$new")" ] || [ "$old" = "$new" ]; then
        echo "container-refresh: ${removed_keys[i]}: $old -> $new is not a plain bump"
        exit 1
    fi
    echo "container-refresh: bump $old -> $new"
    pairs+=("$old" "$new")
done

# Pairs must be independent: the swap applies them in sequence against the
# live tree, so a pair whose old ref is another pair's new ref would rewrite
# the pin it just wrote, and one old ref moving to two different new refs is
# unorderable. Identical duplicates (two roles pinning the same image, bumped
# in one PR) are fine — the second swap is a no-op.
for i in "${!removed_refs[@]}"; do
    for j in "${!removed_refs[@]}"; do
        [ "$i" -ne "$j" ] || continue
        if { [ "${removed_refs[i]}" = "${removed_refs[j]}" ] \
            && [ "${added_refs[i]}" != "${added_refs[j]}" ]; } \
            || [ "${removed_refs[i]}" = "${added_refs[j]}" ]; then
            echo "container-refresh: pins are not independent: ${removed_refs[i]}"
            exit 1
        fi
    done
done

updates=$(jq -cn \
    '$ARGS.positional
     | [range(0; length; 2) as $i | {old: .[$i], new: .[$i + 1]}]
     | {container_refresh_updates: .}' \
    --args "${pairs[@]}")
ansible-playbook "$@" --extra-vars "$updates" playbooks/container-refresh.yml
