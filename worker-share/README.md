# Dragaway Share

A deliberately dumb relay for exposed Dragaway sessions. It stores an opaque ciphertext blob
and some metadata, hands it back on the correct 6-digit code, and deletes it. That is all.

**MIT licensed and self-hostable** — because it is this dumb, you can run your own instance and
point the app at it. See `../docs/SHARE_ARCHITECTURE.md` for the full design.

The server never sees plaintext. In the password tier it holds **no key material at all**.

---

## Deploy (≈ 5 minutes)

Everything below runs **inside this `worker-share/` folder**.

```bash
cd worker-share
```

### 1 · Wrangler

```bash
npm install -g wrangler
wrangler login
```

### 2 · Create the two stores

```bash
wrangler kv namespace create SHARES
wrangler d1 create dragaway-share
```

Each command prints an id. Paste them into `wrangler.toml`, replacing
`PASTE_KV_NAMESPACE_ID` and `PASTE_D1_DATABASE_ID`.

### 3 · Create the tables

```bash
wrangler d1 execute dragaway-share --remote --file=./schema.sql
```

### 4 · Deploy

```bash
wrangler deploy
```

Wrangler prints the deployed address, e.g.

```
Published dragaway-share
  https://dragaway-share.<your-subdomain>.workers.dev
```

**That printed `https://…` address is the URL** you need in the next step. It is the address of
your running service — nothing you have to buy or register; Cloudflare generates it from the
Worker name plus your account subdomain.

### 5 · Point the app at it

In `MacNotchAI/Core/BackendConfig.swift`:

```swift
static let shareBaseURL = URL(string: "https://dragaway-share.<your-subdomain>.workers.dev")
```

While this is `nil`, the whole sharing feature stays hidden: no menu items, no ⌃⌘E / ⌃⌘J
registration. Filling it in is what turns the feature on.

Rebuild the app and the sharing UI appears.

### 6 · Check it responds

```bash
curl -i https://dragaway-share.<your-subdomain>.workers.dev/v1/share/000000
```

Expect `HTTP/2 404` with `{"error":"Not found"}` — that means routing, KV and D1 are wired.
A 500 means a binding id is still a placeholder.

---

## Operating it

**Retention** is layered so no single failure keeps data alive:

| Layer | What it does |
|---|---|
| ack | the app confirms a successful decrypt+write, then the share is deleted |
| fetch cap | stops serving after 5 downloads |
| KV TTL | the value expires itself after 24 h |
| cron | hourly sweep of expired metadata (`[triggers]` in `wrangler.toml`) |
| revoke | the sender can delete at any time |

Deletion is **never** triggered by the download itself — a dropped connection or an app crash
must not destroy a share the recipient never actually received.

**Tunables** live at the top of `src/index.js`: `TTL_SECONDS`, `MAX_BYTES`, `MAX_ATTEMPTS`,
`MAX_FETCHES`. `MAX_BYTES` must stay in sync with `ShareBundle.maxFileBytes` in the app.

**Costs.** Well inside Cloudflare's free tier for normal use: KV and D1 both have generous free
allowances, and payloads are capped at 25 MB and deleted within a day.

---

## Self-hosting elsewhere

The app talks to four endpoints:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/share` | store ciphertext, return a code |
| `GET` | `/v1/share/{code}` | return the ciphertext |
| `POST` | `/v1/share/{code}/ack` | delete after a confirmed import |
| `DELETE` | `/v1/share/{code}` | sender revokes |

Implement those against any storage and point `shareBaseURL` at it. Inside `src/index.js` all
storage access goes through `put / get / del`, so porting off Cloudflare means replacing three
functions.

There is deliberately **no Docker image**: the documented protocol is what enables self-hosting,
not a container. One will be added if a deployment actually needs it.

---

## A note on the two security tiers

- **Code only** — the server stores the AES key and releases it on the correct code. This
  protects against a storage breach and network interception, but the operator *could*
  technically decrypt. The app never calls this end-to-end encrypted, and neither should you.
- **Code + password** — the key is derived from the user's password on their Mac and never
  uploaded. Genuine end-to-end encryption; the operator cannot read the data.

A 6-digit code carries about 20 bits of entropy and therefore can never be a cryptographic key —
its safety in the first tier comes from the attempt limit enforced here, not from cryptography.
