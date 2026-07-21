#!/usr/bin/env bash
# Validate the OpenTofu config offline. init -backend=false skips the GCS state
# backend, so no cloud credentials are needed — the check runs in CI and
# pre-commit. stdout is dropped; errors still surface on stderr and fail the run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
tofu init -backend=false -input=false >/dev/null
tofu validate
