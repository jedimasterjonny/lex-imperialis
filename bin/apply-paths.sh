#!/usr/bin/env bash
# Print the paths changed between two commits that a fleet apply may read —
# the diff minus the paths no play, nor arbites itself, ever reads. arbites
# records a range that prints nothing without applying it, and the container
# fast path lets those paths ride beside its bumps. Exits non-zero when git
# cannot diff the two (an unknown or empty SHA).
#
# Usage: apply-paths.sh <base-sha> <target-sha>
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# CI, agent skills, the other deploy targets, the test harness, the hook
# toolchain and prose. Everything else — roles bar their READMEs and scenarios, playbooks,
# inventory, ansible.cfg, requirements.txt, bin/ — an apply reads.
inert='^(\.github/|\.claude/|terraform/|jonnyoc-site/|packer/|docs/|molecule/|roles/[^/]+/molecule/|roles/[^/]+/README\.md$|[^/]+\.md$|requirements-dev\.txt$|\.pre-commit-config\.yaml$|renovate\.json$)'

# --no-renames: a rename lists only its new path, so a role file moved under
# docs/ would read as inert. Two steps for the reason container-refresh.sh gives.
changed=$(git diff --no-renames --name-only "$1" "$2")
grep -vE "$inert" <<<"$changed" || true
