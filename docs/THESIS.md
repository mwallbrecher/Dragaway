# Master's Thesis — Contribution Map

This is the **living record** of the master's-thesis work built on top of Dragaway. It exists so
the thesis contribution stays cleanly attributable and gradable, separate from the ongoing
released app. See `docs/GIT_WORKFLOW.md` for the rules that keep it that way.

- **Author:** Moritz Wallbrecher
- **Integration branch:** `thesis` (branched from `main` at Dragaway v1.1.3 — the released app)
- **Draft PR:** https://github.com/mwallbrecher/Dragaway/pull/1 (`thesis` → `main`, keep as draft until done)
- **Status:** active — thesis work has started.
- **Every thesis commit carries the trailer** `Thesis-Component: <name>` so it can be extracted
  mechanically at any time:
  ```bash
  git log --grep="Thesis-Component" --no-merges
  git log main..thesis --no-merges          # thesis commits not yet in main
  ```

---

## Thesis features / components

The thesis comprises **several larger features**. Each is a component below; larger ones may get
their own short-lived `thesis/<feature>` branch off `thesis`, merged back with `--no-ff`.

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

The released app (`main`) keeps shipping small features and bugfixes via Sparkle auto-update.
The `thesis` branch **merges `main` in regularly** (never rebases) so the thesis work always
builds on the current app rather than a stale fork. When a thesis feature is complete it merges
back to `main` with a true merge commit (`--no-ff`, never squash), preserving every commit.
