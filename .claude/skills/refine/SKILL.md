---
name: refine
description: >-
  Drive recently written or changed code to a converged, high-quality state.
  First runs an architectural design-review loop (could the whole approach be
  simpler or different?), then a simplify + code-review loop that applies every
  finding which does not violate repo principles, iterating until fresh
  reviewers have nothing left to say, then verifies with lint and molecule and
  updates the docs to match. Use this whenever you have just written or
  changed code and want it polished and checked before committing — triggers
  include "refine this", "polish the code I just wrote", "check the code that's
  been written", "tidy up this change", "clean up and review my diff", even when
  the skill is not named explicitly.
---

# Refine

Take freshly written code and drive it to a state where independent reviewers
have nothing left to say. The flow, in order:

1. **Establish scope and load repo principles.**
2. **Phase 1 — design review loop:** is the *whole approach* as simple as it
   should be? Repeat with a fresh reviewer until one is satisfied cold.
3. **Phase 2 — simplify + code-review loop:** line-level quality and
   correctness. Cycle until a full pass changes nothing.
4. **Lint** (`make pre-commit`) after every editing round in Phase 1 or 2; **test**
   (`molecule`) once after Phase 2 converges — and if it fails, fix at root and
   re-run Phase 2 (not the whole flow).
5. **Phase 3 — documentation:** update the READMEs up the tree and `CLAUDE.md`
   where this change warrants it, then run any doc edits through their own
   code-review loop.
6. **Report.**

Run autonomously — the operator asked for a loop, so act on feedback yourself
and only surface mid-run if you hit a guard: a round cap, a reviewer conflict
(design or simplify/review), or a test failure you cannot resolve. This skill edits the
working tree; it does not commit (see below).

## Scope

The code under review is the recent change: the diff of the current branch
against the base branch (`main` here) plus any uncommitted work in the tree.
This same scope feeds the design reviewer, `simplify`, and `code-review` — the
latter two auto-detect the current diff, so just invoke them (Phase 3 narrows
`code-review` to the doc files).

If there is no change, stop and say there is nothing to refine.

Track edits objectively. Snapshot the diff (`git diff` plus `git status`) before
and after each step, with lint already green so its auto-fixes are not mistaken
for review edits. "No change" means the snapshot is byte-identical, not merely
that a tool reported it found nothing — that is what lets the loops terminate
reliably.

## Repo principles

Before touching anything, read `CLAUDE.md` (root, plus any nested `CLAUDE.md` on
the changed paths). These bind, and they override any reviewer. The ones that
most often collide with reviewer feedback:

- KISS / YAGNI / DRY, and a single owner-operator — reject suggestions that add
  generality, multi-tenancy, configurability, or onboarding affordances nobody
  will use.
- No plaintext secrets; keep sensitive topology out of the repo.
- Every task idempotent; every commit green and bisect-safe.
- Live hosts get `--check`/`--diff` only — never apply.

When a reviewer (design or code) suggests something that conflicts with a
principle, reject it and record why. Never trade a principle for a finding.

## Phase 1 — design review loop

Higher-altitude than `simplify`: this questions the solution, not the lines. Do
it first, because there is no point polishing code you are about to replace.

Each round:

1. Spawn a **fresh** subagent — a new `Agent` call, never a continued one. A
   clean reviewer judges the current state on its own merits instead of
   defending its earlier suggestions, which is exactly what makes "it's
   satisfied" mean something. Use a read-only architect (e.g. the `Plan`
   agent type) so it advises rather than edits.
2. Give it the scope/diff, the relevant files, and the repo principles. Ask it
   plainly: *could this be solved more simply, or with a materially better
   design? Stay at the level of the approach — line-level cleanups are Phase 2's
   job, not yours. Raise only changes clearly worth making for a single-operator
   homelab; if the design is already sound, say so.* Have it return a verdict
   (satisfied or not) plus concrete suggestions.
3. If satisfied, exit Phase 1.
4. Otherwise apply the suggestions that respect the principles, lint (see
   Verification), then loop with a brand-new reviewer.

The exit condition is: a fresh reviewer, seeing the current state cold, has
nothing meaningful to add. If successive reviewers merely trade taste — one
undoing what the last asked for — treat that as a conflict to surface, not a
loop to keep running. Cap at 5 rounds; if the design has not converged by then,
stop the whole skill and surface the outstanding concern — do not drop into
Phase 2 to polish code whose design is still in dispute.

## Phase 2 — simplify + code-review loop

One cycle:

1. Run the `simplify` skill. It applies quality-only cleanups to the diff.
2. Run the `code-review` skill **without** `--fix` — you want the findings, not
   blind application, because each must be weighed against the principles. Use a
   local effort level (`medium` or `high`); never `ultra`, which is a billed
   cloud review the operator triggers themselves.
3. Act on every finding that respects the principles — including correctness
   bugs, not just cleanups. Skip a finding that breaks a principle, or that you
   judge simply wrong (a `code-review` false positive — expected at higher
   effort); record the reason in either case, and never edit the tree to satisfy
   a finding you do not believe.
4. If the cycle edited any file, lint (see Verification).

Repeat. **Converged** when a full cycle makes zero edits to the working tree:
`simplify` changed nothing and no review finding was acted on (lint's own
auto-fixes do not count — measure convergence with lint already green). That
fixed point is what "both have nothing left" means.

Guards:

- Cap at 5 cycles — a hard stop in case review keeps surfacing new work.
- If a cycle reverts an edit a prior cycle made (`simplify` strips what
  `code-review` asked back, or vice versa), that conflict needs a human call —
  surface it and stop rather than oscillating.

## Verification

**Lint, every editing round.** After any round that changes the tree — a design
round or a simplify/review cycle — run `make pre-commit`. It is
cheap, so keeping it green continuously means the only thing left to surprise
you at the end is behaviour. Fix any lint failure at its root before the next
round; never carry red forward.

**Test, once the code converges.** When Phase 1 and Phase 2 have converged — but
before Phase 3 docs — run `make test ROLE=<role>` for each role touched by the
change (the role directories under `roles/` in the changed paths; add
`SCENARIO=` or the `test-*` targets for a non-default tier — a scenario's
provisioner config reaches molecule only through those targets). molecule is
slow, so it runs once rather than per round, and its idempotence check confirms
tasks stay idempotent. If the change touches no role, molecule has nothing to
test — note that and move to Phase 3.

**If molecule fails, re-vet the fix through Phase 2.** A test failure means the
converged code is wrong, and the fix you make is new code that has not been
reviewed. But a molecule failure is almost always a concrete code bug, not a
design flaw, so do not re-run the Phase 1 design loop. Fix the failure at its
root (lint it like any other edit), re-run Phase 2 to convergence on the fix —
its 5-cycle cap resets each attempt — then run molecule again. Cap the molecule
attempts at 3; if molecule still fails, stop and surface it for a human call
rather than looping. Show the gate output as evidence.

## Phase 3 — documentation

Once the code is converged and molecule is green, make the docs match it. Doing
this after the tests pass means you document code that actually works, not code
a later fix might still change. Documentation changes do not affect molecule, so
they do not retrigger it.

Work outward from the change, then check the project's standing docs:

1. **The change's own folder.** Does this change leave the folder's README
   wrong, missing, or stale? Bring it up to date — or, where there is none and
   the change warrants one, create it (see the bar below).
2. **Up the tree.** Walk from that directory to the repo root. Where this change
   alters what a README documents — a new role, a changed interface, a moved
   file, a new convention — update that README, or create one where there is
   none and the change warrants it (the same bar below).
3. **`CLAUDE.md`.** Does the change introduce or alter a convention it records —
   layout, gates, commit rules, a workflow, a tool? If so, update it; if not,
   leave it.

Create a README only when the change genuinely calls for one — a new role or
component whose purpose or usage is not self-evident from the code. Hold that
bar: a single-operator homelab does not want a README in every folder, and
inventing docs to satisfy a step breaks the same YAGNI the code is held to. A
new README follows the repo's conventions strictly — placed where the layout
already puts such docs (for a role, its own directory) and written in the style
below. When a doc genuinely needs no change, say so and move on.

Hold every doc edit to CLAUDE.md's documentation style — terse and direct for a
senior reader.

**Doc review loop.** If you edited any doc, run it through its own loop, the way
Phase 2 treats code: run the `code-review` skill (no `--fix`) scoped to the doc
files — pass it their paths so it does not re-open the already-settled code diff
— act on every finding that respects the principles and the documentation style,
lint, and repeat until a pass yields no acted-on edits. Cap at 5 cycles. If you
edited no doc, there is nothing to review — note the docs were already accurate
and move on.

## What this skill does not do

- It does not commit. It leaves a clean, green tree and a summary; curating the
  change into logical, self-contained commits is the operator's call, and these
  refinements must not be folded into an unrelated commit.
- It does not run plays against live hosts. molecule runs in containers; live
  runs stay `--check`/`--diff` and are the operator's call.

## Final report

When the phases have converged, summarise: how many design rounds and cycles
ran (code, and docs if any), the substantive changes made, which docs changed
or why none needed to, any findings rejected and the principle each would have
broken, and the result of the final gate run.
