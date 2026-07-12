# Git Workflow — READ BEFORE ANY EDIT

This repository has **exactly two canonical branches**: `main` and `thesis`. This is a hard rule for
the owner and every coding agent (Codex, Claude Code, Cursor, and others). Branches and worktrees are
shared coordination state, not disposable implementation details. Do not create, rename, copy, or
delete them without explicit user approval.

Violating this workflow can mix live product work with graded master's-thesis work, lose another
agent's uncommitted changes, or destroy the academic attribution recorded in Git history. When any
state is unexpected, stop and ask.

---

## 1. The only two branches

### `main` — the live product

`main` is the version users install and the only normal development branch. It includes:

- the released Dragaway macOS app;
- all user-facing features, fixes, refactors, and quality improvements;
- the product page / website and its media;
- icons, naming, branding, onboarding, and documentation for the product;
- build, signing, Sparkle, release, and distribution work;
- general infrastructure that is useful outside the thesis.

There is no `develop`, `common`, `feature/*`, `fix/*`, `codex/*`, or `claude/*` workflow. Ordinary
product work happens on `main`.

### `thesis` — research additions on top of `main`

`thesis` contains the master's-thesis contribution and regularly merges the current `main`. It
includes only research-specific additions such as:

- the Computational Intent Pipeline;
- thesis-only sensors, inference, policy, and proactive affordances;
- study instrumentation, conditions, evaluation, and research telemetry;
- thesis-specific architecture and contribution documentation.

There are no `thesis/*` sub-branches. The single integration and PR branch is `thesis`.

```text
main     ●──●──●──●──●──●──●──●       live product keeps moving
              \        \        \
thesis   ●──●──M──●──●──M──●──●──M    thesis-only commits + merges from main
               ↑        ↑        ↑
            merge main into thesis; never rebase
```

The appearance of a Main feature in the Thesis working tree is expected after a merge. It remains
Main work because attribution follows its originating commit, not the branch's final file tree.

---

## 2. Mandatory preflight before changing anything

Before any edit, Git mutation, file move, or commit, run:

```bash
git branch --show-current
git status --short --branch
git worktree list
```

Confirm all of the following:

1. The current branch is the correct one for the requested work.
2. Every existing staged, unstaged, and untracked path is understood.
3. The target branch is not already active in another worktree you have overlooked.
4. No other person or agent appears to be working in the paths you need.

### Stop rules for concurrent agents

- Unexpected changes belong to another person or agent until proven otherwise.
- Never run `git restore`, `git stash`, `git clean`, branch deletion, worktree removal, or bulk staging
  against changes whose ownership is unclear.
- Never "clean up" a foreign worktree merely because it is dirty, old-looking, or on another branch.
- Never stage with `git add .` or `git add -A` in a shared dirty worktree. Stage exact reviewed paths.
- If another agent is editing overlapping files, stop and coordinate instead of overwriting or
  reconstructing its work.

---

## 3. Route work to the correct branch

| Work | Branch |
|---|---|
| Shipping app feature or bug fix | `main` |
| Product page / website / website media | `main` |
| Branding, icons, naming, onboarding | `main` |
| Release, signing, Sparkle, distribution | `main` |
| General refactor or reusable infrastructure | `main` |
| Computational Intent Pipeline | `thesis` |
| Thesis-only proactive affordance or experiment | `thesis` |
| Study instrumentation and evaluation | `thesis` |
| Thesis contribution/architecture record | `thesis` |

### Work that benefits both branches

Do not implement the same general fix twice. Use this sequence:

1. Implement and verify the reusable/product part on `main`.
2. Commit it on `main` without a thesis trailer.
3. Merge `main` into `thesis` with a merge commit.
4. Add only the research-specific delta on `thesis`.

If it is unclear whether something is general product work or thesis-only work, stop and ask the user
before editing.

---

## 4. Branch and worktree creation is forbidden by default

Without an explicit user instruction, do **not**:

- create any third branch;
- create another Git worktree;
- copy the repository directory under a new name;
- create an agent-named branch (`codex/*`, `claude/*`, etc.);
- create a temporary branch to move uncommitted work;
- rename or remove an existing branch/worktree.

If `main` or `thesis` is already checked out elsewhere, locate its existing checkout with
`git worktree list` and work there. A worktree path may have a historical name; do not rename it on
your own. Branch identity comes from Git, not the directory name.

### Moving work that started on the wrong branch

Stop first. Inspect both existing worktrees and identify every affected path. Then propose a move to
the user. After approval:

- transfer only the specific files/patches that belong on the target branch;
- preserve all unrelated staged, unstaged, and untracked work;
- verify file hashes or the exact diff before removing the source copy;
- do not create a new branch or worktree as an intermediate container;
- do not commit, drop a stash, or delete anything until the destination is verified.

---

## 5. Keep `thesis` current: merge `main` in

After a relevant Main change or before a Thesis session, sync in this direction only:

```bash
git switch thesis
git merge main
```

Rules:

- Always merge `main` into `thesis`; never rebase `thesis` onto `main`.
- Do not cherry-pick ordinary Main commits into `thesis`; the merge records the real integration
  boundary.
- Do not merge `thesis` into `main` during normal development.
- Do not start a merge while either worktree has overlapping or unexplained uncommitted changes.
- Resolve conflicts by preserving both the current Main behavior and the explicit Thesis delta.

The merge commit itself does not need a `Thesis-Component:` trailer: it records imported Main work,
not a new thesis contribution.

---

## 6. Commit attribution

### Commits on `main`

- Contain only live-product work.
- Never carry a `Thesis-Component:` trailer.
- Must not accidentally include Thesis files or another agent's dirty paths.

### Thesis-only commits on `thesis`

Every non-merge Thesis commit must end with:

```text
Thesis-Component: <short-component-name>
```

Example:

```text
feat(thesis): add passive translation policy

Thesis-Component: affordance-ui
```

This trailer makes the contribution mechanically extractable even though Main commits are regularly
merged into the same branch:

```bash
git log main..thesis --no-merges
git log --grep="Thesis-Component" --no-merges
```

Stage exact files and review the staged diff before committing:

```bash
git diff --cached --stat
git diff --cached
```

---

## 7. GitHub and final integration

`thesis` has one long-lived draft pull request into `main`. Keep it open for the lifetime of the
research work so the examiner can inspect the accumulating diff and commit history.

Only when the user explicitly declares the thesis feature ready for integration:

```bash
git switch main
git merge --no-ff thesis
```

Never squash the thesis branch. Never rebase it before integration. The individual thesis commits,
their trailers, and the final merge boundary are all part of the academic record.

No agent may push either branch, create/close the PR, or perform final integration unless the user
explicitly requests that external action.

---

## 8. Submission tags

At an academic submission or milestone, freeze the exact Thesis state:

```bash
git tag thesis-<name>-submission-<date>
git push origin thesis-<name>-submission-<date>
```

Create and push such a tag only when explicitly requested by the user.

---

## 9. Quick reference

| Task | Command / action |
|---|---|
| Inspect branch and shared state | `git branch --show-current && git status --short --branch && git worktree list` |
| Product/app/website work | Work on `main` |
| Thesis-only research work | Work on `thesis` |
| Sync product changes into Thesis | On `thesis`: `git merge main` |
| List Thesis-only commits | `git log main..thesis --no-merges` |
| Extract attributed Thesis commits | `git log --grep="Thesis-Component" --no-merges` |
| Need another branch/worktree | Stop and ask the user |
| See unexpected dirty files | Stop; do not restore/stash/delete them |
| Final Thesis integration | User-authorised `git merge --no-ff thesis` on `main` |

See `docs/THESIS.md` for the running contribution map and thesis milestone record.
