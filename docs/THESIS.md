# Master's Thesis — Contribution Map

This is the **living record** of the master's-thesis work built on top of Dragaway. It exists so
the thesis contribution stays cleanly attributable and gradable, separate from the ongoing
released app. See `docs/GIT_WORKFLOW.md` for the rules that keep it that way.

- **Author:** Moritz Wallbrecher
- **Only thesis branch:** `thesis` (built on top of the released Dragaway `main` branch)
- **Draft PR:** _(link added when opened: `thesis` → `main`)_
- **Every thesis commit carries the trailer** `Thesis-Component: <name>` so it can be extracted
  mechanically at any time:
  ```bash
  git log --grep="Thesis-Component" --no-merges
  git log main..thesis --no-merges          # thesis commits not yet in main
  ```

---

## Thesis features / components

The thesis comprises **several larger components**, but all of them are developed on the single
`thesis` branch. Do not create `thesis/*` component branches. The live Thesis branch carries the
detailed contribution map; this Main copy is the baseline template.

| Component (`Thesis-Component:` value) | Description | Status | Branch | Key files |
|---|---|---|---|---|
| _(tbd)_ | _first feature — fill in when we start it_ | planned | `thesis` | — |

---

## Submission milestones

Frozen with tags (`git tag thesis-<name>-submission-<date>`):

| Tag | Date | What it captures |
|---|---|---|
| _(none yet)_ | — | — |

---

## How the thesis relates to the released app

The released app (`main`) contains **all normal product development**: the installed app, product
page/website, branding and icons, bug fixes, features, and releases. The `thesis` branch merges
`main` in regularly (never rebases), so those Main-owned files also appear in the Thesis working
tree. Their presence there does not make them thesis work; attribution follows their originating
Main commits.

Only research-specific deltas are committed directly on `thesis`, with `Thesis-Component:` trailers.
The completed thesis integrates back into `main` only after explicit user approval, using a true
`--no-ff` merge and never a squash.
