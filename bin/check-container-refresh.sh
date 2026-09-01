#!/usr/bin/env bash
# Fixture tests for arbites' container fast path: the range gate
# (bin/container-refresh.sh) and the per-host swap payload
# (bin/container-swap.sh). Both test hermetically — a scratch git repo with
# the real gate script copied in and ansible-playbook stubbed on PATH; a
# scratch filesystem root (CONTAINER_SWAP_ROOT) with systemctl stubbed — so
# every accept, reject, swap, bounce and revert class is asserted. This exists
# because the fast path fails closed: a regression would not break anything
# visibly, every range would just take the correct, slow full apply forever.
# Backs the container-refresh-gate hook.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
src=$PWD/bin/container-refresh.sh
swap=$PWD/bin/container-swap.sh

# The gate mirrors renovate.json's image-manager shapes; pin both managers
# exactly — file patterns and the template pin_re transcribes — so reshaping
# either fails this hook instead of silently disabling the fast path.
if ! jq -e '
        (.customManagers | map(select(
            .autoReplaceStringTemplate ==
                "image: {{{depName}}}:{{{newValue}}}{{#if newDigest}}@{{{newDigest}}}{{/if}}"
            and .managerFilePatterns == ["/^roles/.+/vars/main\\.yml$/"]))
            | length) == 1
        and (.customManagers | map(select(
            .managerFilePatterns == ["/^docs/disaster-recovery\\.md$/"]))
            | length) == 1' \
    renovate.json >/dev/null; then
    echo "renovate.json's image-manager shapes moved:" \
        "update bin/container-refresh.sh's gate and this pin together" >&2
    exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# The stub records its argv, so the accept cases can assert the handed-on pairs.
mkdir "$scratch/stub"
cat >"$scratch/stub/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_LOG:?}"
EOF
chmod +x "$scratch/stub/ansible-playbook"
export PATH="$scratch/stub:$PATH" STUB_LOG="$scratch/argv"

repo=$scratch/repo
renovate='renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>'
git init -q -b main "$repo"
mkdir -p "$repo/bin" "$repo/roles/demo/vars" "$repo/docs"
cp "$src" "$repo/bin/"

pin() { printf 'demo_image: %s\n' "$1" >"$repo/roles/demo/vars/main.yml"; }
commit() { # $1: message; $2: author (defaults to renovate)
    git -C "$repo" add -A
    git -C "$repo" -c user.name=fixture -c user.email=fixture@invalid \
        commit -qm "$1" --author "${2:-$renovate}"
}
sha() { git -C "$repo" rev-parse "$1"; }

ref_a="docker.io/library/demo:1.0@sha256:$(printf 'a%.0s' {1..64})"
ref_b="docker.io/library/demo:1.1@sha256:$(printf 'b%.0s' {1..64})"
ref_c="docker.io/library/demo:1.2@sha256:$(printf 'c%.0s' {1..64})"
ref_other="docker.io/library/other:1.0@sha256:$(printf 'd%.0s' {1..64})"

fail=0
t() { # $1: description; $2: accept|reject; $3/$4: base/target (default HEAD^/HEAD)
    rm -f "$STUB_LOG"
    local rc=0 bad=0
    "$repo/bin/container-refresh.sh" "${3:-$(sha 'HEAD^')}" "${4:-$(sha HEAD)}" \
        >/dev/null 2>&1 || rc=$?
    if [ "$2" = accept ]; then
        { [ "$rc" -eq 0 ] && [ -e "$STUB_LOG" ]; } || bad=1
    else
        { [ "$rc" -ne 0 ] && [ ! -e "$STUB_LOG" ]; } || bad=1
    fi
    if [ "$bad" -ne 0 ]; then
        echo "FAIL ($2 expected, rc=$rc): $1" >&2
        fail=1
    fi
}

pin "$ref_a"
commit seed

# The one accepted shape: a renovate-authored digest bump, pins handed through.
pin "$ref_b"
commit 'bump a->b'
t 'digest bump by renovate' accept
if ! grep -qF "\"old\":\"$ref_a\"" "$STUB_LOG" \
    || ! grep -qF "\"new\":\"$ref_b\"" "$STUB_LOG"; then
    echo 'FAIL: accepted bump did not hand the pair on in old->new order' >&2
    fail=1
fi

# The arr-style nested-mapping pin — the repo's highest-volume renovate
# traffic — must be accepted too: pin_re's key match is indentation-agnostic.
printf 'demo_apps:\n  radarr:\n    image: %s\n' "$ref_a" \
    >"$repo/roles/demo/vars/main.yml"
commit 'restore to the nested shape'
printf 'demo_apps:\n  radarr:\n    image: %s\n' "$ref_b" \
    >"$repo/roles/demo/vars/main.yml"
commit 'nested bump'
t 'nested dict image bump' accept

# Two roles pinning the same image bump identically in one PR; the duplicate
# pair collapses to a no-op second swap, not a rejection.
printf 'demo_image: %s\ndemo2_image: %s\n' "$ref_a" "$ref_a" \
    >"$repo/roles/demo/vars/main.yml"
commit 'restore before duplicate case'
printf 'demo_image: %s\ndemo2_image: %s\n' "$ref_b" "$ref_b" \
    >"$repo/roles/demo/vars/main.yml"
commit 'duplicate bumps'
t 'two pins of the same image' accept

# The runbook renovate co-bumps rides along; any other extra file rejects.
pin "$ref_b"
commit 'restore before rider case'
pin "$ref_c"
echo "$ref_c" >"$repo/docs/disaster-recovery.md"
commit 'bump with runbook rider'
t 'disaster-recovery.md rider' accept

pin "$ref_a"
echo stray >"$repo/README.md"
commit 'bump plus stray file'
t 'range touching another file' reject

pin "$ref_b"
commit 'bump by a human' 'Operator <operator@invalid>'
t 'non-renovate author' reject

pin 'docker.io/library/demo:2.0'
commit 'digestless bump'
t 'pin without a digest' reject

pin "$ref_a"
commit 'restore before tag case'
pin "docker.io/library/demo@sha256:$(printf 'e%.0s' {1..64})"
commit 'tagless bump'
t 'pin without a tag' reject

pin "$ref_a"
commit 'restore before key case'
printf 'renamed_image: %s\n' "$ref_c" >"$repo/roles/demo/vars/main.yml"
commit 'key renamed'
t 'pin key change' reject

pin "$ref_a"
commit 'restore before repository case'
pin "$ref_other"
commit 'repository moved'
t 'cross-repository move' reject

printf 'demo_image: %s\ndemo2_image: %s\n' "$ref_a" "$ref_b" \
    >"$repo/roles/demo/vars/main.yml"
commit 'restore before independence case'
printf 'demo_image: %s\ndemo2_image: %s\n' "$ref_b" "$ref_c" \
    >"$repo/roles/demo/vars/main.yml"
commit 'chained bumps'
t 'pins that are not independent' reject

t 'unknown base SHA' reject "$(printf '0%.0s' {1..40})" "$(sha HEAD)"

# --- container-swap.sh: swap, bounce, revert -------------------------------
# CONTAINER_SWAP_ROOT relocates the script's swept roots into the scratch dir,
# and a PATH stub records every systemctl call (SYSTEMCTL_FAIL=<verb> makes
# that verb fail, to drive the revert path).
export CONTAINER_SWAP_ROOT="$scratch/swaproot" SYSTEMCTL_LOG="$scratch/systemctl.log"
cat >"$scratch/stub/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
[ "${SYSTEMCTL_FAIL:-}" != "$1" ] || exit 1
EOF
chmod +x "$scratch/stub/systemctl"

quadlet=$CONTAINER_SWAP_ROOT/etc/containers/systemd/demo.container
wrapper=$CONTAINER_SWAP_ROOT/usr/local/bin/wrapper
reset_swap_root() {
    rm -rf "$CONTAINER_SWAP_ROOT"
    mkdir -p "${quadlet%/*}" "${wrapper%/*}" "$CONTAINER_SWAP_ROOT/usr/local/sbin"
    printf 'Image=%s\n' "$ref_a" >"$quadlet"
    printf 'exec podman run %s wp\n' "$ref_a" >"$wrapper"
    : >"$SYSTEMCTL_LOG"
}
carries() { grep -qF "$2" "$1"; }

reset_swap_root
if ! out=$("$swap" "$ref_other" "$ref_b" 2>&1) || [ -n "$out" ] \
    || ! carries "$quadlet" "$ref_a" || [ -s "$SYSTEMCTL_LOG" ]; then
    echo 'FAIL: a host carrying none of the bumps must be a silent no-op' >&2
    fail=1
fi

reset_swap_root
if ! out=$("$swap" "$ref_a" "$ref_b" 2>&1) \
    || ! carries "$quadlet" "$ref_b" || ! carries "$wrapper" "$ref_b" \
    || ! carries "$SYSTEMCTL_LOG" 'daemon-reload' \
    || ! carries "$SYSTEMCTL_LOG" 'restart demo.service' \
    || ! grep -qF "matched $ref_a" <<<"$out" \
    || ! grep -qF 'refreshed demo.service' <<<"$out"; then
    echo 'FAIL: a carried bump must swap both renders and bounce the unit' >&2
    fail=1
fi

reset_swap_root
if SYSTEMCTL_FAIL=restart "$swap" "$ref_a" "$ref_b" >/dev/null 2>&1 \
    || ! carries "$quadlet" "$ref_a" || ! carries "$wrapper" "$ref_a" \
    || ! carries "$SYSTEMCTL_LOG" 'start demo.service'; then
    echo 'FAIL: a failed restart must restore every file and start the unit back' >&2
    fail=1
fi

reset_swap_root
dropin=$CONTAINER_SWAP_ROOT/etc/containers/systemd/demo.container.d/override.conf
mkdir -p "${dropin%/*}"
printf 'Image=%s\n' "$ref_a" >"$dropin"
if "$swap" "$ref_a" "$ref_b" >/dev/null 2>&1 || ! carries "$dropin" "$ref_a"; then
    echo 'FAIL: a file with no restart mapping must fail and be reverted' >&2
    fail=1
fi

if "$swap" onlyone >/dev/null 2>&1; then
    echo 'FAIL: odd arguments must be a usage error' >&2
    fail=1
fi

exit "$fail"
