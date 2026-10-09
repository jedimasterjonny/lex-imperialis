#!/usr/bin/env bash
# Validate the OpenTofu config offline. init -backend=false skips the GCS state
# backend, so no cloud credentials are needed — the check runs in CI and
# pre-commit. -lockfile=readonly checks the committed lock instead of rewriting
# it: Renovate takes cloudflare's hashes from the registry's package list, which
# omits the manifest.json line init reads from SHA256SUMS, so a writing init
# failed every cloudflare bump. A provider missing from the lock, or locked
# outside its constraint, still fails. stdout is dropped; errors still surface
# on stderr and fail the run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
tofu init -backend=false -input=false -lockfile=readonly >/dev/null
tofu validate
