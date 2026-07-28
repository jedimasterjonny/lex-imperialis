#!/usr/bin/env python3
"""Fail when a renovate custom manager reaches nothing, or a pinned digest sits
outside every manager's reach.

`renovate-config-validator` exits 0 on a manager whose file patterns match no file,
so a manager killed by a moved path is otherwise invisible — its pins just stop
being offered. bin/README.md has the rest, including why check 3 scores the
currentDigest capture rather than the file or the match span.
"""

import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CONFIG = "renovate.json"

# `@` because only a digest attached to a ref is one renovate can bump; the span
# starts after it, where a currentDigest group starts. Case-insensitive hex to
# match renovate's own isDockerDigest.
DIGEST = re.compile(r"(?<=@)sha256:[0-9a-fA-F]{64}")

# A currentDigest that swallowed a closing quote or stopped short matched the text
# without yielding anything renovate can look up.
WELL_FORMED = re.compile(r"\Asha256:[0-9a-fA-F]{64}\Z")


def tracked_files():
    """Every tracked path, so an untracked scratch file is never a finding."""
    listing = subprocess.run(
        ["git", "ls-files", "-z"], cwd=REPO, capture_output=True, check=True
    ).stdout
    return [path for path in os.fsdecode(listing).split("\0") if path]


def read_text(path):
    """None for anything that is not decodable text — binaries hold no pins."""
    try:
        return (REPO / path).read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def file_pattern(entry):
    """None for anything but a plain `/…/`. Renovate also takes `/…/i`, a negated
    `!/…/` and globs, and guessing wrong on those goes both ways — a glob read as a
    regex matches the wrong set silently, and a negated filter matching zero files
    is normal, so scoring it as positive would fail loudly and wrongly."""
    if len(entry) > 1 and entry.startswith("/") and entry.endswith("/"):
        return re.compile(entry[1:-1])
    return None


def match_string(entry):
    """JS names a group `(?<x>)`, Python `(?P<x>)`; `(?<=` and `(?<!` are lookbehind
    in both and must survive. re.ASCII because renovate compiles these under RE2
    with the `g` flag alone, where `\\d` and `\\s` are ASCII and Python's are not —
    the difference draws spans at different boundaries. Python's `$` still matches
    before a trailing newline where RE2's does not; no manager anchors."""
    return re.compile(re.sub(r"\(\?<(?![=!])", "(?P<", entry), re.ASCII)


def main():
    config = json.loads((REPO / CONFIG).read_text(encoding="utf-8"))
    managers = config.get("customManagers", [])
    if not managers:
        print(f"{CONFIG}: no customManagers to check", file=sys.stderr)
        return 1

    paths = tracked_files()
    contents = {path: text for path in paths if (text := read_text(path)) is not None}

    errors = []
    spans = {}

    for index, manager in enumerate(managers):
        label = f"customManagers[{index}]"

        # A jsonata manager's matchStrings are queries, not regexes, and a
        # non-"any" strategy changes what a match means at all. Refuse rather than
        # score them under rules that do not apply.
        custom_type = manager.get("customType")
        strategy = manager.get("matchStringsStrategy", "any")
        if custom_type != "regex" or strategy != "any":
            errors.append(
                f"{CONFIG}: {label} is customType={custom_type!r} "
                f"matchStringsStrategy={strategy!r}; only regex/any is understood here"
            )
            continue

        covered = set()
        dead_pattern = False
        for entry in manager.get("managerFilePatterns", []):
            pattern = file_pattern(entry)
            if pattern is None:
                errors.append(
                    f"{CONFIG}: {label} managerFilePatterns {entry} is not the plain "
                    "/regex/ form — flags, negation and globs are refused deliberately"
                )
                dead_pattern = True
                continue
            hits = [path for path in paths if pattern.search(path)]
            if not hits:
                errors.append(
                    f"{CONFIG}: {label} managerFilePatterns {entry} matches no tracked file"
                )
                dead_pattern = True
            covered.update(hits)

        # Strategy "any" makes matchStrings alternatives, so one of several
        # matching nothing is legitimate; the manager as a whole is not. Only a
        # currentDigest group counts as digest coverage — any other group
        # overlapping a digest means renovate read it as part of a name or a
        # version, which is the unreachable case check 3 exists to catch.
        total = 0
        searched = sorted(covered & contents.keys())
        for entry in manager.get("matchStrings", []):
            pattern = match_string(entry)
            digest_group = "currentDigest" in pattern.groupindex
            for path in searched:
                for found in pattern.finditer(contents[path]):
                    total += 1
                    if not digest_group:
                        continue
                    start, end = found.span("currentDigest")
                    if start != -1 and WELL_FORMED.match(found["currentDigest"]):
                        spans.setdefault(path, []).append((start, end))
        # A dead pattern already reported cannot also be news here.
        if total == 0 and not dead_pattern:
            errors.append(
                f"{CONFIG}: {label} matchStrings match nothing across its "
                f"{len(searched)} matched file(s)"
            )

    for path in sorted(contents):
        text = contents[path]
        for found in DIGEST.finditer(text):
            if any(
                start <= found.start() and found.end() <= end
                for start, end in spans.get(path, [])
            ):
                continue
            line = text.count("\n", 0, found.start()) + 1
            errors.append(f"{path}:{line}: digest is not matched by any custom manager")

    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
