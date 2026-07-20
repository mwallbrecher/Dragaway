import Foundation

enum AIAction: String, CaseIterable, Identifiable {
    // Document actions
    case summariseBullets   = "Summarise into Bullets"
    case summariseShort     = "Summarise in 1 Sentence"
    case extractKeyDates    = "Extract Key Dates"
    case extractKeyPoints   = "Extract Key Points"
    case translateEnglish   = "Translate to English"
    case translateGerman    = "Translate to German"
    case translateFrench    = "Translate to French"
    case translateSpanish   = "Translate to Spanish"
    case rephraseFormal     = "Rephrase Formally"
    case rephraseCasual     = "Rephrase Casually"

    // Code actions
    case explainCode        = "Explain This Code"
    case findBugs           = "Find Bugs"
    case addDocstring       = "Add Documentation"
    case refactor           = "Suggest Refactoring"
    case writeTests         = "Write Tests"

    // Image actions
    case describeImage          = "Describe Image"
    case extractTextFromImage   = "Extract Text (OCR)"
    case generateAltText        = "Generate Alt Text"
    case analyseUI              = "Analyse UI"
    case designReference        = "Design Reference"
    case rebuildHTML            = "Rebuild as HTML/CSS"

    // Data / CSV actions
    case summariseTable         = "Summarise Table"
    case describeData           = "Describe the Data"
    case showTrends             = "Show Trends"
    case findOutliers           = "Find Outliers"
    case suggestCharts          = "Suggest Charts"
    case makeReport             = "Make a Report"

    // Text / productivity actions
    case summariseEmail         = "Summarise Email"
    case emailNextSteps         = "What Do I Need to Do?"
    case emailDeadlinesRisks    = "Deadlines & Risks"
    case draftReply             = "Draft Email Reply"
    case emailQuestions         = "Questions to Answer"
    case extractTodos           = "Extract To-Dos"
    case extractContacts        = "Extract Names & Contacts"
    case explainSimply          = "Explain Simply"
    case proofread              = "Proofread & Fix"

    // Notes / creation actions (txt/md content flavour)
    case slideOutline           = "5-Slide Outline"
    case linkedinPost           = "Write LinkedIn Post"
    case turnIntoBrief          = "Turn into a Brief"

    // Free-form follow-up — used when the user types a custom question
    // in the prompt field. System prompt deliberately stays neutral so the
    // AI answers the question instead of applying a fixed transformation.
    case freeform               = "Custom Query"

    var id: String { rawValue }

    /// SF Symbol shown to the left of the action in its menu-style row (the chips-stage
    /// Suggested/Utilities lists + the result-stage Suggested rail / follow-ups). All
    /// picked from symbols available on the macOS 14 deployment target.
    var icon: String {
        switch self {
        case .summariseBullets:     return "list.bullet"
        case .summariseShort:       return "text.alignleft"
        case .extractKeyDates:      return "calendar"
        case .extractKeyPoints:     return "list.number"
        case .translateEnglish:     return "globe"
        case .translateGerman:      return "globe"
        case .translateFrench:      return "globe"
        case .translateSpanish:     return "globe"
        case .rephraseFormal:       return "briefcase"
        case .rephraseCasual:       return "bubble.left"
        case .explainCode:          return "chevron.left.forwardslash.chevron.right"
        case .findBugs:             return "ladybug"
        case .addDocstring:         return "text.quote"
        case .refactor:             return "arrow.triangle.2.circlepath"
        case .writeTests:           return "checkmark.seal"
        case .describeImage:        return "photo"
        case .extractTextFromImage: return "doc.text.viewfinder"
        case .generateAltText:      return "text.below.photo"
        case .analyseUI:            return "macwindow"
        case .designReference:      return "paintpalette"
        case .rebuildHTML:          return "curlybraces"
        case .summariseTable:       return "tablecells"
        case .describeData:         return "tablecells.badge.ellipsis"
        case .showTrends:           return "chart.line.uptrend.xyaxis"
        case .findOutliers:         return "exclamationmark.triangle"
        case .suggestCharts:        return "chart.bar.xaxis"
        case .makeReport:           return "doc.richtext"
        case .summariseEmail:       return "envelope.open"
        case .emailNextSteps:       return "checklist"
        case .emailDeadlinesRisks:  return "exclamationmark.triangle"
        case .draftReply:           return "arrowshape.turn.up.left"
        case .emailQuestions:       return "questionmark.bubble"
        case .extractTodos:         return "checklist"
        case .extractContacts:      return "person.crop.circle"
        case .explainSimply:        return "lightbulb"
        case .proofread:            return "text.badge.checkmark"
        case .slideOutline:         return "rectangle.on.rectangle.angled"
        case .linkedinPost:         return "text.bubble"
        case .turnIntoBrief:        return "doc.text.magnifyingglass"
        case .freeform:             return "sparkles"
        }
    }

    var systemPrompt: String {
        switch self {
        case .summariseBullets:
            return "Summarise the following content into concise bullet points. Be brief and extract only the most important information."
        case .summariseShort:
            return "Summarise the following content in exactly one sentence."
        case .extractKeyDates:
            return "Extract all dates, deadlines, and time references from the following content. Present them as a clean list."
        case .extractKeyPoints:
            return "Extract the 5 most important key points from the following content as a numbered list."
        case .translateEnglish:
            return "Translate the following text to English. Preserve formatting."
        case .translateGerman:
            return "Translate the following text to German. Preserve formatting."
        case .translateFrench:
            return "Translate the following text to French. Preserve formatting."
        case .translateSpanish:
            return "Translate the following text to Spanish. Preserve formatting."
        case .rephraseFormal:
            return "Rephrase the following text in formal, professional English."
        case .rephraseCasual:
            return "Rephrase the following text in casual, friendly English."
        case .explainCode:
            return "Explain what this code does in plain English. Use bullet points for each major component."
        case .findBugs:
            return "Analyse this code and identify any bugs, errors, or potential issues. List each issue with a brief explanation."
        case .addDocstring:
            return "Add clear documentation comments/docstrings to this code. Return the full code with documentation added."
        case .refactor:
            return "Suggest concrete refactoring improvements for this code. Explain each suggestion briefly."
        case .writeTests:
            return "Write unit tests for this code covering the main paths and important edge cases. Use the language's conventional test framework. Return only the test code in one code block."
        case .describeImage:
            return "Describe this image in detail."
        case .extractTextFromImage:
            return "Extract and transcribe all text visible in this image."
        case .generateAltText:
            return "Write concise, descriptive alt text for this image suitable for accessibility."
        case .analyseUI:
            return "Analyse this UI screenshot: layout, visual hierarchy, spacing, typography, colour, and usability. Give concrete, prioritised improvement suggestions as a short list."
        case .designReference:
            return "From this screenshot, extract a design reference spec: the dominant colours (hex), the type styles (approximate font family, sizes, weights), spacing/rhythm, corner radii, and notable component styles. Present it concisely."
        case .rebuildHTML:
            return "Rebuild this UI as a single self-contained HTML file with inline CSS that closely matches the layout, colours, and typography shown. Return only the code inside one ```html code block."
        case .summariseTable:
            return "Summarise this table/CSV: what it contains, its key columns, and the main takeaways. Be concise and use bullet points."
        case .describeData:
            return "Describe this dataset: number of rows and columns, what each column represents, the data type of each, and any obvious gaps or quality issues. Present it as a short structured overview."
        case .showTrends:
            return "Identify the main trends, patterns, and notable changes in this data. Explain briefly what each suggests. Use bullet points."
        case .findOutliers:
            return "Find outliers, anomalies, and suspicious values in this data. For each, note the row or value and explain why it stands out."
        case .suggestCharts:
            return "Recommend which chart types best visualise this data and why. For each: name the chart, the columns to map (x / y / series), and what it would reveal. Do not attempt to draw the chart."
        case .makeReport:
            return "Write a short structured report on this data: an overview, key findings as bullet points, and a brief conclusion. Use Markdown headings."
        case .summariseEmail:
            return "Summarise this email for its recipient. Cover the sender's purpose, the key information or decisions, any requests, and the context needed to act. Keep it concise, do not draft a reply, and do not invent details."
        case .emailNextSteps:
            return "Identify exactly what the recipient needs to do after reading this email. Put required actions first, then clearly implied or optional actions. For each item include the owner, deadline, dependency, and requested response when stated. If no action is needed, say so clearly. Do not invent tasks."
        case .emailDeadlinesRisks:
            return "Analyse this email for deadlines, dated commitments, blockers, risks, dependencies, and important ambiguity. Separate explicit facts from reasonable risks or uncertainties, cite the relevant evidence briefly, and say clearly when none are present. Do not invent dates or commitments."
        case .draftReply:
            return "Draft a clear, professional reply to this email or message. Use an appropriate tone, address the key points, and keep it concise."
        case .emailQuestions:
            return "List every explicit question in this email plus any clearly implied request for information or a decision. Group them into questions to answer and decisions to make, preserving enough context to respond. If there are none, say so clearly. Do not draft the reply or invent questions."
        case .extractTodos:
            return "Extract every action item, task, and to-do from this content as a checklist. Include any owner or deadline mentioned next to each item."
        case .extractContacts:
            return "Extract all people, organisations, and contact details (emails, phone numbers, handles) mentioned in this content. Present them as a clean grouped list."
        case .explainSimply:
            return "Explain this content in simple, plain language that a non-expert can understand. Avoid jargon and use short sentences."
        case .proofread:
            return "Proofread this text and return a corrected version fixing grammar, spelling, punctuation, and clarity. Preserve the original meaning, tone, and formatting — do not rewrite the style."
        case .slideOutline:
            return "Turn this content into a 5-slide presentation outline. For each slide give a short title and 2–4 concise bullet points."
        case .linkedinPost:
            return "Write an engaging LinkedIn post based on this content: a strong opening hook, a few short paragraphs, and a closing line or question. Keep it professional but personable; a few tasteful emoji are fine."
        case .turnIntoBrief:
            return "Turn this content into a clear one-page brief with these Markdown sections: Objective, Background, Key Points, and Next Steps."
        case .freeform:
            return "You are a helpful document assistant. The user's message contains a question followed by the document content. Answer the question accurately and concisely using the document as context. Do not summarise unless asked."
        }
    }
}
