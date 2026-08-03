#!/usr/bin/env bash
set -euo pipefail

# Bounded per store, so one prune wedged on a held store lock is killed and
# reported rather than eating the whole run's TimeoutStartSec budget. stdin from
# /dev/null because --pipe would otherwise hand the child the caller's own stdin,
# and anything reading it would swallow the rest of the loop.
prune() {
  systemd-run --quiet --wait --pipe --collect --property=RuntimeMaxSec=5m "$@" \
    /usr/bin/podman image prune --all --force </dev/null
}

# Stores are independent, so one failure must not skip the rest — including
# root's. Full rationale in the role's README.
rc=0
prune || rc=1

# Iterate passwd, not a /home/* glob: podman resolves the store from the $HOME
# the PAM session sets out of the passwd entry. Captured so a partial
# enumeration aborts under set -e rather than silently shortening the loop.
users=$(getent passwd)

while IFS=: read -r user _ uid _ _ home _; do
  [ "$uid" -ne 0 ] || continue # pruned above, and uid 0 resolves to that store
  [ -d "$home/.local/share/containers" ] || continue

  # Named before the attempt, so the journal records which stores the run
  # actually reached — the enumeration above is otherwise invisible, and a prune
  # silently covering the wrong set is what this whole script exists to fix.
  echo "podman-image-prune: ${user}"
  prune --uid="$uid" --property=PAMName=login || {
    echo "podman-image-prune: skipped ${user}, rootless podman unusable" >&2
    rc=1
  }
done <<<"$users"

exit "$rc"
