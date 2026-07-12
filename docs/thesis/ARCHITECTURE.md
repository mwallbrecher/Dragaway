# Computational Intent Pipeline — Architecture Specification

**Thesis:** *From Prompting to Intent Recognition: Designing Context-Aware AI Affordances in
Operating-System Workflows* (Kingston University, CI7801)
**Author:** Moritz Wallbrecher · **Host app:** Dragaway (macOS) · **Branch:** `thesis` only
**Status:** living document — this is the architecture deliverable (Objective 2) and the
implementation contract for all `Thesis-Component:` work.

> North star: *infer the need, before it is prompted.* The system observes OS-level interaction
> signals, infers user intent, and surfaces the right AI affordance at the point of intent —
> proactively, on-device, without ever getting in the way.

---

## 1 · Problem decomposition

| # | Sub-problem | Layer |
|---|---|---|
| 1 | **Sensing** — which OS signals are observable, at what permission/CPU cost | L1 |
| 2 | **Representation** — turning a raw event stream into computable evidence | L2 |
| 3 | **Inference** — calibrated `P(intent class | evidence)` | L3 (+L3b) |
| 4 | **Decision & resolution** — *when* to surface *which* concrete action, *how phrased* | L4 |
| 5 | **Learning** — per-user improvement without initial training data | L5 |

**Hard constraint A — silence bias (the Clippy problem).** In the overwhelming majority of
moments the user has *no* assistable intent. The base rate makes even a high-precision
classifier annoying unless the architecture is structurally biased toward silence. This is
enforced mathematically (§5, prior term) and by policy (§7).

**Hard constraint B — on-device + explainability.** UK GDPR / EU AI Act (proposal §5): no
content leaves the device by default, and every suggestion must be *explainable*. This rules
out black-box models in the core path and motivates the log-linear scorer (§5), whose additive
score decomposition **is** the explanation.

---

## 2 · Pipeline overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  L1  SENSORS          Clipboard · AppFocus · Dwell/Scroll · AX-     │
│      (event stream)   Selection (M2) · FileActivity (M2)           │
├─────────────────────────────────────────────────────────────────────┤
│  L2  FEATURES         detectors: ForeignLanguage, ReReading,       │
│      (evidence)       CollectMode, CopySwitchPaste, DenseDwell …   │
├─────────────────────────────────────────────────────────────────────┤
│  L3  SCORER           log-linear Bayes score per intent class      │
│      (P(intent|E))    + personalised weights & priors              │
├─────────────────────────────────────────────────────────────────────┤
│  L3b DISAMBIGUATOR    user-selected LLM — ONLY in the uncertainty  │
│      (optional)       band; votes as one more evidence feature     │
├─────────────────────────────────────────────────────────────────────┤
│  L4  POLICY+RESOLVER  utility threshold θ(tier), cooldowns, quiet  │
│                       contexts; intent → concrete AIAction+phrase  │
├─────────────────────────────────────────────────────────────────────┤
│  L5  AFFORDANCE       whisper pill (passive) + summon ticker       │
│      + FEEDBACK       (active); accept/dismiss/ignore → learning   │
└─────────────────────────────────────────────────────────────────────┘
```

Each layer is independently replaceable (the modularity claim of the proposal). Reused
Dragaway assets: pasteboard polling pattern (`ClipboardHistoryStore`), content heuristics
(`FileSignals`), decayed usage scores (`ActionFrecency`), the 36-action catalog (`AIAction`),
the notch pill (`OverlayViewModel` stages), the provider layer incl. Ollama.

Target intent classes (proposal Objective 2): **Translation/Transformation** (primary MVP),
**Comprehension**, **Discovery/Cross-Reference**.

---

## 3 · L1 — Sensors

| Sensor | API | Permission | Emits |
|---|---|---|---|
| Clipboard | `NSPasteboard.general.changeCount` polling (0.5 s) | none | content-derived scalars (§4) |
| App focus | `NSWorkspace.didActivateApplicationNotification` | none | bundle id, category, dwell-in-previous |
| Scroll | global `NSEvent` monitor `.scrollWheel` | none (pointer events are ungated) | scroll bursts: net Δ, direction changes |
| Mouse dwell | 1 Hz poll of `NSEvent.mouseLocation` | none | stationary periods ≥ 10 s |
| Selection / doc context | Accessibility API (`AXUIElementCopyAttributeValue`: `kAXSelectedText`, `kAXDocument`, `kAXTitle`) | **Accessibility (opt-in)** | selected text scalars, doc path — **M2** |
| File activity | FSEvents / `NSMetadataQuery` | folder TCC | new/changed files — **M2** |

**Permission stance.** The *released* app (main branch) requests zero permissions as of
v1.1.3 and stays that way. The research prototype (this branch) reintroduces **Accessibility
as a transparent opt-in** — it is the *only* permission. `CGEventTap` (named in the proposal)
is deliberately avoided: scroll/dwell work through ungated `NSEvent` APIs, keeping the
permission footprint minimal. Coverage caveat for the write-up: AX selections work in native
apps and Chromium; are flaky in some Electron apps; never in secure fields.

---

## 4 · Event model & the privacy invariant

Sensors emit `SignalEvent` values (Codable, JSONL-serialisable). **The invariant: raw content
never crosses the bus.** Content-derived scalars are computed *at capture time inside the
sensor* and the content is discarded:

- clipboard text → content class, char/word count, top language + confidence,
  `isForeignLanguage`, shape (`prose|code|table|list|question|fragment`), `hasURL`,
  SHA-256 hash prefix (re-copy/dedup detection without content), source app
- sensitive pasteboards are **skipped entirely** via the shared `PasteboardPrivacy` gate
  (concealed · `com.apple.is-sensitive` · transient · auto-generated — the same list the
  clipboard-history feature uses, so the two clipboard paths cannot drift; auto-generated
  is also semantic hygiene: a programmatic write is not a user copy, hence not a signal)
- every event carries its **own timestamp `t`**; all downstream logic MUST use event time,
  never wall clock — this single rule is what makes traces deterministically replayable (§10).
  Sensors stamp at **publish time**, so bus time is monotonic (a DEBUG tripwire guards this;
  scroll bursts accept ≤ ~1.3 s detection latency — <2% decay error at τ ≥ 60 s). The replayer
  **rejects** traces with >1 s time regressions instead of sorting them — order is part of the
  recorded interaction; sub-second regressions are tolerated as clock jitter (`Date()` is not
  monotonic across NTP adjustments).

The `SignalBus` keeps a ring buffer (window 120 s / cap 600 events, trimmed against the
*newest event's* time, not wall clock) for windowed feature extraction; older data exists only
as aggregates.

**Honest classification of what remains:** the bus carries no raw content, but what it does
carry — content hashes, sentence embeddings, app identities, timing — is **content-minimised
behavioural data, not anonymous data**. Embeddings are partially invertible, hashes support
membership tests ("was exactly this text copied?"), and the event stream itself profiles work
behaviour. Consequences: traces stay on-device, count as personal data under UK GDPR (consent +
retention rules, M5), and anonymisation is deliberately **not** claimed anywhere in this design.
Data minimisation is architecture; anonymity would be an overclaim.

---

## 5 · L3 — Scoring: log-linear Bayes

We want `P(c | E)` for each intent class `c`. Naive Bayes in log-odds form turns
multiplication into addition:

```
S_c  =  log P(c)/(1−P(c))  +  Σ_i  w_i · f_i · e^−(t−t_i)/τ_i
        └─────prior────────┘   └──evidence, decayed──────────┘
P(c|E) = σ(S_c) = 1/(1+e^−S_c)
```

- **Weights are log-likelihood-ratios**, not arbitrary knobs: `w_i = log P(e_i|c)/P(e_i|¬c)`.
  `w = +2.2` means "this signal is ~9× more likely under real intent" (`e^2.2 ≈ 9`).
- **The prior enforces silence.** With `P(c) ≈ 0.02`, every hypothesis starts at ≈ **−3.9**;
  evidence must contribute ~4–5 points before anything can surface.
- **Decay is analytic and lazy**: `e^−(t−t_i)/τ` is a pure function of *read time* — scores are
  computed on new events or on demand. **No timers tick for scoring.**
- **Explainability is built in**: each feature's contribution `w_i·f_i·decay` is an additive
  summand; the "why this suggestion?" popover is a printout of the score decomposition.

**Worked example (Translation), as implemented.** Prior −3.9; foreign-language clipboard
(w 2.2 × confidence 0.9, decayed ≈ +1.9); switch toward a translator within 10 s (+3.0)
→ S ≈ +1.0 → P ≈ 0.73 → show (θ=0.70). Foreign copy alone: P ≈ 0.12; translator switch alone:
P ≈ 0.29 → **silence** either way. Earliness (suggesting on the copy alone) is **earned through
personal evidence** (§9), never assumed. Calibration stance: translation signals are
near-deterministic and fire readily; the noisier comprehension/discovery families need
near-max combined evidence to speak unprompted and otherwise surface via the summon ticker.

**Initial parameters** (from the formative-study taxonomy; provenance column required —
every weight cites the observation that motivated it):

| Param | Initial | Notes |
|---|---|---|
| Prior per class | logit(0.02) ≈ −3.9 | + per-context personal offsets (§9) |
| τ clipboard evidence | 60 s | a copy from 5 min ago says nothing |
| τ dwell/scroll evidence | 180 s | reading state decays slower |
| Feature window | 90–120 s | matches ring buffer |
| Weight clamp | ±4 | no single feature may decide alone |

---

## 6 · L3b — The LLM's two narrow jobs

The LLM is **not** the classifier (auditability, latency, the proposal's own risk mitigation:
"rule-based inference removes ML dependency from critical path").

1. **Disambiguation, only in the uncertainty band** `0.45 < P < 0.70`: it receives the
   *structured evidence list* (features, language, content class — no raw content by default)
   and votes; the vote enters the score as one more weighted feature. 2 s timeout → the rule
   decision stands (below θ → silence).
2. **Phrasing** the affordance: turning (intent, context) into the one sentence the user would
   have asked.

**Provider & privacy tiers.** The user's selected provider (BYOK, incl. cloud) is used — not
only local Ollama. Default tier is **metadata-only** (the LLM never sees raw text). A visible,
separate toggle enables the **content tier** (raw snippets for better phrasing) — required
consent stage in the study. The preference compiler (§9) sends *only* the user's typed
preference sentence, never behavioural data.

---

## 7 · L4 — Decision policy

Show iff expected utility exceeds interruption cost: `P·V > (1−P)·C`. Since C is high, the
threshold is high. **Sensitivity tiers set C — they shift the exposure threshold θ only,
never the score.** P stays calibrated and comparable across users and tiers (that makes tier
a post-hoc analysable variable in the logs).

| Tier | θ_show | Rate limit | Semantics |
|---|---|---|---|
| Lazy | 0.85 | 3/h | "only when near-certain" |
| Balanced (default) | 0.70 | 6/h | |
| Aggressive | 0.55 | 12/h | "rather one miss than a missed need" |

Guardrails: per-class dismiss cooldown (10 min) · ignore = auto-fade ~8 s, logged as weak
negative · "do not suggest again" hard mutes per (class × app) · **quiet contexts**: fullscreen,
presentation, **screen sharing**, secure input — never speak. (Known confound to report:
aggressive users generate more feedback → learn faster.)

**Two channels, one scorer.**
- *Passive channel:* unsolicited whisper — gated by θ(tier).
- *Active channel (summon ticker):* a hotkey shows the current top-3 intents with honest
  calibrated confidence — **no threshold**; a solicited suggestion cannot annoy by definition.

The ticker doubles as a measurement instrument: **every summon is a labelled ground-truth
moment** ("user had intent NOW"). A summon while the passive channel stayed silent is a logged
false negative — direct evidence for RQ1 threshold/signal analysis. The candidate buffer also
gives faded suggestions a recovery path.

**Resolver:** intent class + evidence payload → hard mapping into the `AIAction` catalog
(translation intent + text ⇒ Translate with target language from the user profile), then
fine-ranking by embedding similarity (content snippet ↔ action descriptions) + `ActionFrecency`.
Output: `(AIAction, target object, phrased suggestion)`.

---

## 8 · L2 — Feature detectors per class (M2)

| Class | Detector | Core signal |
|---|---|---|
| Translation/Transformation | `foreign_language_clip` | NLLanguageRecognizer: clipboard lang ∉ user languages, 40–2000 chars |
| | `copy_then_translator_switch` | copy → translator/dictionary app or tab within 10 s |
| | `format_mismatch` | clipboard shape (code/table) vs. target-app capability |
| Comprehension | `re_reading` | ≥3 scroll direction changes / 60 s, small net displacement, same doc |
| | `dense_dwell` | mouse-quiet + no app switch + document focused ≥ N s |
| | `repeat_selection` | repeated AX selections in the same paragraph |
| Discovery/Cross-Ref | `collect_mode` | ≥3 copies / 90 s from ≥2 sources |
| | `topic_coherence` | pairwise cosine of snippet embeddings > 0.55 ⇒ one research thread |
| | `copy_to_search` | copy → paste into a search/address field |
| | `entity_overlap` | NLTagger NER: same entities in clipboard and open document |

Embedding backbone: start with Apple `NLEmbedding` (zero deps); the interface is cut so
MiniLM-L6 (CoreML, 384-dim, ~90 MB) is a drop-in. Decide empirically when `topic_coherence`
discriminates too weakly on real traces. Embeddings are computed at capture and cached by
content hash (10–40 ms on Apple silicon).

---

## 9 · L5 — Learning & user control

**The ownership split** (resolves "wouldn't this be learned anyway?"):

```
S_c = Prior_c + Σ w_i f_i
      └─PREFERENCE─┘ └─EVIDENCE─┘
      owned by USER   owned by LEARNER
```

- **Evidence weights `w_i`** ("how reliable is this signal?") belong to the learner. Online
  logistic update after each outcome, in log-odds space:
  `w_i ← w_i + η·(y − P)·f_i` with η = 0.08; accept y=1, dismiss y=0, ignore y=0 at η/4;
  clamp ±4; feedback half-life 14 days (frecency pattern). Plus per-(class × app-context)
  **prior offsets** — the mechanism behind *earned earliness*: repeated accepts in a context
  raise its personal prior until earlier, weaker evidence suffices. Measurable as
  time-to-affordance over sessions.
- **Priors + thresholds per class** ("how often do I *want* to be asked?") belong to the user.
  Explicit control is not redundant with learning: (1) learning needs exposures — low prior +
  lazy tier = cold-start deadlock, a statement breaks it instantly; (2) aspiration ≠ observed
  behaviour; (3) it *is* the "meaningful user control" requirement, concretely.

**`IntentConfig`** — single source of truth, every value provenance-tagged
(`default | onboarding | user-statement | learned`):
`{ tier, prior_offsets[class], cooldowns[class], mutes[(class,app)] }`

**Preference compiler.** Natural-language statement ("ask me about translations more often") →
user-selected LLM receives *only that sentence* + the parameter schema → strict JSON of deltas.
Three safety layers: **whitelist** (unknown keys dropped) · **clamp** (prior offsets ±1.5 ≈
odds ×4.5 max) · **preview diff + undo** before anything applies. Config changes are logged
events (usage of language control is itself a finding). Onboarding uses the same compiler on
2–3 workflow questions, provenance `onboarding`.

---

## 10 · Telemetry, traces, replay — the study is part of the architecture

- **Log everything, including below threshold**: every event writes
  `(t, feature vector, all class scores, decision, outcome?, in-situ rating?)` —
  pseudonymised, on-device, consent-gated. RQ1 ("which signal combinations suffice?") becomes
  an **offline ablation**: re-score logged traces with feature subsets → precision/recall/AUC
  per combination, no new sessions needed.
- **Traces** are JSONL files of `SignalEvent`s (schema §4). The formative observation sessions
  are encoded as traces too — the interview keyframes literally become regression tests.
- **Replay harness**: feed a trace through the pipeline deterministically (possible because
  all logic uses event time, §4). Golden traces = unit tests for intent detection; every
  threshold experiment is exactly reproducible.
- **Study modes** (RQ2, within-subjects): condition switcher A: chat-mediated · B: drag
  (today's Dragaway) · C: intent-mediated. Logged outcomes: accepted / dismissed / ignored +
  task timings; **in-situ prompts** ("helpful? intrusive?") after each affordance interaction,
  skippable, non-blocking.

---

## 11 · Milestones & acceptance

| M | Scope | Accept when |
|---|---|---|
| **M1** | SignalBus, Clipboard/AppFocus/Dwell sensors, trace recorder + replayer, engine flag + debug menu | a recorded real session replays with identical event stream; zero permissions used |
| **M2** | AX sensor (opt-in), feature detectors, scorer + `IntentConfig`, weights tuned on own traces | golden smoke checks (debug menu → Run Golden Checks) all pass; "why" decomposition available |
| **M3** | whisper affordance + policy + resolver (Translation e2e) + summon ticker. **Passive channel fires for translation only** — comprehension/discovery stay ticker-only until calibrated on real traces | translation scenario works end-to-end passively and via summon |
| **M4** | online learning, context priors, preference compiler, onboarding, LLM disambiguator/phrasing | preference statement changes behaviour with preview+undo |
| **M5** | study mode switcher, in-situ prompts, consent gates, export | pilot session produces analysable RQ1/RQ2 dataset |

**Component ↔ `Thesis-Component:` trailer map:** `infrastructure` (workflow/docs) ·
`signal-capture` (L1, traces, replay) · `intent-scoring` (L2/L3/L3b) · `affordance-ui` (L4/L5
surfaces) · `personalization` (learning, priors) · `user-control` (tiers, compiler, onboarding)
· `study-instrumentation` (telemetry, study modes).

## 12 · Open decisions

1. **Embedding backbone** — NLEmbedding vs. MiniLM-CoreML; decide on real-trace discrimination
   of `topic_coherence` (§8).
2. **Ticker hotkey & exact whisper visuals** — decide in M3 with the UI work.
