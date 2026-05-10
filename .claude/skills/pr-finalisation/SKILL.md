---
name: pr-finalisation
description: Use when finalising a PR for jedimasterjonny.lex — computes the version bump from accumulated changelog fragments, regenerates the changelog with antsibull-changelog, and writes the single release commit. Trigger on phrases like "finalise the PR", "release commit", "bump the version", "wrap up the PR", "ready to merge", "cut a release", or whenever a PR with accumulated changelog fragments needs its closing release commit. Also use when the user asks to bump galaxy.yml's version field or regenerate CHANGELOG.md / changelogs/changelog.yaml.
---

# PR finalisation

A PR that touches the collection ends with one release commit that bumps the version in `galaxy.yml`, regenerates the changelog from accumulated fragments, and stages exactly those files. This is the only commit in the repo allowed to touch multiple unrelated things — that's its purpose.

A PR with no changelog fragments has made no user-visible changes, so it gets no release commit and no version bump. Stop and tell the user if that's the case.

## The workflow

### 1. Check for accumulated fragments

```bash
ls collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/
```

If the directory is empty (or contains only the `.gitkeep`-style placeholder), there is nothing to release. Tell the user the PR has no user-visible changes and no release commit is needed. Stop.

If fragments are present, continue.

### 2. Compute the bump level

Read each fragment file and identify which top-level sections it uses. Map sections to bump levels:

| Sections present in any fragment                                     | Bump  |
| -------------------------------------------------------------------- | ----- |
| `breaking_changes`, `removed_features`                               | major |
| `major_changes`, `minor_changes`, `deprecated_features`              | minor |
| `bugfixes`, `security_fixes`, `known_issues`                         | patch |

Take the highest level present. A PR with one `bugfixes` fragment and one `minor_changes` fragment is a **minor** bump — minor wins.

`trivial` fragments don't appear in the changelog and don't contribute to the bump level.

### 3. Suggest a major bump if `major_changes` is present

The default mapping puts `major_changes` into the *minor* bump bucket. That's correct for most cases — antsibull's `major_changes` section often covers reworks that are large but still backwards-compatible.

**However:** if any fragment uses `major_changes`, also tell the user that a major bump may be appropriate if the scope of those changes is large enough to warrant it (e.g., a substantial rework of role behaviour even without a strictly breaking interface change). Phrase it as a suggestion they can accept or reject — don't switch to major automatically.

Example phrasing:

> "Found 1 `major_changes` fragment. The default calculation gives a **minor** bump, but if those changes are large in scope you may want to bump **major** instead. Let me know which you want."

### 4. Form a view on whether to release this PR now

A PR with real fragments doesn't always need to ship a release commit immediately. Sometimes the right call is to defer the release to a later PR that bundles more user-visible work. Form a view based on:

- **Fragment substance.** Are the changes consequential (security fix, bugfix consumers are likely hitting, new role, breaking change), or thin (one minor doc tweak, one small variable rename)?
- **Release cadence.** When was the last release? A very recent cut means another bump can wait; long-stale `main` means consumers benefit from any release.
- **Stated intent.** Did the user mention upcoming work that should land in the same release?
- **Bump level signal.** Major or breaking changes generally warrant their own release so consumers can pin a known cut. Patch-only PRs are the easiest to defer.

Default to "release now" — that is the repo convention. Only suggest deferral when you have a concrete reason. Phrase the view as a suggestion the user can override; the decision is theirs.

Don't ask the user yet — this view is presented in the next confirmation step alongside the version proposal.

### 5. Read the current version and propose the new one

Read `collections/ansible_collections/jedimasterjonny/lex/galaxy.yml` with the Read tool and pull the `version:` field.

Compute the proposed new version from the current version and the bump level (standard semver: major bumps reset minor and patch to 0; minor bumps reset patch to 0; patch bumps add 1).

### 6. Confirm with the user

Show the user:

- Current version
- Proposed bump level and new version
- Reasoning: which fragments contributed which sections
- Major-bump suggestion if applicable (per step 3)
- Your view from step 4 on whether to release now or defer, with the reason

The user has three valid responses: proceed with the proposed version, override the version, or defer the release entirely. Wait for explicit confirmation before continuing. Do not proceed silently.

If the user defers, stop here. The fragments stay in `changelogs/fragments/` and the next PR's finalisation will pick them up alongside whatever is added then. No version bump, no release commit, nothing else to do.

Example (release now):

> ```
> Current: 0.3.1
> Proposed: minor → 0.4.0
>
> Reasoning:
>   - 2 fragments with minor_changes (new role: monitoring; new variable: baseline_timezone)
>   - 1 fragment with bugfixes (firewall idempotency fix)
>
> My view: release now. Three substantive fragments including a new role — worth a release on its own.
>
> Confirm 0.4.0, defer to a later PR, or override?
> ```

Example (suggest deferral):

> ```
> Current: 0.3.1
> Proposed: patch → 0.3.2
>
> Reasoning:
>   - 1 fragment with bugfixes (typo fix in baseline README)
>
> My view: consider deferring. The only fragment is a doc typo; if more work is queued for the next PR, batching this with it would avoid a near-empty 0.3.2.
>
> Confirm 0.3.2, defer to a later PR, or override?
> ```

### 7. Bump galaxy.yml

Edit the `version:` field in `collections/ansible_collections/jedimasterjonny/lex/galaxy.yml` to the confirmed version. Change nothing else in that file.

### 8. Draft and write a release_summary fragment

Antsibull-changelog doesn't require a release_summary, but this collection's previous releases have included one — it appears at the top of the changelog as the headline summary for the release. Continue the convention by default; only skip when there's nothing meaningful to summarise.

Read the accumulated fragments and draft a 1-3 sentence summary covering the headline changes. Lead with what consumers will care most about:

- **Major release:** lead with the breaking change(s) and any migration note.
- **Minor release:** lead with new functionality, then significant behaviour changes.
- **Patch release:** lead with notable bug or security fixes.

Keep it concrete (mention role names, behaviour) but short. The full detail lives in the per-section entries below it; the summary is the elevator pitch.

Show the draft to the user. Accept edits, accept a full replacement, or accept "skip" (no summary fragment for this release).

If the user accepts (with or without edits), write the fragment to:

```
collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/<version>-release-summary.yml
```

The version-prefixed filename groups the summary with its release for human readers; antsibull doesn't parse it. Format:

```yaml
---
release_summary: |
  Adds the new monitoring role with Prometheus support, and ships
  improvements to baseline timezone handling. Includes a fix for
  firewall idempotency on minimal images.
```

Single-line summaries can use a plain scalar instead of the block form:

```yaml
---
release_summary: "Patch release fixing firewall idempotency on minimal images."
```

If the user chose to skip, write nothing and proceed to step 9. Step 10's `git add changelogs/fragments/` still works — it stages the deletions of the other fragments without needing a summary file.

### 9. Run antsibull-changelog

`antsibull-changelog release` must run from the collection root. Use a subshell so the cwd change doesn't leak into later commands:

```bash
(cd collections/ansible_collections/jedimasterjonny/lex && antsibull-changelog release)
```

This consumes the fragments (deleting them from `changelogs/fragments/`), updates `changelogs/changelog.yaml`, and regenerates `CHANGELOG.md`. It picks up the new version from the `galaxy.yml` you just edited.

### 10. Stage exactly the release artefacts

Stage **only** the files modified or deleted by the release process:

```bash
git add collections/ansible_collections/jedimasterjonny/lex/galaxy.yml
git add collections/ansible_collections/jedimasterjonny/lex/CHANGELOG.md
git add collections/ansible_collections/jedimasterjonny/lex/changelogs/changelog.yaml
git add collections/ansible_collections/jedimasterjonny/lex/changelogs/fragments/
```

The last line stages the fragment deletions. Verify with `git status` that nothing else is staged — if there's stray content, the release commit's "one logical change for this PR" purpose is broken and the unrelated work should go in its own commit.

### 11. Commit

```bash
git commit -m "release: X.Y.Z"
```

Use the `release:` prefix (not `chore:`, not `feat:`). The release commit is its own category — see the convention list in `CLAUDE.md`. The message body can stay empty; the regenerated `CHANGELOG.md` is the canonical record of what's in the release.

## What the release commit may touch

Only:

- `galaxy.yml` (version field only)
- `CHANGELOG.md` (regenerated)
- `changelogs/changelog.yaml` (regenerated)
- Deleted fragment files in `changelogs/fragments/`

Anything else in the staged diff is a mistake. If pre-commit auto-fixes touched other files during the commit, revert those hunks and let them go in a separate commit.

## When NOT to use this skill

- A PR with no changelog fragments — no release needed.
- Mid-PR work — fragments accumulate as commits land; the release commit is the *last* commit before merge.
- Rebases that don't add new user-visible commits — no new release needed.
- Reverting a release — that's a different operation; ask the user how to handle.
