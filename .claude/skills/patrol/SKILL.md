---
name: patrol
description: >-
  Deal one random target from the repo — a role, a top-level directory, or the
  root — and review it against a deliberately hostile prior: assume it is the
  worst possible solution to its problem, then ask what would be simpler, DRYer,
  more idiomatic, or unnecessary. Lands only changes that survive a conservative
  removal-only bar, hands the result to `refine` under explicit constraints and
  then `branch-finaliser`, and leaves the merge to the operator. A deck deals
  every target once per cycle; one card instead triggers a whole-repo radical
  rethink, written up and never applied. Use when the operator wants the repo
  chipped at with no particular target in mind — triggers include "patrol",
  "roll for a review", "deal me a target", "pick something and improve it",
  even when the skill is not named explicitly.
---

# Patrol

Deal one target at random, review it as if it were the worst possible solution
to its problem, and land only what survives a conservative bar.

Most runs should end with no change, and that is the skill working. A run that
reports "nothing here needs changing" and says what it checked has done its job.

One target per run. One branch. Never merge.

## 0. Preconditions

`branch-finaliser` sweeps uncommitted *and untracked* work into the PR it opens,
so a patrol started on a dirty tree curates the operator's work-in-progress into
its own branch. Before dealing:

- `git status --porcelain` must be empty. If it is not, stop and say what is in
  the way.
- HEAD must be `main` and up to date — `git pull --ff-only`.

## 1. Deal

The deck is derived, so a new role or a new tracked top-level directory gets a
card without editing this file: every directory under `roles/`, every other
tracked top-level directory, `<root>` (the loose files at the repo root), and one
`BONUS` card. That is 44 cards today, so `BONUS` comes up once per cycle.

The ledger is `.claude/patrol-ledger.md` — gitignored local state, not repo
content. One run per line, and **the line format is load-bearing**: the parser
takes the target from field 2 of every date-led line, so anything else written
to the ledger must not start with a date.

```text
YYYY-MM-DD  <target>  <pr-or-dash>  <note>
```

Everything after the last `## cycle` header is what this cycle has dealt:

```bash
cd "$(git rev-parse --show-toplevel)" || exit 1
LEDGER=.claude/patrol-ledger.md
deck() {
    git ls-files | grep / | cut -d/ -f1 | grep -vx roles
    ls -d roles/*/ | sed 's:/$::'
    printf '%s\n' '<root>' BONUS
}
dealt() { [ -f "$LEDGER" ] && tac "$LEDGER" | sed '/^## cycle/q' | awk '/^[0-9]{4}-/ {print $2}'; }
remaining=$(comm -23 <(deck | sort -u) <(dealt | sort -u))
printf '%s\n' "$remaining" | grep -c .          # cards left in the cycle
printf '%s\n' "$remaining" | shuf -n 1          # the deal
```

Zero cards left means the cycle is complete: append `## cycle <n+1> opened
<today>` (n = the count of existing `## cycle` lines) and deal from the full
deck. A count that is merely *low* on the first run of a cycle means the deck
build failed — check the working directory rather than opening a new cycle.

Deal once and commit to it. No re-rolling.

## 2. Load the context before judging it

Read, in this order, before forming any opinion:

1. `CLAUDE.md` — root, plus any nested one on the target's path. These bind and
   outrank every conclusion below.
2. The target's own `README.md`, and for a role its variables and contracts.
3. `git log --oneline -- <target>`, and the full message of any commit that
   introduced something you are inclined to delete.
4. The memory index at
   `/home/jonny/.claude/projects/-home-jonny-repos-lex-imperialis/memory/MEMORY.md`,
   and any entry naming the target.

Step 4 is not optional. Several decisions in this repo are deliberately closed —
the dual YAML linters, Packer's licence, `libvirt` needing no `retire.yml`,
`/home` being restic'd unencrypted, the btrfs timer drop-ins being generated —
and the hostile prior walks straight into all of them. Re-raising a closed
decision is a failed run, not a finding.

## 3. The lens

Assume the implementation in front of you is the worst possible way of solving
its problem, and try to prove it. Six questions, each needing evidence:

1. **Simpler?** Fewer tasks, fewer files, fewer moving parts? Where does it
   reach for generality, configurability, or a future case a single operator
   will never have (KISS, YAGNI)?
2. **DRYer?** Is this already solved elsewhere in the repo? Grep the whole tree,
   not just the target. The converse counts: is something here duplicated *out*
   into consumers that should own it, or hoisted into a shared place that has
   one caller?
3. **More idiomatic?** Is this how Ansible, systemd, podman, OpenTofu — whatever
   the target actually is — expects the job to be done? A bespoke construct
   where a stock module, unit directive, or provider feature exists is a finding.
4. **Needed at all?** Challenge the purpose. What does this customisation buy
   over the OS or upstream default? Would deleting it be noticed? Could the whole
   target go? Highest-value question, and the one most likely to be wrong.
5. **README accurate and terse?** Does it still describe the code? Does it say
   anything a senior engineer already knows, or restate what the code shows?
6. **Comments earning their place?** Every comment terse, no fillers, no
   examples, no narration of the obvious — and any that can go entirely, goes.

Two files are exempt. The root `README.md` is deliberately narrative, so Q5's
terseness does not apply to it — do not rewrite it into a `CLAUDE.md`.
`CLAUDE.md` itself is exempt from Q5 and Q6 and is never edited by this skill;
a change to it is a proposal, reported like a BONUS idea.

Absence of a README is not a finding — four cards ship none.

## 4. The bar for acting

The lens generates candidates; this bar decides which become edits. Act only
when all of these hold:

- It **removes** something — code, a customisation, a comment, a file — or
  replaces bespoke with standard. Net-new abstraction is not a patrol finding.
- **Nothing is lost** — proved, not asserted. Snapshot what the target
  observably produces, make the change, regenerate, diff. Reading the code is
  not proof: a Hugo config strip that four reviewers read as safe still deleted
  `robots.txt` and two taxonomies. Where the target produces nothing to diff,
  say what you checked instead — and say when the test is blind, because a diff
  that exercises none of the removed behaviour proves nothing.
- It **does not re-open a closed decision** (step 2).
- It is **defensible cold**, to a reviewer who did not do the deal and has no
  investment in the run producing something.

And one mechanical clause, because three of the four above are self-certified
while "removes something" is not: **a comment or README trim does not clear the
bar on its own.** It is the cheapest candidate that objectively removes
something, so left unchecked it becomes the only thing this skill ever does —
a stream of `docs:` PRs eroding the explanatory layer that `MEMORY.md` exists to
compensate for. Bank the trim in the ledger; it rides with the next substantive
change to that target.

Anything that fails the bar but still looks real goes in the report. Where the
rejection is one a future hostile pass would re-derive — a closed decision, or
something that looks redundant but is load-bearing — write it to project memory
as well, *unless the repo already defends itself*: `CLAUDE.md` states the `motd`
exemption outright, and copying the constitution into memory only gives it a
second place to rot. The ledger records the outcome; memory records reasoning the
repo does not.

Stay inside the dealt target. Something wrong two directories over gets reported,
never fixed.

## 5. Fold in, then hand off

If nothing survived the bar, skip to the report — no branch, no commit.

Otherwise branch `type/<kebab-summary>`, naming the change and not this skill
(`refactor/caddy-drop-header-block`, never `refactor/patrol-caddy`, which also
collides with the same target's branch from the previous cycle). Make the
changes, then hand off rather than reimplementing what exists — `refine` can only
review a diff, which is why the lens above is the part it cannot do:

1. **`refine`**, with its scope constrained. Left to its defaults it undoes this
   skill's bar: its Phase 1 spawns an unconstrained design reviewer that will
   propose net-new abstraction, its scope is the whole branch diff rather than
   the dealt target, and its Phase 3 edits READMEs up the tree and `CLAUDE.md`.
   State when invoking it: scope is `<target>` only; **skip Phase 1**, because
   the lens is the design pass and runs at a stricter bar; reject any finding
   that adds abstraction or touches a file outside `<target>`; do not edit
   `CLAUDE.md`. Then re-check what it produced against §4 and revert anything
   that fails.
2. **`branch-finaliser`** — curates the commits and opens the PR.

Then stop. The operator reviews and merges.

## Gates

`refine` runs `make pre-commit` and `make test ROLE=<role>`. Anything below that
it does not run is this skill's job.

| Target | Gate |
| --- | --- |
| `roles/<role>` | `make test ROLE=<role>` — or `make test-vm ROLE=<role>` for `incus`, `libvirt` and `nfs`, which ship no `default` scenario. If `echo <role> \| bin/expand-role-consumers.sh` prints more than the role itself, it is an engine: test the consumers too, since the engine's own scenario does not assert what theirs do. |
| `molecule`, `.github` | `make test ROLE=motd` — the harness exemplar; add `make test-vm ROLE=motd` if the libvirt tier changed. |
| `jonnyoc-site` | `make hugo-build`. No pre-commit hook covers it, so nothing else in the flow will. |
| everything else | `make pre-commit` alone. |

`terraform` and `packer` need no row — `tofu-fmt`, `tofu-validate`, `tflint`,
`packer-fmt` and `packer-validate` are all pre-commit hooks. Do not reach for the
`make tofu-fmt` target: it rewrites files where the hook checks them.

## The BONUS card

Dealing `BONUS` replaces the target for that run: no directory review, no edits.

Analyse the whole repo and think past its current shape. What would a fundamental
change look like — a structure abandoned, two things merged, a tier or tool
dropped, a layer of the design questioned? Look for the assumptions so settled
that nothing in the repo argues for them any more, and argue against them. The
closed-decision check still applies, and so does the single-operator lens:
"this would scale better" is not an argument here.

Produce **at most three** ideas, each with what it would cost and what it would
break. Report them inline and log a one-line summary of each in the ledger — not
date-led, so the deal parser ignores them — so the next `BONUS` run proposes
something new rather than recycling them.

Radical changes are proposals. The operator accepts or bins them.

## What this skill does not do

- **Does not merge.** The operator gates every merge, always.
- **Does not run against live hosts.** molecule is the gate; a live `--check` is
  the operator's call, and `make apply` is never this skill's.
- **Does not touch anything outside the dealt target.**
- **Does not edit any file under `.claude/skills/`** — including the two it is
  about to invoke. The `.claude` card is therefore proposal-only: review the
  skills, report what should change, edit nothing.
- **Does not edit `CLAUDE.md`.**

## Report

Every run, whatever the outcome:

- The target dealt, and how many cards remain in the cycle.
- Per lens question: what was checked, and what was found or explicitly cleared.
- What changed and why, or a plain statement that nothing met the bar.
- Candidates rejected, with the reason — closed decision, would lose something,
  out of scope, banked for the next substantive change.
- Any memory entry written.
- Observations outside the target, for the operator to pick up separately.
- The PR link, or the note that there is no branch.
