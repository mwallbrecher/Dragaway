# Dragaway Privacy & Data Handling

*Plain-language technical overview — last reviewed July 2026*

Dragaway is designed to keep data movement understandable and minimal. Most preparation happens
locally on the Mac, and an AI request is sent only when the user chooses an AI action. This document
explains what stays local, what leaves the device, and where the limits of those guarantees are.

## The short version

- With **Bring Your Own Key (BYOK)**, AI requests go directly from the Mac to the provider and model
  selected by the user. Document content, prompts, responses, and API keys are not routed through or
  stored on Dragaway infrastructure.
- With the **hosted Free/Pro service**, the request passes through Dragaway's metering service and is
  forwarded to Gemini. The service stores usage information such as a pseudonymous device ID, call
  counts, model tier, and token totals — not document content, prompts, or AI responses.
- Files are prepared locally before an AI request. Images sent to a vision model are included in that
  provider request.
- API keys are stored in the macOS Keychain.
- Network requests use HTTPS. This protects their contents in transit from ordinary network
  observers, but no application can truthfully promise that data is unreadable to the chosen
  provider, a managed company proxy, or a compromised device.

## Local file processing

Dragaway extracts text from supported documents, email files, code, and folders on the Mac. Ordinary
files are read when the user starts an action. Folder scans run locally in the background and are
bounded by file, size, time, and depth limits.

Folder analysis skips hidden and generated directories, symbolic links, and known secret or key
files. The folder preview shows which files were included, omitted, or skipped. This protection is
based on known names, extensions, and file types; it should not replace a company's own data
classification or access controls.

No document content is sent to an AI provider merely because a file was dropped. It is sent only
after the user starts an AI action.

## Bring Your Own Key

In BYOK mode, Dragaway connects directly to the selected OpenAI, Anthropic, Gemini, Groq, or local
Ollama endpoint. There is no hidden fallback through a Dragaway server and no silent switch to a
different provider. Refreshing the available model list also contacts only the selected provider.

The API key is stored in the macOS Keychain and is used only to authenticate requests to that
provider. Dragaway does not receive the key.

The selected provider necessarily receives the prompt and prepared content needed to answer it.
Retention, abuse monitoring, regional processing, subprocessors, and model-training rules are
controlled by the provider and the customer's provider account. Organisations should review those
terms and enable enterprise or zero-data-retention controls where required.

## Hosted Free and Pro service

The hosted service uses a Dragaway-operated Cloudflare Worker so the provider key does not have to be
shipped inside the app. The Worker receives the request, forwards it to Gemini, returns the answer,
and meters usage.

The current backend design stores:

- a pseudonymous installation identifier;
- daily and trial usage;
- call and token totals;
- the model and quality tier used.

It does not write document content, prompts, images, or generated answers to its application database
or content logs. The request is nevertheless processed in readable form by the Worker and Gemini
while the answer is generated. Customers who require a path with no Dragaway-operated intermediary
should use BYOK or local Ollama.

## Encryption in transit

Provider and hosted requests use HTTPS with macOS system certificate validation. Someone observing a
normal Wi-Fi or internet connection may see destinations, timing, and approximate traffic size, but
not the request or response contents.

HTTPS is not end-to-end encryption from the provider itself: the selected provider must read the
request to process it. A company-managed TLS inspection proxy, trusted system administrator, or
compromised Mac may also be able to inspect traffic. Dragaway therefore promises encrypted transport,
not that interception is technically impossible under every threat model.

## Local storage

To support reopening sessions and convenient drag workflows, Dragaway may store the following inside
the current macOS user's Application Support directory:

- recent file paths, prompts, and AI answers;
- materialised text, link, mail, or image drops;
- Clipboard History entries when that feature is enabled.

These records remain local and are not uploaded as telemetry, but they are not separately encrypted
by Dragaway. They are protected by the Mac's user account, filesystem permissions, FileVault when
enabled, and any controls applied by the organisation. API keys are stored separately in Keychain.

## Clipboard History

Clipboard History keeps up to 20 recent text, image, or file entries locally. Dragaway refuses to
capture pasteboard entries marked by their source application as sensitive, concealed, transient, or
automatically generated. Password managers and secure Apple fields commonly use these markers, so
properly marked passwords and other secret values are never added to the history.

This should never be treated as a 100% secret detector. A source application can place a password,
token, or confidential text on the clipboard without marking it as sensitive, and plain text alone
cannot always be classified reliably. For strict corporate environments, Clipboard History should be
disabled unless it is explicitly required.

When Clipboard History is disabled, Dragaway stops monitoring the clipboard and captures or writes
no new clipboard content. Existing history is not silently deleted; users can remove individual
entries or clear it before or after disabling the feature.

## Websites and browser content

Dropping a website URL is different from dropping a local file. Dragaway fetches that URL immediately
so the page text can be prepared locally. The destination website therefore receives a normal web
request before an AI action is selected. The fetch uses an ephemeral, cookie-free session; a
first-party rendering pass may be used when static HTML is incomplete.

The extracted page text is sent to an AI provider only after the user starts an AI action. As with a
browser, remote sites and resources have their own privacy practices. Files containing explicit
remote references, such as a Markdown document with a remote image used during PDF export, may also
cause that referenced resource to be requested.

## Dictation and transcription

Dictation uses Apple's Speech framework. Recognition may happen on the device when supported, but
macOS can use Apple's speech service as a fallback. Audio used for speech recognition is not routed
through Dragaway's AI backend, but Apple's terms and device settings apply.

## Permissions and app access

Dragaway is not sandboxed because its core drag detection relies on system-wide mouse events. This
does not by itself send data anywhere, but it gives the app a broader local trust boundary than a
sandboxed utility.

Accessibility access is optional and off by default. When enabled, Dragaway uses it to send a paste
command after a Clipboard History selection. It does not inspect the accessibility tree or read the
interface of other applications.

## Enterprise guidance

For an organisation using BYOK, Dragaway is not an additional recipient of AI content: the prepared
request travels directly to the organisation's selected provider. A conservative managed deployment
should additionally:

- use an approved enterprise provider account and retention policy;
- disable Clipboard History when it is not needed;
- restrict outbound traffic to approved provider and update domains;
- use FileVault and the organisation's normal endpoint protection;
- install only signed and notarised Dragaway releases from an approved source;
- review local session retention against the organisation's data-handling policy.

Dragaway can provide a direct and transparent BYOK data path. It cannot replace the security policy of
the selected AI provider, the configuration of the Mac, or the controls of the organisation operating
it.
