# bin

Bespoke pre-commit checks (`.pre-commit-config.yaml` local hooks); `make
pre-commit` runs them in the lint CI gate.

## check-role-test-coverage.sh

Enforces the test-coverage contract over `roles/`: every role ships a
`molecule/default` (incus) or `molecule/libvirt` scenario; a `libvirt` scenario
requires a `molecule/hetzner` one (its real-VM CI form); and each role in the
hardcoded Leap-16 subset (`leap_roles`) ships a `molecule/leap` scenario. Exits
non-zero listing every gap; runs on every commit, ignoring filenames.

## shellcheck-jinja.sh

Shellchecks the shell-in-Jinja templates the plain `shellcheck` hook skips —
`identify` tags them jinja, not shell: every `*.sh.j2`, plus the
extensionless-bash `wp`/`wp-db-dump` templates. Rewrites Jinja to valid shell
first (`{% … %}` → `:`, `{{ … }}` → `X`), then pipes the result through
shellcheck.
