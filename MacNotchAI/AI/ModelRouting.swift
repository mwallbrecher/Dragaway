import Foundation

// Deterministic, no-extra-LLM-call routing policy. See docs/HOW_LLM_IS_CHOSEN.md.
//
// Priority order (from the spec):
//   1. minimise the operator's API bill   → default to the cheapest CAPABLE model
//   2. per-user token caps are a relief valve, not a hard requirement
//
// Two levers come out of this file:
//   • `maxOutputTokens` — a RUNAWAY GUARD (you pay for tokens emitted, so a ceiling
//     only saves money when a model loops to the cap). Applied by every provider.
//   • `tier` — which model to use. The hosted Worker maps `tier → model`
//     (fast → gemini-2.5-flash-lite, strong → gemini-2.5-flash, extra → gemini-2.5-pro
//     for Pro only). BYOK providers use a fixed model per provider, so tier is a no-op.
//
// The `tier` for the 17 built-in actions is decided ENTIRELY by their task class — a
// deterministic switch, no text analysis, no keywords. The single fuzzy case is a
// typed custom prompt, handled by `forCustomPrompt` below.

/// Which model the router asks the Worker for.
/// - `fast`        = the cheap model for mechanical, bounded work.
/// - `strong`      = the capable default wherever judgement/reasoning matters.
/// - `extraStrong` = the top model, **Pro only**, reserved for the few genuinely hard
///   tasks (tiny whitelist below) and the manual "Go deeper" escalation. Free devices
///   degrade it to `strong` on the Worker — they never reach the pricey model.
///
/// Unknown/missing tier on the Worker falls back to `strong` (never silently cheaper).
/// The raw values are the wire contract with the Worker's `pickModel`.
enum AITier: String {
    case fast
    case strong
    case extraStrong = "extra"
}

/// Coarse task family, derived deterministically from the action — no LLM call.
/// Drives both the tier and the output ceiling.
enum AITaskClass {
    case extraction      // pull structured facts — bounded list output
    case summarisation   // compress — short output
    case transformation  // translate / rephrase / docstring — output ≈ input
    case explanation     // explain / review code — needs reasoning
    case vision          // image in — describe / OCR / alt text
    case evaluation      // judgement / argue / prove
    case freeform        // typed custom prompt
}

/// The deterministic routing decision for one request.
struct RoutingPlan {
    let tier: AITier
    let taskClass: AITaskClass
    /// Ceiling on generated tokens. A SAFETY GUARD, not a target: you pay for tokens
    /// actually emitted, so this only saves money when the model runs away. Tight for
    /// bounded output; generous where output ≈ input (capping those truncates real work).
    let maxOutputTokens: Int
}

extension AIAction {
    /// Static routing plan for a built-in action. The intent is already known, so no
    /// classification is needed (doc §3). Mechanical/bounded tasks → `.fast` (cheap
    /// model); anything needing reasoning → `.strong`. For `.freeform`, prefer
    /// `RoutingPlan.forCustomPrompt(_:)`.
    var routing: RoutingPlan {
        switch self {
        // ── Extraction: mechanical, bounded list output → cheap model ─────────
        case .extractKeyDates, .extractKeyPoints:
            return RoutingPlan(tier: .fast, taskClass: .extraction, maxOutputTokens: 512)

        // ── Summarisation: mechanical, short output → cheap model ─────────────
        case .summariseShort:
            return RoutingPlan(tier: .fast, taskClass: .summarisation, maxOutputTokens: 120)
        case .summariseBullets:
            return RoutingPlan(tier: .fast, taskClass: .summarisation, maxOutputTokens: 512)

        // ── Transformation: mechanical, output ≈ input → cheap model ──────────
        case .translateEnglish, .translateGerman, .translateFrench, .translateSpanish,
             .rephraseFormal, .rephraseCasual, .addDocstring, .proofread:
            return RoutingPlan(tier: .fast, taskClass: .transformation, maxOutputTokens: 4096)

        // ── Data extraction / description: bounded structured output → cheap ──
        case .extractTodos, .extractContacts, .describeData:
            return RoutingPlan(tier: .fast, taskClass: .extraction, maxOutputTokens: 768)
        case .summariseTable:
            return RoutingPlan(tier: .fast, taskClass: .summarisation, maxOutputTokens: 512)

        // ── Data reasoning: judgement over numbers → capable model ────────────
        case .showTrends, .findOutliers, .suggestCharts:
            return RoutingPlan(tier: .strong, taskClass: .explanation, maxOutputTokens: 768)

        // ── Generative prose: reply / report / brief / social → capable model ─
        case .draftReply, .explainSimply, .makeReport, .slideOutline,
             .linkedinPost, .turnIntoBrief:
            return RoutingPlan(tier: .strong, taskClass: .explanation, maxOutputTokens: 1536)

        // ── Vision reasoning: UI critique / design spec → capable model ───────
        case .analyseUI, .designReference:
            return RoutingPlan(tier: .strong, taskClass: .vision, maxOutputTokens: 1024)
        case .rebuildHTML:
            // Vision + a full code emit → capable model, generous ceiling.
            return RoutingPlan(tier: .strong, taskClass: .vision, maxOutputTokens: 4096)

        // ── Explanation: flash is plenty capable → capable model ──────────────
        case .explainCode:
            return RoutingPlan(tier: .strong, taskClass: .explanation, maxOutputTokens: 1024)
        case .writeTests:
            return RoutingPlan(tier: .strong, taskClass: .explanation, maxOutputTokens: 1536)

        // ── Deep code reasoning: the FEW tasks worth the top model (Pro only;
        //    free degrades to strong). Kept deliberately tiny — everything else
        //    reaches the top model only via the manual "Go deeper" escalation. ──
        case .findBugs, .refactor:
            return RoutingPlan(tier: .extraStrong, taskClass: .explanation, maxOutputTokens: 1024)

        // ── Vision ────────────────────────────────────────────────────────────
        case .generateAltText:
            // Short, mechanical caption → cheap model.
            return RoutingPlan(tier: .fast, taskClass: .vision, maxOutputTokens: 120)
        case .extractTextFromImage:
            // OCR is mechanical; output ≈ text in the image, so give headroom.
            return RoutingPlan(tier: .fast, taskClass: .vision, maxOutputTokens: 4096)
        case .describeImage:
            // A rich description benefits from the capable model.
            return RoutingPlan(tier: .strong, taskClass: .vision, maxOutputTokens: 1024)

        // ── Freeform: the safe default is the capable model ───────────────────
        case .freeform:
            return RoutingPlan(tier: .strong, taskClass: .freeform, maxOutputTokens: 1536)
        }
    }
}

extension RoutingPlan {
    /// Copy with a different tier — used by the manual "Go deeper" escalation to force
    /// `.extraStrong` while keeping the action's task class and output ceiling.
    func with(tier newTier: AITier) -> RoutingPlan {
        RoutingPlan(tier: newTier, taskClass: taskClass, maxOutputTokens: maxOutputTokens)
    }

    /// Router for a typed custom prompt — **prompt text only**, never the document.
    ///
    /// The FLOOR is the capable model (`AIAction.freeform.routing`, tier `.strong`): if
    /// this function did nothing, every custom prompt would just use flash and be fine.
    /// The keyword list below is a NON-LOAD-BEARING optimisation — it may only DOWNGRADE
    /// an obviously trivial, short, mechanical prompt to the cheap tier. It can never
    /// decide quality: a miss costs at most a little money (cheap→capable would've been
    /// right), never a bad answer. Delete it and freeform reverts to always-flash.
    static func forCustomPrompt(_ prompt: String) -> RoutingPlan {
        let floor = AIAction.freeform.routing          // tier .strong (capable / flash)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Clearly mechanical asks that the cheap model handles well. Kept short and
        // conservative on purpose — only fires on brief, single-intent prompts.
        let trivialSignals = [
            "translate", "tl;dr", "tldr", "spell check", "fix typos",
            "list the", "what is the date", "word count",
        ]
        let looksTrivial = trimmed.count <= 80 && trivialSignals.contains { lower.contains($0) }

        if looksTrivial {
            return RoutingPlan(tier: .fast, taskClass: .freeform,
                               maxOutputTokens: floor.maxOutputTokens)
        }
        return floor
    }
}
