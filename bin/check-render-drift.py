#!/usr/bin/env python3
"""Fail a PR that moves what the fleet renders, unless the move is intended.

Converges the composed-fleet scenario on a base ref and on the working tree and
diffs the artefact roots. bin/README.md has the rest, including the two limits
worth knowing before trusting it.
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# Directories the repo wholly owns, checked with rpm -qf on a converged instance,
# so `find -type f` is an exact artefact set and no path list is needed. Add a
# root when a phase starts moving one.
ROOTS = ("/etc/containers/systemd", "/etc/caddy/sites", "/etc/caddy/sites-public")

SHAPES = ("solar", "rogue-trader")

# The one input that reaches a render without being a role: the scenario itself,
# which holds the fixtures converged against. Not playbooks/ — gen-fixture-hostvars
# projects only solar and rogue-trader, and its pre-commit hook (re-run by CI's
# pre-commit job) fails on drift, so a play edit that moves a render must ship a
# regenerated fixture under this same prefix. Not inventory/ either: molecule
# passes its own -i, so the repo's inventory is never loaded here.
INPUT_PREFIXES = ("roles/fleet/",)

# A renovate image bump rewrites the pinned line whole, so every changed line
# carries the digest. Nothing else in a vars/main.yml looks like this.
DIGEST_LINE = re.compile(r"@sha256:[0-9a-fA-F]{64}")


def git(*args, cwd=REPO):
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, check=True, text=True
    ).stdout


def rendering_roles():
    """Roles that template into a watched root. Derived, not listed: a stale list
    under-triggers, which is a false green."""
    roots = "|".join(re.escape(root) for root in ROOTS)
    pattern = re.compile(rf"dest:\s*[\"']?({roots})/")
    found = set()
    for tasks in REPO.glob("roles/*/tasks/*.yml"):
        if pattern.search(tasks.read_text(encoding="utf-8")):
            found.add(tasks.parts[-3])
    return found


def triggering(paths, roles):
    """The subset of changed paths that could move a watched artefact. Markdown is
    dropped, as the discover job does for the tiers — a role's README sits inside
    the role."""
    prefixes = tuple(f"roles/{role}/" for role in roles) + INPUT_PREFIXES
    return [
        path
        for path in paths
        if path.startswith(prefixes) and not path.endswith(".md")
    ]


def only_digest_bumps(base, head, paths):
    """True when every triggering path is a pin file whose changed lines all carry
    a digest. A renovate bump moves the Image= line by definition, and those
    automerge, so gating them on this would block the merge on an expected diff."""
    if not all(re.fullmatch(r"roles/[^/]+/vars/main\.yml", path) for path in paths):
        return False
    for path in paths:
        diff = git("diff", "-U0", f"{base}...{head}", "--", path).splitlines()
        changed = [
            line
            for line in diff
            if line[:1] in "+-" and not line.startswith(("+++", "---"))
        ]
        if not changed or not all(DIGEST_LINE.search(line) for line in changed):
            return False
    return True


def applies(base, head):
    """(should_run, reason) for CI, which asks before booking a runner. A local
    `make render-drift` is an explicit request and never consults this."""
    changed = git("diff", "--name-only", f"{base}...{head}").split()
    if not changed:
        return False, "no files changed"
    roles = rendering_roles()
    paths = triggering(changed, roles)
    if not paths:
        return False, (
            f"nothing changed under the {len(roles)} rendering roles or their inputs"
        )
    if only_digest_bumps(base, head, paths):
        return False, "only renovate digest bumps, whose Image= change is the point"
    return True, f"{len(paths)} changed path(s) can move a watched artefact"


def instance(shape, run_id):
    return f"lex-fleet-{shape}-incus-{run_id}"


def incus(name, *args, check=True):
    return subprocess.run(
        ["incus", "exec", name, "--", *args], capture_output=True, text=True, check=check
    ).stdout


def converge(tree, run_id):
    env = {**os.environ, "MOLECULE_RUN_ID": run_id}
    subprocess.run(
        ["make", "converge", "ROLE=fleet"], cwd=tree, env=env, check=True
    )


def destroy(tree, run_id):
    env = {**os.environ, "MOLECULE_RUN_ID": run_id}
    subprocess.run(["make", "destroy", "ROLE=fleet"], cwd=tree, env=env, check=False)


def default_ipv4(name):
    """The address ansible_facts['default_ipv4'] resolves to. solar's play
    templates it into two quadlets and it is DHCP-assigned per instance, so
    unnormalised those two differ on every run. Only the default route's source:
    the addresses prepare.yml adds to lo are fixture literals and must compare."""
    route = incus(name, "ip", "-4", "route", "get", "1.1.1.1")
    found = re.search(r"\bsrc\s+(\S+)", route)
    return found.group(1) if found else None


def capture(run_id, outdir):
    """Pull every watched artefact out of each instance, normalised, and return
    the count per shape. Per shape, not a total: a shape that rendered nothing is
    absent from both captures and so diffs as identical, which is a silent loss of
    that shape's coverage — a total hides it behind the other shape's artefacts."""
    taken = {}
    for shape in SHAPES:
        name = instance(shape, run_id)
        address = default_ipv4(name)
        listing = incus(name, "find", *ROOTS, "-type", "f", check=False)
        taken[shape] = 0
        for remote in sorted(listing.split()):
            local = outdir / shape / remote.lstrip("/")
            local.parent.mkdir(parents=True, exist_ok=True)
            text = incus(name, "cat", remote)
            if address:
                text = text.replace(address, "<INSTANCE_IPV4>")
            local.write_text(text, encoding="utf-8")
            taken[shape] += 1
    return taken


def compare(base_dir, head_dir):
    diff = subprocess.run(
        ["diff", "--recursive", "--unified", "--new-file", str(base_dir), str(head_dir)],
        capture_output=True,
        text=True,
    )
    return diff.returncode == 0, diff.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("head", nargs="?", default="HEAD")
    parser.add_argument(
        "--applies",
        action="store_true",
        help="print run/skip and exit, without converging anything",
    )
    parser.add_argument(
        "--base-capture",
        metavar="DIR",
        help="reuse the base side's render from DIR if present, else write it there",
    )
    args = parser.parse_args()

    if args.applies:
        should_run, reason = applies(args.base, args.head)
        print("run" if should_run else "skip")
        print(reason, file=sys.stderr)
        return 0

    if not (REPO / ".venv").is_dir():
        print("render-drift: no .venv — the make targets need it", file=sys.stderr)
        return 2

    workdir = pathlib.Path(tempfile.mkdtemp(prefix="render-drift-"))
    worktree = workdir / "base-tree"
    head_dir = workdir / "head"
    # A caller-owned directory survives this run, so CI can cache it; without one
    # the base side lands in the tempdir and dies with it.
    base_dir = (
        pathlib.Path(args.base_capture).resolve()
        if args.base_capture
        else workdir / "base"
    )

    # The base side is a function of the base commit and of this script's capture
    # rules; both key the cache upstream. It is published whole below, so its
    # presence is enough — nothing partial can get here.
    reusable = base_dir.is_dir()
    if reusable:
        print(f"render-drift: reusing the cached base for {args.base}", file=sys.stderr)

    try:
        # Captured into the tempdir and moved into place only once complete, so a
        # run that dies mid-capture leaves nothing for the next one to trust.
        staged = workdir / "base"
        sides = [("head", REPO, "drift-head", head_dir)]
        if not reusable:
            git("worktree", "add", "--quiet", "--detach", str(worktree), args.base)
            # .venv is gitignored, so a worktree has none and the make targets,
            # which activate it, would die on the base side only.
            (worktree / ".venv").symlink_to(REPO / ".venv")
            sides.append(("base", worktree, "drift-base", staged))

        for label, tree, run_id, outdir in sides:
            print(f"render-drift: converging {label}", file=sys.stderr)
            try:
                converge(tree, run_id)
                taken = capture(run_id, outdir)
            except subprocess.CalledProcessError:
                # Either stage: the point is that there is no render to compare,
                # so this is not the gate reporting a diff.
                print(
                    f"render-drift: the {label} side never produced a render to "
                    "compare — fix that first; it is not a render diff.",
                    file=sys.stderr,
                )
                return 2
            finally:
                destroy(tree, run_id)

            counts = ", ".join(f"{n} {shape}" for shape, n in taken.items())
            print(f"render-drift: {label} rendered {counts}", file=sys.stderr)
            empty = [shape for shape, n in taken.items() if not n]
            if empty:
                print(
                    f"render-drift: {label}'s {' and '.join(empty)} rendered nothing "
                    f"into {', '.join(ROOTS)} — refusing to call that a clean diff.",
                    file=sys.stderr,
                )
                return 2

        if not reusable:
            shutil.rmtree(base_dir, ignore_errors=True)
            base_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(staged), str(base_dir))

        identical, report = compare(base_dir, head_dir)
        if identical:
            print("render-drift: rendered artefacts are unchanged", file=sys.stderr)
            return 0
        print(report)
        print(
            "\nrender-drift: the rendered artefacts moved. If that is intended, say so "
            "in the PR and describe the diff above; if not, this is the gate working.",
            file=sys.stderr,
        )
        return 1
    finally:
        # Tolerant: this runs even when `worktree add` was what failed, and an
        # exception here would mask the one worth reading.
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(worktree)],
            cwd=REPO,
            capture_output=True,
            check=False,
        )
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
