# AI Drop — hosted free-tier Worker

A tiny Cloudflare Worker that powers the **"AI Drop Free"** version. It holds the
host **Gemini 2.5 Flash** key as a server secret (never in the Mac app), forwards
completions, and meters usage per device: a one-time **30-call trial**, then
**10 calls/day**, with a **global daily cap** so abuse can't drain your budget.

The Mac app only ever knows this Worker's URL — never the key.

## One-time setup

You need a free [Cloudflare account](https://dash.cloudflare.com/sign-up) and a
[Google AI Studio key](https://aistudio.google.com/apikey).

```bash
cd worker

# 1. Install the Cloudflare CLI and log in
npm install -g wrangler
wrangler login

# 2. Create the database, then paste the printed `database_id` into wrangler.toml
wrangler d1 create aidrop

# 3. Create the tables
wrangler d1 execute aidrop --remote --file=./schema.sql

# 4. Store your Gemini key as a secret (you'll be prompted to paste it)
wrangler secret put GEMINI_API_KEY

# 5. Deploy
wrangler deploy
```

`wrangler deploy` prints a URL like `https://aidrop.<your-subdomain>.workers.dev`.

## Connect the app

Open `MacNotchAI/Core/BackendConfig.swift` and paste that URL:

```swift
static let proxyBaseURL: URL? = URL(string: "https://aidrop.<your-subdomain>.workers.dev")
```

Rebuild the app. "AI Drop Free" is now selectable in onboarding and the menu.

## Adjust limits (no redeploy of logic needed)

Edit the `[vars]` block in `wrangler.toml` and run `wrangler deploy`:

- `TRIAL_TOTAL` — one-time free interactions per device (default 30)
- `FREE_DAILY_CAP` — interactions/day after the trial (default 10)
- `GLOBAL_DAILY_CAP` — hard ceiling on total daily interactions = your budget guard (default 2000)

## Quick test

```bash
curl -X POST https://aidrop.<your-subdomain>.workers.dev/v1/complete \
  -H "Content-Type: application/json" \
  -H "X-Device-Id: test-device-123" \
  -d '{"system":"You are concise.","content":"Say hello in 3 words."}'
```

## Security notes / known limits

- The key lives only as a Worker secret (`wrangler secret`), never in git or the app.
- Device identity is a client-generated UUID today — **best-effort** metering. A
  determined abuser can reset it for a fresh trial. The `GLOBAL_DAILY_CAP` is the
  hard money-protection. Hardening with **App Attest + DeviceCheck** (so quota
  survives reinstall and only genuine app builds are served) is the planned next
  step — see `tasks/todo.md` Phase 2 (identity decision).
- No file content is stored — only per-device counters. Keep it that way.
