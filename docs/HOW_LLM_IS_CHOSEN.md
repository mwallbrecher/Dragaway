# How AI Drop Chooses an LLM — Engineering Spec

> Status: spec + partial implementation. Goal priority: **(1) minimise the operator's API
> bill** (the free tier runs on our Worker, on our money), **(2) per-user token limits**
> are a *relief valve*, not a hard requirement — we'd rather a user hit their cap early
> than have us overspend.

---

## 1. The cost model (read this first)

Per request you are billed:

```
cost = input_tokens × price_in  +  output_tokens × price_out
```

Two facts that drive everything below:

1. **`max_tokens` is a CEILING, not a target.** You pay for tokens the model *actually
   generates*. A well-behaved "summarise in one sentence" emits ~30 tokens whether the
   cap is 200 or 4096. So lowering `max_tokens` only saves money when the model would
   otherwise **run away** (loop/ramble to the cap). It's a *safety guard*, not a primary
   lever.
2. **For document tasks, input dominates.** A 12k-char PDF ≈ 3k input tokens; a typical
   answer is a few hundred output tokens. On a multi-turn chat we currently **re-send the
   whole document every turn**, so input cost scales with turn count.

Therefore the only two reliable levers on the bill are:

| Lever | Mechanism | Cuts operator bill | Cuts per-user token count |
|---|---|---|---|
| **$/token** | route to a cheaper model | ✅ (biggest) | ❌ (same tokens, cheaper) |
| **token count** | prompt caching, input trimming, output ceiling | ✅ | ✅ |

Model routing is the highest-impact lever for the bill — but it only applies where **we
choose the model**, i.e. the hosted Worker. BYOK users choose an exact provider/model
pair; any price/quality trade-off there is explicit and belongs to them, not us.

---

## 2. Where each decision lives

- **Hosted (free/Pro) tier → the Worker decides.** The client sends the action, file
  metadata, input size, and a suggested tier/output budget; the Worker picks the actual
  model and owns the key. This is where the bill is won.
- **BYOK tier → the user decides exactly.** `AIModelCatalogStore` loads the account's
  live models from the provider, caches them for 24 hours, and persists one exact model
  ID per provider. Every direct request sends that ID unchanged. A missing model is shown
  as unavailable and errors explicitly; it is never replaced silently. Catalogue and
  completion calls use the same API surface (for example, Gemini's OpenAI-compatible
  `/models` list feeds its OpenAI-compatible Chat Completions route).

The client still computes a **routing plan** from the action on every request
(`AI/ModelRouting.swift`). `maxOutputTokens` is used by every route; `tier` chooses a
model only on the hosted Worker and is deliberately ignored by BYOK providers.

---

## 3. Signals (cheap, deterministic — no extra LLM call)

For **built-in actions** the intent is already known — map directly, no classification:

- `extract*`, OCR → extraction (fast tier)
- `translate*`, `rephrase*`, `addDocstring` → transformation, output ≈ input length
- `summarise*`, `describeImage`, `generateAltText` → summarisation (fast tier)
- `explainCode`, `findBugs`, `refactor` → explanation (fast→balanced)
- evaluation / "is this correct / review / argue" → strong tier
- `freeform` (typed prompt) → balanced default

For **custom prompts**, classify with a **heuristic first** (length, keyword match for
"why/evaluate/compare/prove/review"), and only fall back to a tiny classifier call when
genuinely ambiguous. **Never feed the document to the router** — prompt text only. An
extra round-trip adds latency and cost, so avoid it on the common path.

---

## 4. The routing rule *(implemented — `AI/ModelRouting.swift`)*

- **Default to the cheapest capable model.** Bill priority means the floor, not the
  ceiling, is the default.
- Extraction / formatting / short summary / translation → **fast** model, reasoning off.
- Explanation / code review → **strong** (these need judgement; the saving isn't worth a
  wrong answer).
- Evaluation / judgement / freeform / rich image description → **strong** model.

Three hosted tiers (`fast`, `strong`, `extra`). The Worker maps them to concrete models:
`fast → gemini-2.5-flash-lite`, `strong → gemini-2.5-flash`, `extra → gemini-2.5-pro`.
Do **not** build a 6-way model matrix you can't tune.

**`extra` is the Pro-only top model, used sparingly.** Free and Pro see the *same*
models on `fast`/`strong` (Pro's everyday win is the larger content cap, not a better
model). `extra` is reserved for the few genuinely hard tasks and fires only two ways:

1. **A tiny client whitelist** — `findBugs` / `refactor` carry tier `.extraStrong` in
   `AIAction.routing` (deep code reasoning, where the frontier model most clearly beats
   flash). Keyword-free (keyed off the action enum). Deliberately small — add/remove a
   `case` to tune.
2. **Manual "Go deeper"** — a Pro-only, hosted-only button in the result view re-answers
   the current turn forced to `.extraStrong` (`RoutingPlan.with(tier:)` + `regenerate`).
   The *human* decides "really necessary", so the pricey model fires only on demand.

The trust + fail-safe model is unchanged and server-enforced: the Worker resolves tier→
model knowing the device is server-verified Pro (`accounts.pro`). A free device's `extra`
**degrades to `strong`** — it can never reach the pricey model. `GEMINI_MODEL_EXTRA` is
optional and defaults to flash, so enabling the tier can't *silently* jump cost, and any
unknown/missing tier still resolves to the capable default. A client can request a *tier*
but never a *model* — keep it that way.

**How the tier is chosen — and why it can't pick wrong-expensive-quietly:**

1. **The 17 built-in chips: a deterministic `switch`, zero keywords.** `AIAction.routing`
   maps each action's *task class* to a tier. The intent is already known the moment the
   user taps the chip, so there's nothing to guess. It's a `switch` over a Swift enum —
   total (the compiler forces every case) and it physically cannot throw or fall through.
2. **The one fuzzy case (a typed custom prompt): flash is the FLOOR, keywords can only
   downgrade.** `RoutingPlan.forCustomPrompt` starts from `.freeform` (= `.strong` / flash)
   and the keyword list may only *drop* an obviously-trivial, short, single-intent prompt
   to the cheap tier. A keyword miss therefore costs at most a few cents (we ran flash when
   flash-lite would've sufficed) — it can **never** produce a bad answer. Delete the
   keyword list entirely and freeform reverts to always-flash. That's the "we don't rely on
   it" guarantee: the heuristic is a money optimisation bolted *on top of* a correct floor,
   never the thing deciding quality.
3. **The Worker treats `tier` as an UNTRUSTED hint.** `pickModel` only honours an explicit
   `"fast"`; anything missing, unknown, or malformed → the capable default. So a garbled or
   absent tier degrades **cost**, never quality.
4. **Model-level retry.** If the routed (cheap) model call fails, the Worker retries once
   on the capable default before surfacing an error — the user gets an answer, not a 502.
5. **Output ceiling + Gemini thinking-headroom underneath** (§5) catch a model that runs
   away or starves its visible answer.

The asymmetry is deliberate: every failure mode biases toward **cheap**, because
wrong-cheap is recoverable (slightly worse answer) while wrong-expensive spends the
operator's money silently. Nothing in the path can keyword-match its way into the
expensive model.

---

## 5. Output ceilings (implemented — runaway guard)

Per-action `max_tokens` ceilings live in `AIAction.routing.maxOutputTokens`
(`AI/ModelRouting.swift`) and are plumbed through
`AIProvider.reply(messages:imageURL:maxOutputTokens:)` to all six providers
(replacing the flat hardcoded `4096`). `sendTurn` computes the plan per request: a chip
uses its action's static plan; a typed prompt routes through
`RoutingPlan.forCustomPrompt` (keyword/length heuristic, prompt text only). These are
**safety caps** against a looping model burning a paid key, not a primary saving:

- short/bounded output (1-sentence summary, alt text, key dates/points) → tight ceiling
- output ≈ input (translate, rephrase, add-docstring) → generous ceiling (~4k); capping
  these truncates legitimate output
- OCR / describe / explain / freeform → mid ceilings

**Gemini caveat:** on Google's OpenAI-compat endpoint, "thinking" tokens count against
`max_tokens`. When the live model metadata reports thinking support, the Gemini provider
adds reasoning headroom and a floor on top of the requested ceiling (with
`reasoning_effort: low`) so a tight cap can't starve the visible answer. Non-thinking
models receive the plain safety ceiling.

---

## 6. Input reduction (next, biggest real bill win after routing)

1. **Prompt caching of the document prefix.** *(implemented for the chat subset.)* On
   multi-turn we replay the document each turn. The document now rides on the first user
   turn as a **separate, stable block** (`ChatTurn.cacheableDocument`, built in
   `buildChatTurns`) instead of being glued into the instruction text. Anthropic marks
   that block with explicit `cache_control: ephemeral` (~90% off cached reads, 5-min TTL),
   guarded by a ~2048-token (`cacheMinChars`) floor since Haiku won't cache below it.
   OpenAI and Gemini cache long leading prefixes **automatically** — they need no marker,
   only the stable prefix, which `flattenedContent` preserves byte-for-byte. Biggest lever
   for the chat subset; single-shot drops don't benefit (the first turn pays a ~25% cache
   *write* premium, recovered on the first follow-up).
2. **Per-action input trimming.** Image-only actions (`describeImage`, OCR, alt text)
   must **not** ship the extracted-text document at all. For text actions, keep the
   existing global page/char cap; trimming further risks correctness (you can't know which
   page holds the answer).

---

## 7. Structured extraction + validated escalation (extraction only)

For `extract*`, request **structured JSON** and validate cheaply with **no extra LLM
call**: required fields present, and each `source` string actually appears in the
document (plain substring search). Example:

```json
{ "dates": [ { "date": "2026-05-31", "label": "submission deadline",
               "source": "The deadline is May 31, 2026." } ] }
```

Only **escalate to a stronger model when failure is detectable for free** (extraction
validation, or a truncated/empty response). Do **not** escalate on subjective tasks — you
can't judge quality without paying for a second call, and a retry means paying for *both*
attempts. Escalation is a quality safeguard, not a saving; keep its trigger rate low.

---

## 8. Instrumentation (prerequisite for tuning)

Extend `UsageStore` to log per call: `{ action, tier, model, input_tokens,
output_tokens, retried, latency }`. Thresholds in §3–§7 are guesses until there's data;
route on measurements, not vibes. Per-user limits should meter in **normalised
cost-credits** (model-weighted), not raw tokens, so a Haiku turn and a Flash turn debit
fairly.

---

## 9. Implementation order (by ROI for the bill)

1. **Worker model routing** — *done.* Tier per task class (`AI/ModelRouting.swift`),
   `tier → model` map + untrusted-hint fallback + cheap→capable retry in the Worker
   (`worker/src/index.js`, `pickModel`). **Requires `wrangler deploy` to go live.**
2. **Prompt caching** of the document prefix (Anthropic explicit; OpenAI/Gemini auto) —
   *done.*
3. **Output ceilings** per action — *done* (runaway guard + Worker scaffolding).
4. **Input trimming** — drop the doc for image-only actions.
5. **Validated escalation** for extraction only.
6. **Usage instrumentation** to tune 1–5.

---

## 10. Product principle

Hosted Dragaway should remain effortless: drop the file, pick the action, and let the
server choose the cheapest reliable tier. BYOK is intentionally different: the user can
see and choose the exact model they pay for, and Dragaway must never change that choice
quietly.
