# Git Workflow — READ BEFORE ANY COMMIT

**This is a hard rule for every coding agent (Claude Code, Codex, Cursor, …) and for the
human. It is not a style preference. Violating it corrupts the academic attribution of the
master's-thesis work, which the university has to grade. When in doubt, STOP and ask.**

---

## The two lines of work

This repo runs **two parallel streams** at once:

1. **`main`** — the *released* Dragaway app. It ships to real users via Sparkle auto-update.
   All small features, bug fixes, and quality-of-life changes land here and get released
   (v1.1.3, v1.1.4, …). There is **no** `common`/`develop` branch — `main` *is* the mainline.

2. **`thesis/*`** — long-lived branches holding the master's-thesis feature work, developed
   over **weeks**. This is graded academic work and must stay cleanly attributable.

```
main          ●──●──●──●──●──●──●──●──●        ← released app, keeps shipping
                   \        \        \
thesis/<topic>      ●──●──●──M──●──●──M──●──●   ← thesis feature, weeks long
                            ↑         ↑
                     merge main in    merge main in   (NEVER rebase)
```

---

## Rules (follow exactly)

### R1 — Know which line you are on
Before writing code, run `git branch --show-current` and confirm the work belongs there:
- **Released-app work** (bugfix, small feature, release chore) → `main` (or a short-lived
  `fix/*` branch that merges straight back to `main`).
- **Thesis work** → the relevant `thesis/*` branch. **Never commit thesis work to `main`.**

### R2 — Keep thesis current by MERGING main in — never rebase
The thesis branch must not rot. Regularly (after every `main` release, or before each thesis
session) pull mainline progress **into** the thesis branch:

```bash
git checkout thesis/<topic>
git merge main          # ✅ merge — creates a clear "synced with main here" marker
```

**NEVER `git rebase main` on a `thesis/*` branch.** These branches are pushed (backup + PR);
rebasing rewrites shared history, breaks the PR, and destroys the honest timeline of when
mainline work entered the thesis. Merge often → conflicts stay small and incremental.

### R3 — Tag every thesis commit with a trailer
Every commit on a `thesis/*` branch MUST end its message with a trailer naming the thesis
component it belongs to:

```
Thesis-Component: <short-component-name>
```

This makes the thesis contribution mechanically extractable at any time, regardless of branch
topology, even after everything is merged:

```bash
git log --grep="Thesis-Component" --no-merges
```

Do **not** put this trailer on `main`-only (released-app) commits.

### R4 — Never squash the thesis feature into main
When a thesis feature is complete and integrates back to `main`, use a **true merge commit**:

```bash
git checkout main
git merge --no-ff thesis/<topic>   # ✅ preserves every thesis commit + marks the feature boundary
```

**NEVER `--squash`** a thesis branch. Squashing collapses weeks of gradable work into one
commit and erases the granular history the examiner needs. `--no-ff` keeps each commit *and*
draws a visible feature bubble in the graph.

### R5 — The thesis branch has a live draft PR
Each `thesis/*` branch has a **draft pull request** open against `main` for its whole life. It
is the single URL an examiner can open to see the full accumulating diff, commit list, and
timeline. Keep pushing to the branch; do not close the PR until the feature actually merges.

### R6 — Freeze submission points with a tag
At any academic submission/milestone, tag the exact state:

```bash
git tag thesis-<topic>-submission-<date>
git push origin thesis-<topic>-submission-<date>
```

---

## Why this structure matters (do not "simplify" it away)

- **Attribution is graded.** The university must be able to see *exactly* which work is the
  thesis contribution vs. the ongoing released app. The trailer (R3), the `--no-ff` merge (R4),
  the draft PR (R5), and the submission tags (R6) are four independent, durable proofs of that
  boundary. An agent that squashes, rebases, or commits thesis work to `main` silently destroys
  that proof — and it cannot be reconstructed later.
- **The released app must keep shipping.** Users get auto-updates from `main`. The thesis work
  cannot block or destabilise releases, so it lives on its own branch until it is truly ready.
- **The thesis must not be isolated from mainline progress.** Because bugfixes and QoL land on
  `main` continuously, the thesis branch merges `main` in regularly (R2) so it always builds on
  the current app — never a stale fork.

## Quick reference

| Task | Command |
|---|---|
| Where am I? | `git branch --show-current` |
| Start thesis session | `git checkout thesis/<topic> && git merge main` |
| List thesis commits | `git log --grep="Thesis-Component" --no-merges` |
| Thesis commits not yet in main | `git log main..thesis/<topic> --no-merges` |
| Integrate finished thesis feature | `git checkout main && git merge --no-ff thesis/<topic>` |
| Freeze a submission | `git tag thesis-<topic>-submission-<date>` |

See `docs/THESIS.md` for the running contribution map (components, commit ranges, PR link).
