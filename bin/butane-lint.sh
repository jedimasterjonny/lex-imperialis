#!/usr/bin/env bash
# Validate Butane configs. --strict promotes warnings to errors, --check drops
# the compiled output: the real artefact is generated at provision time so there
# is one source of truth.
#
# One file per invocation, because butane takes a single input and exits 2 on a
# batch.
set -euo pipefail

rc=0
for config in "$@"; do
    if ! butane --strict --check "$config"; then
        echo "butane findings in $config" >&2
        rc=1
    fi
done
exit "$rc"
