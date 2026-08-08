#!/usr/bin/env python3
"""Parse the Jinja templates pre-commit hands over, so a syntax error fails here
rather than at converge.

The failure this catches is cheap to make and expensive to find: a bare `{#`
outside a `{% raw %}` fence opens a Jinja comment that never closes, and bash's
`${#array[@]}` is the usual source. Ansible then aborts while templating, so the
error surfaces only when a play or a molecule converge reaches that task — a full
container build in CI — and `arbites` applies as root within ~15 min of a
merge. shellcheck-jinja cannot see it: it rewrites `{% %}` and `{{ }}` but not
comment tags.

Parsing builds the AST and stops: variables are never resolved and filters never
looked up, so an Ansible-only filter is not a false positive. Ansible's
AnsibleEnvironment loads no Jinja extensions and keeps the stock delimiters
(measured against ansible-core), so a stock environment accepts exactly the tag
vocabulary Ansible does.
"""

import sys

from jinja2 import Environment, TemplateSyntaxError


def main(paths):
    env = Environment()
    status = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as template:
                env.parse(template.read(), filename=path)
        except TemplateSyntaxError as error:
            print(f"{path}:{error.lineno}: {error.message}", file=sys.stderr)
            status = 1
        except OSError as error:
            print(f"{path}: {error.strerror}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
