# Master's Thesis — Contribution Map

This is the **living record** of the master's-thesis work built on top of Dragaway. It exists so
the thesis contribution stays cleanly attributable and gradable, separate from the ongoing
released app. See `docs/GIT_WORKFLOW.md` for the rules that keep it that way.

- **Author:** Moritz Wallbrecher
- **Only thesis branch:** `thesis` (built on top of the released Dragaway `main` branch; branched at v1.1.3)
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

The thesis builds the **Computational Intent Pipeline** — passive OS-level intent inference
surfacing proactive AI affordances. Full technical spec: `docs/thesis/ARCHITECTURE.md`.
Each component below is a `Thesis-Component:` trailer value. All components are developed on the
single `thesis` branch — do not create `thesis/*` component branches (`docs/GIT_WORKFLOW.md` §4).

| Component (`Thesis-Component:` value) | Description | Status | Key files |
|---|---|---|---|
| `infrastructure` | branch/PR/workflow scaffolding, architecture spec | ongoing | `docs/GIT_WORKFLOW.md`, `docs/thesis/ARCHITECTURE.md` |
| `signal-capture` | L1 sensors (clipboard, app focus, dwell/scroll, AX selection), SignalBus, trace recording + replay harness | **M1 done · M2 AX sensor added** | `MacNotchAI/Intent/` |
| `intent-scoring` | L2 feature detectors (8) + L3 log-linear Bayes scorer with editable `IntentConfig`; LLM disambiguator pending (M4) | **in progress (M2 core done)** | `MacNotchAI/Intent/` |
| `affordance-ui` | whisper pill (passive channel), summon ticker (active channel), policy + resolver | planned (M3) | — |
| `personalization` | online weight learning, per-context prior offsets | planned (M4) | — |
| `user-control` | sensitivity tiers, preference compiler (NL → config), onboarding | planned (M4) | — |
| `study-instrumentation` | telemetry schema, study-mode switcher, in-situ prompts, export | planned (M5) | — |

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
