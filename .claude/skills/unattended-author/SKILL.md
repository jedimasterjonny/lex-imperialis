---
name: unattended-author
description: >-
  Take an Ansible change from request to merged-and-live in one unattended pass,
  chaining the three authoring skills then gating the merge on a real apply:
  `ansible-author` (draft) → `refine` (design/review/molecule/docs) →
  `branch-finaliser` (curate commits, open the PR) → wait for green CI → apply
  to the affected hosts → reapply to confirm idempotence → merge on a clean
  apply. Invoking it is the operator's explicit, standing authorisation to apply
  to the live fleet — the one sanctioned automated-apply path. Use when the
  operator wants a change driven end to end with no hand-holding — triggers
  include "unattended author", "take this all the way", "author it, then apply
  and merge", "run the whole pipeline", even when the skill is not named.
---

# Unattended author

Drive an Ansible change the whole way — written, refined, finalised, applied to
the live fleet, and merged — without stopping for the operator at each handoff.
This skill is an **orchestrator**: it owns no authoring or review logic of its
own, it sequences the three authoring skills and then gates the merge on a real
apply. The flow, in order:

0. **Phase 0 — set up:** branch, preconditions, scope.
1. **Phase 1 — author:** run `ansible-author`.
2. **Phase 2 — refine:** run `refine`.
3. **Phase 3 — finalise:** run `branch-finaliser` — opens the PR.
4. **Phase 4 — apply on green CI:** wait for the PR's CI to go green, then apply
   to the affected hosts.
5. **Phase 5 — reapply for idempotence:** apply again; every host reports zero
   changed.
6. **Phase 6 — merge:** `--no-ff` merge on a clean, idempotent apply.

Run **unattended**: invoking this skill is the operator's standing authorisation
for every step including the live apply, so proceed through the handoffs without
asking. The only thing that stops the pipeline is a failure or a guard (see
Halting) — never a routine "may I continue?". Surface, don't barrel: if any
stage halts or fails, stop the whole flow at that point and report; do not press
on to a later phase on a broken earlier one.

## The apply reconciliation — read first

`CLAUDE.md` and the Makefile both say a live `make apply` is "the operator's
call, not part of any automated flow," and that authoring touches live hosts
only via `--check`/`--diff`. This skill is the **deliberate exception the
operator opts into by running it**: the operator invoking `unattended-author`
*is* the call to apply, given once for the whole pipeline. That standing
authorisation is what makes the automated apply legitimate; nothing else here
overrides the rule, and no other skill or play may apply unattended.

Because it crosses that line, the apply is fenced by the rails the operator
asked for, and they are not optional:

- **Apply only on green CI** — the PR's full check set must conclude success
  first (Phase 4). A red or incomplete CI never reaches an apply.
- **Apply the validated tree** — `branch-finaliser`'s content invariant
  guarantees the branch HEAD equals what CI tested and what the `--no-ff` merge
  will land on `main`, so the fleet runs exactly the reviewed code, pre-merge.
- **Reconfirm idempotence live** (Phase 5) before trusting the apply.
- **Merge only on a clean, idempotent apply** (Phase 6). The live apply is the
  *final* gate, ordered ahead of the merge on purpose.
- **No rollback.** Ansible has none; a failed apply leaves the fleet wherever it
  reached. So an apply failure halts and surfaces for the operator — it never
  auto-reverts and never merges.

## Phase 0 — set up

Before any authoring, settle the things a later phase can't recover from:

1. **Branch.** The pipeline ends in a PR, so it must run on a feature branch, not
   `main`. If HEAD is `main`, create `type/short-desc` from it (Conventional
   Commits `type`, kebab-case desc derived from the task — `feat/<role>` for a
   new role). If already on a feature branch, use it.
2. **Apply preconditions.** Confirm now what Phase 4 will need, so an unattended
   run doesn't do all the authoring then fail at the fence: `.vault_pass` exists
   at the repo root (decrypts the vault for `make apply`), `gh auth status` is
   good (CI wait + merge), and this is the control host (`scholam`) with reach to
   the fleet. If a precondition is missing, stop and surface — don't author work
   that can't be delivered.
3. **Scope.** Name what is being authored (the role/play/tasks), exactly as
   `ansible-author` would. That scope rides through every phase.

## Phase 1 — author

Invoke the **`ansible-author`** skill on the scoped work. It produces a sound,
lint-clean, uncommitted draft and hands off. Do not reimplement any of its forward
pass here. When it reports done, move to Phase 2; if it stops on a guard (it
can't establish scope, a principle conflict it won't resolve alone), halt the
pipeline and surface.

## Phase 2 — refine

Invoke the **`refine`** skill. It runs the design loop, the simplify/code-review
loop, molecule for each touched role, and the docs pass, leaving a clean, green,
still-uncommitted tree. Let it run its loops; do not second-guess them. If it
surfaces a guard — a reviewer conflict, a round cap, a molecule failure it can't
resolve — that is a real stop: halt the pipeline and surface it. Refine's molecule
gate is the last check before the change is committed, so a red exit here must
not proceed to finalise.

## Phase 3 — finalise

Invoke the **`branch-finaliser`** skill. It curates the tree into clean,
bisect-safe commits, verifies each is green, audits the messages, pushes the
branch, and **opens the PR** against `main`. Capture the PR number it reports —
Phases 4 and 6 need it. If it halts (an ambiguous curation, the content
invariant failing, a push/PR-create error), stop and surface; the branch and any
backup ref it made are the operator's to resolve.

## Phase 4 — apply on green CI

Two steps: wait for CI, then apply the affected hosts.

**Wait for green CI.** `branch-finaliser` has just opened the PR, so GitHub may
not have registered the check runs yet — and an empty check set reads as green.
Wait for at least one check to appear (lint always runs — `lint.yml` has no path
filter, so it registers on every PR) before trusting `--watch`, then poll until
every check concludes and require all success:

```bash
until gh pr checks <pr> --json name --jq '.[].name' 2>/dev/null | grep -q .; do sleep 10; done
gh pr checks <pr> --watch --fail-fast    # then block until every check settles
```

The check set is `lint` always, plus the `molecule` legs `discover` scheduled for
the changed roles (a docs-only or toolchain-only change may schedule no molecule
leg — green then means lint alone, which is correct). Treat the gate as: every
scheduled check is success. `--watch --fail-fast` exits non-zero the moment any
check fails or is cancelled — that non-zero exit is the stop signal: do not
apply, leave the PR open, surface which check failed. CI can be slow (the hetzner
leg bills a VM and takes minutes); polling is expected, a stall past a sane bound
is a surface-and-stop, not an indefinite wait.

**Determine the affected hosts.** A host is affected if its play names a changed
role:

```bash
BASE=$(git merge-base main HEAD)
# Strip *.md first, as CI's discover does, so a role-README-only edit (which CI
# runs lint-only) resolves to no role and triggers no apply.
roles=$(git diff --name-only "$BASE"..HEAD | grep -vE '\.md$' | sed -n 's#^roles/\([^/]*\)/.*#\1#p' | sort -u)
```

For each `playbooks/<host>.yml`, it is affected if its `roles:` list names any
of `$roles`. The `PLAY` value is that file's basename without `.yml` — the host
name for every play except `scholam.yml`, which targets `this_host`. A change
that also touches shared runtime config read fleet-wide (`inventory/`,
`group_vars/`) affects **every** play — widen the set to all hosts rather than
guess. A change that wires into **no** play (a role not yet added to any host, or
a molecule/docs-only change) has nothing to apply: skip Phases 4-apply and 5, and
let green CI alone gate the Phase 6 merge — say so explicitly.

**Apply.** For each affected play, in turn:

```bash
make apply PLAY=<play>
```

This runs the branch's code (the validated tree) against the live host via
`.vault_pass`. Read the `PLAY RECAP`: `failed=0` and `unreachable=0` on every
host line. Any failed or unreachable host is an apply failure — stop at that play
and do **not** apply the remaining ones, do **not** merge, leave the PR open.
There is no rollback, and any earlier play in the loop has already applied live:
surface the recap, the failing task output, and which plays are now live but
unmerged, so the operator inherits an accurate picture of the half-applied fleet.

## Phase 5 — reapply for idempotence

Re-run the same `make apply PLAY=<play>` for each affected play. The second pass
must be a no-op:

```bash
make apply PLAY=<play>      # PLAY RECAP must show changed=0 on every host
```

Require `changed=0` (with `failed=0`, `unreachable=0`) on every host line. A
host that still reports changes is a genuine non-idempotence defect — the kind
molecule's containerised check can miss but a real apply exposes (environment
divergence: NetworkManager vs netconfig, top-level-fact deprecations,
SELinux relabels). It is a real stop: do **not** merge, leave the PR open, and
surface the changed tasks so the operator (or a fresh `refine`) can fix the root
cause. Do not paper over it by reapplying until it settles.

## Phase 6 — merge

Only on a clean Phase 4 apply and a zero-changed Phase 5 (or green CI alone when
no host was affected), integrate with the project's merge convention — a `--no-ff`
merge commit, never fast-forward or squash:

```bash
gh pr merge <pr> --merge      # creates the --no-ff merge commit
```

`branch-finaliser` left a local backup ref; keep it until the operator is
satisfied, so don't `--delete-branch` here unless asked. If the merge call fails
(branch protection, a mergeability race, auth), do not retry blindly or alter
history — report the failure, that the apply already succeeded and is live, and
the command to finish the merge by hand.

## Halting

Unattended means proceed without asking, not press on through breakage. Stop the
whole pipeline and surface — never advance to a later phase — when:

- A sub-skill (`ansible-author`, `refine`, `branch-finaliser`) halts on its own
  guard. Its stop is the pipeline's stop; relay what it reported.
- CI concludes with any check failed or cancelled (Phase 4) — the PR stays open.
- An apply reports a failed or unreachable host (Phase 4), or a non-zero changed
  on the idempotence reapply (Phase 5).
- A Phase 0 precondition is missing.

In every case leave the work where it is — branch, PR, and live state intact, no
rollback, no merge — and report the stage, the evidence (gate or recap output),
and what the operator needs to decide.

## What this skill does not do

- It does not author, review, or curate — Phases 1-3 are wholly the three
  sub-skills; this skill only sequences them and acts on their outcome.
- It does not apply outside the green-CI fence, and it is the *only* sanctioned
  unattended apply — no other skill or play applies to live hosts unattended.
- It does not roll back. There is no automated revert of a live apply; a failure
  surfaces for the operator.

## Final report

Summarise the run end to end: the branch and PR, the sub-skill outcomes (design
rounds / review cycles / commits as each reported), the CI result that gated the
apply, the hosts applied and their first-pass recap, the idempotence reapply
result, and the merge — or, if the pipeline halted, the stage it stopped at, the
evidence, and the live state left behind.
