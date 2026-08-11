#!/usr/bin/env bash
# Expand a set of changed roles to the set molecule must actually test.
#
# Two roles are engines rather than plays' roles: restic_backup is consumed by
# home_backup and podman_backup, stow by common and dev. An engine's own scenario
# tests the engine, so a PR touching only restic_backup runs green while its two
# consumers — whose scenarios assert the units, timers and metrics the engine
# renders for them — are never converged. arbites then applies main to the fleet as
# root within ~15 min. Renaming one of the engine's variables is enough.
#
# Reads role names on stdin, one per line; writes the closure, sorted and unique.
# Empty in, empty out — the workflow calls this before it knows whether the diff
# touched any role at all.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The edge list is derived, not kept here: a second copy of the role graph is the
# thing that goes stale, and its going stale is silent in exactly the way this
# script exists to stop. `name:` is the key on the line after the module in every
# include_role in the tree; awk aborts rather than skipping if that ever stops
# holding, so a shape this cannot read fails the run instead of quietly narrowing
# the matrix.
edges() {
    awk '
        function consumer(path,   parts, n) {
            n = split(path, parts, "/")   # .../roles/<consumer>/tasks/<file>.yml
            return parts[n - 2]
        }
        /include_role:/ { pending = 1; next }
        pending {
            if ($1 != "name:") {
                printf "ERROR: %s: include_role is not followed by name:, so the " \
                       "role graph cannot be read\n", FILENAME > "/dev/stderr"
                exit 1
            }
            print consumer(FILENAME), $2
            pending = 0
        }
    ' "$repo"/roles/*/tasks/*.yml
}

graph="$(edges)"

# Blank lines dropped here rather than downstream: the caller builds its list with
# printf on a possibly-empty variable, so an empty line is the normal shape of "no
# roles changed" and must not survive into the matrix as a nameless entry.
roles="$(grep -v '^[[:space:]]*$' || true)"
[ -n "$roles" ] || exit 0
roles="$(printf '%s\n' "$roles" | sort -u)"

# Fixed point rather than one pass. Today every consumer is a leaf, so one pass
# would do; a consumer that is itself included would otherwise be the same silent
# miss, one link further out.
while :; do
    grown="$(
        {
            printf '%s\n' "$roles"
            # Consumers of anything already in the set.
            join -1 2 -o 1.1 <(printf '%s\n' "$graph" | sort -k2,2) <(printf '%s\n' "$roles")
        } | sort -u
    )"
    [ "$grown" = "$roles" ] && break
    roles="$grown"
done

printf '%s\n' "$roles"
