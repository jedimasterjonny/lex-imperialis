#!/usr/bin/env bash
# Shellcheck the *.sh.j2 templates that `identify` tags as jinja, not shell, so
# the shellcheck hook (types: [shell]) skips them — leaving the riskiest scripts
# (backup, restore, image-refresh) unanalysed. Strip Jinja to valid shell first:
# {% ... %} statements become ':' (a no-op command), {{ ... }} expressions become
# 'X' (a bare word), so shellcheck parses the result and reports real findings. A
# blanket SC1073 suppression would instead make it abandon the file and pass blind.
set -euo pipefail

rc=0
for template in "$@"; do
    if ! sed 's/{%[^}]*%}/:/g; s/{{[^}]*}}/X/g' "$template" | shellcheck -; then
        echo "shellcheck findings in $template" >&2
        rc=1
    fi
done
exit "$rc"
