#!/usr/bin/env bash
# Lint the content a commit touches, and drop the duplicate-collection noise.
#
# ansible-lint's cost is one `ansible-playbook --syntax-check` subprocess per
# role, playbook and molecule scenario file — 122 of them, ~107s, and the hook
# paid all of it on every commit whatever the diff held. Mapping the changed
# paths onto their lint targets makes a one-role commit ~6s. pre-commit passes
# every tracked YAML under --all-files, so `make lint` and CI still cover the
# repo; what scoping gives up is a cross-file break the diff does not name — a
# role deleted without the play that runs it being edited in the same commit.
#
# Paths under inventory/ and bootstrap/ map to the directory, not the file:
# ansible-lint applies .ansible-lint's exclude_paths while walking a directory
# but lints an excluded file handed to it by name, and both exclusions live
# there.
#
# Reads changed paths as arguments; no arguments lints the whole repo.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

targets=()
for path in "$@"; do
    case "$path" in
        # These decide how every other file lints, so nothing narrower is sound.
        .ansible-lint | ansible.cfg | requirements.txt | requirements-dev.txt)
            targets=()
            break
            ;;
        roles/*/*)
            rest="${path#roles/}"
            targets+=("roles/${rest%%/*}")
            ;;
        molecule/*/*)
            rest="${path#molecule/}"
            targets+=("molecule/${rest%%/*}")
            ;;
        inventory/*) targets+=(inventory) ;;
        bootstrap/*) targets+=(bootstrap) ;;
        *) targets+=("$path") ;;
    esac
done

if [ "${#targets[@]}" -gt 0 ]; then
    mapfile -t targets < <(printf '%s\n' "${targets[@]}" | sort -u)
fi

# stderr is held back so the collection noise can be dropped from it; findings
# go to stdout and still stream. ansible-lint renders no progress UI, so there
# is nothing live to lose.
stderr_log="$(mktemp)"
trap 'rm -f "$stderr_log"' EXIT

status=0
ansible-lint --strict ${targets[@]+"${targets[@]}"} 2>"$stderr_log" || status=$?

# A venv's lib64 -> lib symlink puts the bundled collections on two sys.path
# roots, so ansible-core reports all 91 of them as duplicates on every run: 92
# lines of noise ahead of anything real. Every other warning still surfaces.
grep -vF 'only the first one will be used' "$stderr_log" >&2 || true

exit "$status"
