#!/usr/bin/env python3
"""Detect which roles a diff affects, expanded via meta/main.yml reverse deps.

Reads BASE_SHA and HEAD_SHA from the environment, runs
`git diff --name-only BASE...HEAD`, and emits a JSON list of affected role
names. Writes `matrix=<json>` to $GITHUB_OUTPUT when set; always prints the
JSON to stdout for local debugging.

Falls back to "all roles" when:
- BASE_SHA or HEAD_SHA is empty or all-zero (e.g. first push to a new branch)
- the git diff fails
- a changed path matches a shared file that every matrix entry depends on
  (the workflow file, shared Molecule scaffolding, dep manifests)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
COLLECTION_ROOT = (
    REPO_ROOT
    / "collections"
    / "ansible_collections"
    / "jedimasterjonny"
    / "lex"
)
ROLES_DIR = COLLECTION_ROOT / "roles"
ROLE_PREFIX = "collections/ansible_collections/jedimasterjonny/lex/roles/"

# Mirrors the `paths:` filter on .github/workflows/molecule.yml — any change
# under these paths invalidates the per-role narrowing and forces every role
# to run.
SHARED_FILES = frozenset(
    {
        ".github/workflows/molecule.yml",
        "requirements.yml",
        "requirements-ci.txt",
    }
)
SHARED_DIR_PREFIXES = (
    "collections/ansible_collections/jedimasterjonny/lex/molecule/shared/",
)


def list_roles() -> list[str]:
    return sorted(p.name for p in ROLES_DIR.iterdir() if p.is_dir())


def role_deps(role: str) -> list[str]:
    """Local role names this role depends on (last segment of FQCN)."""
    meta = ROLES_DIR / role / "meta" / "main.yml"
    if not meta.is_file():
        return []
    data = yaml.safe_load(meta.read_text()) or {}
    deps = data.get("dependencies") or []
    out: list[str] = []
    for dep in deps:
        if isinstance(dep, dict):
            name = dep.get("role") or dep.get("name")
        elif isinstance(dep, str):
            name = dep
        else:
            continue
        if name:
            out.append(name.split(".")[-1])
    return out


def reverse_dep_map(roles: list[str]) -> dict[str, set[str]]:
    """role -> set of roles that depend on it (transitive expansion seed)."""
    rev: dict[str, set[str]] = {r: set() for r in roles}
    for role in roles:
        for dep in role_deps(role):
            rev.setdefault(dep, set()).add(role)
    return rev


def diff_files(base: str, head: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    return [line for line in result.stdout.splitlines() if line]


def is_shared(path: str) -> bool:
    if path in SHARED_FILES:
        return True
    return any(path.startswith(p) for p in SHARED_DIR_PREFIXES)


def directly_changed_roles(changed: list[str], roles: set[str]) -> set[str]:
    hit: set[str] = set()
    for path in changed:
        if not path.startswith(ROLE_PREFIX):
            continue
        name = path[len(ROLE_PREFIX) :].split("/", 1)[0]
        if name in roles:
            hit.add(name)
    return hit


def expand_via_reverse_deps(
    seed: set[str], rev: dict[str, set[str]]
) -> set[str]:
    result = set(seed)
    queue = list(seed)
    while queue:
        role = queue.pop()
        for downstream in rev.get(role, ()):
            if downstream not in result:
                result.add(downstream)
                queue.append(downstream)
    return result


def is_unset(sha: str) -> bool:
    return not sha or set(sha) == {"0"}


def emit(matrix: list[str]) -> None:
    payload = json.dumps(matrix)
    print(payload)
    out_path = os.environ.get("GITHUB_OUTPUT")
    if out_path:
        with open(out_path, "a", encoding="utf-8") as fh:
            fh.write(f"matrix={payload}\n")


def main() -> int:
    base = os.environ.get("BASE_SHA", "")
    head = os.environ.get("HEAD_SHA", "")
    roles = list_roles()

    if is_unset(base) or is_unset(head):
        print(
            f"BASE_SHA/HEAD_SHA unset (base={base!r}, head={head!r}); "
            "running all roles",
            file=sys.stderr,
        )
        emit(roles)
        return 0

    try:
        changed = diff_files(base, head)
    except subprocess.CalledProcessError as exc:
        print(
            f"git diff failed: {exc.stderr.strip()}; running all roles",
            file=sys.stderr,
        )
        emit(roles)
        return 0

    if any(is_shared(p) for p in changed):
        print("Shared path changed; running all roles", file=sys.stderr)
        emit(roles)
        return 0

    role_set = set(roles)
    direct = directly_changed_roles(changed, role_set)
    affected = sorted(expand_via_reverse_deps(direct, reverse_dep_map(roles)))
    emit(affected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
