---
name: branch-finaliser
description: >-
  Reshape a finished feature branch into a clean, bisect-safe history and open
  its PR. Curates the branch's change into self-contained, logical commits —
  splitting, grouping, reordering, and staging hunk-by-hunk where needed — with
  no whitespace or unrelated churn; gives each the correct, consistent
  Conventional Commits message; verifies every commit is green so the tree
  bisects; then opens a `type: name` PR with a description. Preserves author and
  committer dates wherever the rewrite allows. Use when a branch is functionally
  done and its history needs cleaning up before merge — triggers include
  "finalise this branch", "tidy up the commits", "clean up the git history",
  "prepare this branch for a PR", "open a PR for this branch", even when the
  skill is not named explicitly.
---

# Branch finaliser

Take a branch whose *content* is already done and reshape its *history* into a
sequence of clean, logical, bisect-safe commits, then open the PR. This skill
rewrites how the change is committed; it does not change what the change does.
The flow, in order:

1. **Phase 0 — set up:** scope, principles, backup ref, baseline snapshot, and the
   dates to preserve — all before any rewrite.
2. **Phase 1 — curate** the change into self-contained, logical commits.
3. **Phase 2 — verify bisectability:** every commit green.
4. **Phase 3 — audit messages:** correct, consistent Conventional Commits.
5. **Phase 4 — open the PR.**
6. **Report.**

Run autonomously, but treat history rewriting as load-bearing: keep the backup
ref and the content invariant (below) so any step is reversible, and surface
rather than guess whenever a curation decision is genuinely ambiguous.

## Scope

The work is the current branch's divergence from `main`:

```bash
BASE=$(git merge-base main HEAD)     # commits to curate: BASE..HEAD
```

The changeset to reshape is **everything BASE..HEAD plus any uncommitted work in
the tree** — refine hands off a clean-but-uncommitted tree, and that work is part
of the branch's change. Stop and say there is nothing to finalise if the branch
is `main`, or if `BASE..HEAD` is empty and the tree is clean.

## Repo principles

Read `CLAUDE.md` (root, plus any nested one on the changed paths) first; it binds
and overrides anything here. This skill *enforces* its commit rules — the
operationally load-bearing ones:

- **Commit hygiene** — each commit holds only the changes for its stated purpose:
  no whitespace churn, no unrelated or "while I was here" edits.
- **Conventional Commits** — `scope` is the role name, omitted only for
  cross-cutting changes; mind the project's extra `ops` type, distinct from
  `build`.
- **Bisect-safe** — every commit passes lint and tests; never commit red.
- **Single operator** — the operator's own branch, so rewriting and force-pushing
  it is safe.

No secrets or sensitive topology reach a commit message or the PR body.

## The content invariant

History changes; net content does not. Phase 0 captures the baseline as a tree
object `SNAP` — `git write-tree`, not `git stash create`, which omits untracked
files. The gate is two checks together — run it at the end of Phase 1 to fail fast,
and again before pushing:

```bash
git status --porcelain          # empty: nothing stranded in the working tree
git diff --quiet "$SNAP" HEAD    # empty: HEAD's tree equals the baseline
```

Both are needed: the tree-vs-tree diff ignores the working tree, so it passes even
with content left stranded unstaged.

The one sanctioned exception is hygiene removal: whitespace-only churn and
clearly-unrelated/accidental edits that `CLAUDE.md` says should never have been in
the diff. Dropping a line is not free — it could drop something intended — so
**surface the hunks you propose to drop to the operator and wait for confirmation
before dropping**. Drops make `git diff "$SNAP" HEAD` non-empty by design: inspect
it and confirm every difference is one of those dropped hunks and nothing else —
any unexplained line is lost content, so restore the backup. Never silently alter
content to make a commit look clean.

## Non-interactive git

Interactive git is unavailable here: no `git rebase -i`, `git add -i`, or
`git add -p`. Rewrite history with non-interactive primitives only:

- **Rebuild by replay** (the workhorse for any mid-history change). Move the
  changeset into the working tree, then re-commit it in curated pieces:

  ```bash
  git reset --soft "$BASE"   # HEAD→BASE, whole committed changeset staged
  git reset                  # unstage: tracked edits go unstaged, branch-new files untracked
  # for each target commit, in the order you want:
  git add <paths>            # tracked or untracked; or apply a hunk patch (below)
  GIT_AUTHOR_DATE=… GIT_COMMITTER_DATE=… git commit -F <msgfile>
  ```

- **Hunk-level staging** without `add -p`: write the unstaged diff to a patch,
  keep only the wanted hunks, apply to the index with `--recount` so you need not
  fix the `@@` line counts by hand. A new file normally lands whole in one commit;
  split it only when it genuinely mixes concerns (`git add -N <file>` first so
  `git diff` shows it).

  ```bash
  patch=$(mktemp); git diff -- <file> > "$patch"   # trim to the wanted hunks
  git apply --cached --recount "$patch"
  ```

- **Tip-only edits** are lighter than a replay: `git commit --amend` to reword
  the last commit, or `git reset --soft HEAD^` to re-split it.
- Use `git commit-tree` if you need a parent/tree/date combination the porcelain
  cannot express. Never reach for `rebase -i`.

## Phase 0 — set up

Run these while HEAD is still the original tip, before any rewrite — every later
phase depends on them:

1. **Snapshot the baseline tree** (see The content invariant):
   `git add -A && SNAP=$(git write-tree) && git reset`.
2. **Back up the full handoff:** `OLD_HEAD=$(git rev-parse HEAD)`, then point a
   backup ref at a commit whose tree is that snapshot, parented on the tip:
   `git branch finaliser-backup/<branch> "$(git commit-tree "$SNAP" -p "$OLD_HEAD" -m backup)"`.
   The backup thus holds both the committed tip and the uncommitted work; Safety and
   recovery has the restore.
3. **Record the dates to preserve:** `git show -s --format='%aI %cI' <commit>` for
   every commit whose dates you will keep — the replay's `git reset --soft "$BASE"`
   destroys the per-commit boundaries, so capture them now.

## Phase 1 — curate into logical commits

Decide the target history before touching anything: read the changeset — the
committed range (`git log -p "$BASE"..HEAD`), the uncommitted diff, and any
**untracked** files (`git status --porcelain`; `git diff` will not show them) —
and plan the final sequence of commits as a clear implementation flow. Each target commit is
self-contained, does one logical thing, and stands green on its own.

Then build that sequence by replay. For each commit, stage exactly its
content — whole files with `git add <path>`, or specific hunks via the patch
route when one file's changes belong to more than one commit — and commit it with
its final Conventional Commits message and its dates (see below). Drop the
whitespace/unrelated hunks you flagged. When the sequence is complete the tree
must be clean (`git status --porcelain` empty) and satisfy the content invariant.

Group and split for *logic*, not count: combine changes that only make sense
together, separate independent concerns, and order so the branch reads as a
coherent build-up. A feature and its tests may be one commit or two adjacent
green commits — never a green commit followed by one that makes it pass.

## Date preservation

Phase 0 captured the dates to preserve (`git show -s --format='%aI %cI'`); re-stamp
each commit from that record:

```bash
GIT_AUTHOR_DATE="$AD" GIT_COMMITTER_DATE="$CD" git commit …
```

Replay commits are created fresh, so **neither** date is inherited — set both env
vars on every commit whose dates you mean to keep. `--amend` (the tip-only path)
is the exception: it keeps the author date by default but moves the committer date
to now, so preserve that one explicitly with `GIT_COMMITTER_DATE`.

Per operation — keep real dates wherever the result stays chronologically
monotonic, take fresh dates only where it cannot:

- **Reword** (same position, same tree): keep both original dates.
- **Split** one commit into adjacent pieces: every piece inherits the source
  commit's author and committer dates.
- **Squash** adjacent commits: take the **earliest** constituent's author date
  and the **latest** constituent's committer date — both real, both monotonic.
- **Reorder**: do **not** keep original dates. Moving a commit earlier than one
  with an older date would make `git log` run backwards in time, so reordered
  commits take fresh finalisation-time dates (git's default). This is the only
  case where dates are not preserved.

Committer and author identity are the single operator throughout, so only dates
need carrying; if a non-operator author ever appears, preserve it with `--author`.

## Phase 2 — verify bisectability

Walk the curated commits oldest→newest, checking out each with `git checkout -f`
(so a previous gate's autofix cannot block the next checkout), and gate each; after
the walk, `git switch` back to the branch.

- **Lint every commit** — `make pre-commit`. Cheap; mandatory. A hook
  that autofixes files makes pre-commit exit non-zero — treat that as the commit
  failing lint (re-curate so it is clean from the start) and discard the autofix
  edits before moving on.
- **`make test ROLE=<role>` for each role a commit changes** — the bisect-safety bar is
  lint *and* tests. Run it only for roles whose files differ from the previous
  gated commit; a commit that changes no role needs no molecule run. molecule is
  slow: if the sweep means more than a few runs, surface the count to the operator
  and wait before starting.

A red commit is a real defect in the curation, not something to paper over: it
means content landed in the wrong commit (a commit that needs a later one to go
green). Fix it by re-curating — move the offending hunk into the right commit —
not by editing content to pass. Re-run the sweep. Cap at 3 attempts; if it still
will not bisect cleanly, restore the backup and surface it. A gate that *cannot
run* (no container runtime, molecule absent) is not a red commit — surface it and
stop without rolling back, rather than spending attempts on a tooling failure.

## Phase 3 — audit messages

Messages were written in Phase 1, so this is a consistency pass, and reword
changes no tree — it cannot disturb Phase 2's result. Across the whole series
check: correct type per commit (the Conventional Commits set, plus the project's
`ops`); role-name scope where the change is role-scoped, omitted where genuinely
cross-cutting; consistent mood, tense, and capitalisation; subject describing the
*purpose*, not the file list. Reword any outlier in place, preserving its dates.
If no honest single message fits a commit because it does two things, that is a
Phase 1 mis-split, not a reword — loop back to re-curate and re-gate it, never
paper it over with a message. Otherwise this pass changes nothing.

## Phase 4 — open the PR

Push the rewritten branch and open the PR against `main`:

```bash
git push --force-with-lease=<branch>:"$OLD_HEAD"   # never pushed yet: git push -u origin HEAD
gh pr create --base main --title "type: name" --body "<description>"
```

The lease pins the recorded pre-rewrite tip, so an intervening fetch cannot let the
push silently clobber other work (the bare `--force-with-lease` leases against the
remote-tracking ref, which a fetch advances). A never-pushed branch has no upstream
to lease against — push it with `-u` instead, as the comment notes. If the push or
`gh pr create` fails (auth, network, branch protection), do **not** roll back the
rewritten history — it is correct: report the failure, the local branch state, and
the command to finish by hand.

Title is `type: name` — the type that best represents the branch overall and a
short name; add a `(scope)` only when the whole branch is one role. The body is
terse and direct per `CLAUDE.md`'s documentation style: what the branch changes
and why, the logical commits in order, and the verification run (lint, and
molecule per role). No secrets, no sensitive topology.

## Safety and recovery

- Phase 0 creates the backup ref; keep it until the PR is up and the operator is
  satisfied. Run the content-invariant gate (both halves) before pushing; if either
  fails for any reason other than the confirmed dropped hunks, restore and stop.
- Restore: `git reset --hard finaliser-backup/<branch>` brings the full handoff back
  (its tree is the snapshot), then `git reset "$OLD_HEAD"` moves HEAD to the tip and
  leaves the handoff in the tree as unstaged/untracked work — the exact pre-finalise
  state.

## What this skill does not do

- It does not change behaviour or net content — only the noise it surfaces and
  you confirm. Reviewing and simplifying the change is `refine`'s job; run that
  first.
- It does not merge. Integration is a `--no-ff` merge, the operator's call.
- It does not run plays against live hosts.

## Final report

Summarise: the original vs. final commit shape (how many commits, what was
split/grouped/reordered/reworded), any hunks dropped and why, the per-commit gate
results proving bisectability, which dates were preserved vs. re-stamped and why,
and the PR URL.
