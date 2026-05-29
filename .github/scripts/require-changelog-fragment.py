#!/usr/bin/env python3
"""Fail a PR that changes user-visible collection content without a fragment.

Reads BASE_SHA and HEAD_SHA from the environment, runs
`git diff --name-only BASE...HEAD`, and exits 1 when the PR touches files that
ship to consumers of jedimasterjonny.lex without adding or updating a changelog
fragment under changelogs/fragments/.

The gate PASSES (exit 0) when any of these hold:
- No user-visible collection content changed. Dev tooling, the top-level
  playbooks/inventory/bootstrap, the molecule scaffolding (shared and
  per-role), and the changelog machinery itself are all out of scope — none of
  them ship to consumers.
- The PR is a release: it regenerates changelogs/changelog.yaml *and* bumps
  galaxy.yml's version in the same commit. The release flow consumes fragments
  (keep_fragments: false), so it removes them rather than adding one. Both files
  are required so a stray hand-edit of changelog.yaml can't masquerade as one.
- A fragment under changelogs/fragments/ was added or modified.

Fails OPEN (exit 0) when the SHAs are unset/all-zero or the git diff errors —
this is a discipline backstop, not a security control, so an infra hiccup must
not wedge every PR.

Run locally with BASE_SHA/HEAD_SHA set, e.g.:
    BASE_SHA=main HEAD_SHA=HEAD python3 .github/scripts/require-changelog-fragment.py
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
COLLECTION_ROOT = "collections/ansible_collections/jedimasterjonny/lex/"
FRAGMENTS_PREFIX = COLLECTION_ROOT + "changelogs/fragments/"
CHANGELOG_YAML = COLLECTION_ROOT + "changelogs/changelog.yaml"
GALAXY_YAML = COLLECTION_ROOT + "galaxy.yml"
FRAGMENT_SUFFIXES = (".yml", ".yaml")


def collection_rel(path: str) -> str | None:
    """Path relative to the collection root, or None if outside it."""
    if path.startswith(COLLECTION_ROOT):
        return path[len(COLLECTION_ROOT):]
    return None


def is_user_visible(rel: str) -> bool:
    """Does this collection-relative path ship to consumers?

    Mirrors the feat:-family definition in CLAUDE.md and the changelog-fragments
    skill scope: roles, plugins, collection playbooks, galaxy.yml,
    meta/runtime.yml, and the collection README/LICENSE ship. The molecule
    scaffolding (shared and per-role), the changelogs/ machinery, and the
    generated CHANGELOG.md do not.
    """
    parts = rel.split("/")
    head = parts[0]

    # Test-only scaffolding and the changelog machinery never ship. The
    # generated CHANGELOG.md sits at the collection root, so exclude it by name.
    if head in ("changelogs", "molecule") or rel == "CHANGELOG.md":
        return False
    # roles/<name>/** ships, except roles/<name>/molecule/** (per-role test
    # scaffolding, dropped from the build via build_ignore).
    if head == "roles":
        return not (len(parts) >= 3 and parts[2] == "molecule")
    if head in ("plugins", "playbooks"):
        return True
    # Collection-level shipped files.
    return rel in ("galaxy.yml", "meta/runtime.yml", "README.md", "LICENSE")


def is_fragment(path: str) -> bool:
    return path.startswith(FRAGMENTS_PREFIX) and path.endswith(FRAGMENT_SUFFIXES)


def evaluate(changed: list[str], added_modified: list[str]) -> tuple[bool, str]:
    """Decide the gate from the changed and added/modified path lists.

    Pure function (no git / no env) so it is trivially unit-testable.
    """
    user_visible = [
        p for p in changed
        if (rel := collection_rel(p)) is not None and is_user_visible(rel)
    ]

    if not user_visible:
        return True, "No user-visible collection content changed; fragment not required."

    # A real release regenerates changelog.yaml AND bumps galaxy.yml's version
    # in the same commit (the pr-finalisation flow). Requiring both rules out a
    # PR that merely hand-edits changelog.yaml while shipping an unrelated
    # user-visible change without a fragment.
    if CHANGELOG_YAML in changed and GALAXY_YAML in changed:
        return True, (
            "Release PR (changelogs/changelog.yaml regenerated and galaxy.yml "
            "bumped); the release flow consumes fragments rather than adding one."
        )

    fragments = [p for p in added_modified if is_fragment(p)]
    if fragments:
        return True, "Changelog fragment present:\n" + "\n".join(
            f"  - {p}" for p in fragments
        )

    listing = "\n".join(f"  - {p}" for p in user_visible)
    return False, (
        "Missing changelog fragment.\n\n"
        "This PR changes user-visible collection content:\n"
        f"{listing}\n\n"
        f"Add a fragment under {FRAGMENTS_PREFIX} describing the change "
        "(see the\nchangelog-fragments skill / CLAUDE.md). For a genuinely "
        "non-user-facing\nedit, a `trivial:` fragment satisfies this gate."
    )


def diff_files(base: str, head: str, *, diff_filter: str | None = None) -> list[str]:
    cmd = ["git", "diff", "--name-only"]
    if diff_filter:
        cmd.append(f"--diff-filter={diff_filter}")
    cmd.append(f"{base}...{head}")
    result = subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    return [line for line in result.stdout.splitlines() if line]


def is_unset(sha: str) -> bool:
    return not sha or set(sha) == {"0"}


def main() -> int:
    base = os.environ.get("BASE_SHA", "")
    head = os.environ.get("HEAD_SHA", "")

    if is_unset(base) or is_unset(head):
        print(
            f"BASE_SHA/HEAD_SHA unset (base={base!r}, head={head!r}); "
            "skipping changelog-fragment gate.",
            file=sys.stderr,
        )
        return 0

    try:
        changed = diff_files(base, head)
        # Renames surface their destination path under --name-only, so AMR
        # catches a fragment added, edited, or moved into place.
        added_modified = diff_files(base, head, diff_filter="AMR")
    except subprocess.CalledProcessError as exc:
        print(
            f"git diff failed: {exc.stderr.strip()}; "
            "skipping changelog-fragment gate.",
            file=sys.stderr,
        )
        return 0

    ok, reason = evaluate(changed, added_modified)
    print(reason, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
