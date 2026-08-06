# Session Sharing — Architecture

**Status:** design agreed, implementation in progress · **Branch:** `main` (product work)
**Goal:** User A exposes a session; User B enters a 6-digit code and continues working on it
with **their own** API key.

> **The promise stays intact.** Everything remains local until the user performs one explicit,
> unambiguous action ("Expose Session"). Nothing is uploaded before that, and nothing is uploaded
> that the user did not choose to expose.

---

## 1 · What is shared

A `SessionRecord` is useless on another machine — `primaryPath` is a local path:

```swift
struct SessionRecord { primaryPath: String; additionalPaths: [String]; turns: [SessionTurn] }
```

So the share bundle carries **both** halves:

| Part | Content | Why |
|---|---|---|
| **Insights** | `turns[]` — action, prompt title, result text, date | the actual value: what the AI concluded |
| **Artifact** | the primary file's bytes + filename | User B must be able to drag it out and keep working |

**Fork semantics, not sync.** User B receives a *copy*. They get their own local session, their own
history, and run further actions through **their own provider/API key**. Nothing flows back to
User A. This is a snapshot, and the UI says so.

Limits: **1 file** (the primary) and **25 MB** in the first version. Additional files and larger
payloads are deliberately deferred — see §8.

---

## 2 · Security model — two honest tiers

A 6-digit code carries ~20 bits of entropy. That **cannot** be a cryptographic key: anyone holding
the ciphertext could brute-force 10⁶ candidates offline in seconds. Deriving a 256-bit key from it
(HKDF) does not help — a KDF stretches entropy, it never creates it.

Therefore the product ships two tiers, and **the UI states which one is active in plain language**:

| | **Code only** (default) | **Code + password** (optional) |
|---|---|---|
| User types | 6 digits | 6 digits + password |
| Payload encryption | AES-256-GCM | AES-256-GCM |
| Key location | **server-held**, released on correct code | **derived from the password** — never uploaded |
| Protects against | R2/storage breach, network interception, guessing (rate-limited) | all of that **plus a compromised or curious server** |
| Honest claim | "Encrypted, protected by attempt limits" | "End-to-end encrypted — we cannot read it" |
| Suitable for | ordinary work material | confidential material |

**Never claim end-to-end encryption for the code-only tier.** That would be false: the server can
decrypt. The UI copy in §5 is written accordingly.

### Key handling

```
Code only:
  key       = random 256 bit, generated on User A's Mac
  uploaded  = ciphertext + key            (server stores both, releases key on correct code)

Code + password:
  key       = Argon2id(password, salt, …)  ← never leaves the Mac
  uploaded  = ciphertext + salt            (server stores NO key material)
```

Both tiers use AES-256-GCM; the auth tag is verified before anything is written to disk.

### Why not a long link with the key in the URL fragment
That is the cryptographically superior design (`…/s/J7K4P9#k=<256 bit>`; the fragment is never sent
to the server) and remains the right answer for a future "Share link" affordance. It was **not**
chosen as the default because the product decision is a typable 6-digit code read out loud or
pasted into a chat. The password tier restores real end-to-end encryption for anyone who needs it.

### Why not PAKE
SPAKE2 (Magic Wormhole) makes short codes genuinely safe, but it is **interactive** — both parties
must be online simultaneously. This is an asynchronous snapshot ("expose now, look tomorrow"), so
PAKE does not fit. Revisit if a live co-working mode is ever built.

### Brute-force defence (the code-only tier depends on this)
- **10 attempts** per share, then the share is locked permanently.
- Per-IP rate limit on the redeem endpoint.
- **Short TTL** (see §3) — the window for guessing is small by construction.
- Codes are generated with a CSPRNG, never sequential.

---

## 3 · Retention — four layers, so no single failure keeps data alive

| Layer | Mechanism | Granularity | Guarantees |
|---|---|---|---|
| 0 | Encryption | — | leftovers are unreadable (with password: by anyone) |
| 1 | **Ack-based delete** | seconds | normal case cleans itself up |
| 2 | **Cron Trigger** (hourly) | hours | precise TTL, also for never-fetched shares |
| 3 | **R2 lifecycle rule** | days | **infrastructure backstop** — runs even if the Worker is broken |

**TTL: 24 hours.** The sender can revoke at any time.

### Ack-based deletion — not "delete on first GET"
Deleting on the first `GET` is unsafe: a dropped Wi-Fi connection or an app crash would destroy the
session before the recipient ever had it. Ranged/resumed downloads also make "one GET" ill-defined.

The flow instead:

```
GET /v1/share/{id}          → ciphertext
   client decrypts, verifies the GCM tag, writes the file to disk
POST /v1/share/{id}/ack     → only now the server deletes
```

No ack ⇒ the share survives until TTL. Additionally `max_fetches = 5` guards against endless
re-download, and the sender can revoke explicitly.

### Wording discipline
R2 lifecycle rules operate in **days**, so never say "deleted after 24 h". Say what is true:

> *"After 24 hours the share can no longer be retrieved and its key is destroyed. The encrypted
> remains are removed automatically."*

---

## 4 · Backend

A **separate, open-source Worker** — not an addition to the existing `worker/` metering proxy.
Different job, different bindings, different licence, and the AI proxy stays untouched.

```
worker-share/          MIT licensed, publishable standalone
  src/index.js
  schema.sql
  wrangler.toml
```

### Protocol (this is the artifact that enables self-hosting)

| Method | Path | Body / result |
|---|---|---|
| `POST` | `/v1/share` | ciphertext + metadata → `{ code, id, expires_at }` |
| `GET` | `/v1/share/{code}` | → ciphertext (+ key, code-only tier) |
| `POST` | `/v1/share/{code}/ack` | → deletes the share |
| `DELETE` | `/v1/share/{code}` | sender revokes |

The server only ever sees ciphertext and opaque metadata. That makes it *dumb* — and therefore
trivially reimplementable by anyone.

### Storage
- **Cloudflare KV** with `expirationTtl` for payloads ≤ 25 MB — the store expires entries itself,
  no cron needed for the common case.
- **R2 + lifecycle rule** when larger payloads are enabled later.
- **D1** for share metadata (attempt counter, fetch counter, expiry).

All storage access goes through four functions (`put / get / del / exists`) so a future port is
mechanical. **No Docker image until a real customer asks for it** — the documented protocol above
is what makes self-hosting possible, not a container.

### Self-hosting
The app points at any compatible server via `BackendConfig.shareBaseURL` — the same pattern already
used for `proxyBaseURL`. Companies deploy their own Worker (or their own implementation) and change
one setting.

---

## 5 · UI

### Expose (User A)
Reachable from the session card ("Expose Session") **and** a hotkey. Shows:

1. the **6-digit code**, large, copyable
2. a **plain-language disclosure block** — what leaves the Mac, how it is stored, how it is
   encrypted, when it is deleted
3. an **optional password field** underneath, which upgrades the tier and *changes the disclosure
   text live*

Disclosure copy — **code only**:

> **What leaves your Mac:** the file *«name.pdf»* and this session's AI results.
> **Encrypted** before upload (AES-256). Stored on Dragaway's server, protected by an attempt limit
> — we hold the key, so we could technically read it.
> **Deleted** once your colleague has it, at the latest after 24 hours.
> *Set a password for confidential material — then not even we can read it.*

Disclosure copy — **with password**:

> **What leaves your Mac:** the file *«name.pdf»* and this session's AI results — **end-to-end
> encrypted**. The password never leaves your Mac; without it the data cannot be decrypted, not
> even by us.
> **Deleted** once your colleague has it, at the latest after 24 hours.
> *Share the password over a different channel than the code.*

Also on the panel: remaining validity, "Revoke" button.

### Join (User B)
Hotkey or menu → enter the 6-digit code → password prompt **only if** the share requires one →
download, decrypt, verify → the file lands in the local drops directory and a **new local session**
opens with the imported turns visible as history.

From that point it is an ordinary Dragaway session: User B's own provider, own API key, own history.

---

## 6 · Data flow

```
User A                          Server                        User B
──────                          ──────                        ──────
bundle = {turns, file}
  ↓ AES-256-GCM
ciphertext ──────────────────→  KV/R2 + D1
                                 code ────(Slack/verbally)───→ enters code
                                      ←──────────────────────  GET
                                 ciphertext ─────────────────→
                                                               decrypt + verify tag
                                                               write file, open session
                                      ←──────────────────────  ack
                                 delete
```

---

## 7 · Permissions

Nothing here requires a new macOS permission. Uploads are ordinary outbound HTTPS from a
non-sandboxed app.

**If LAN transfer (Bonjour/MultipeerConnectivity) is added later:** macOS 15+ gates local-network
discovery behind a TCC permission. The Info.plist keys (`NSLocalNetworkUsageDescription`,
`NSBonjourServices`) do **not** trigger a prompt on their own — only the first actual API call does.
So the browser/listener must be created **lazily, on explicit opt-in**, exactly like the thesis
branch's Accessibility sensor. Verify empirically: fresh build → `tccutil reset` → use the app
without LAN sharing → Dragaway must **not** appear under Privacy › Local Network.

---

## 8 · Deliberately out of scope (first version)
- multiple files per share (only the primary file travels)
- payloads > 25 MB
- live/synchronised sessions (this is a snapshot; DO-based sync is a separate project)
- share links with fragment keys (§2) — natural follow-up
- Docker/self-host reference image (§4) — build on demand
- accounts, ACLs, "who opened my share"

## 9 · Open questions
- Should sharing be a **Pro** feature? `EntitlementStore` already distinguishes `byok / freeHosted /
  pro`, and server cost only arises here. Not gated in the first version.
- Abuse: end-to-end encrypted payloads **cannot** be scanned. Size caps, per-device rate limits and
  short TTLs are the only available mitigations — an accepted trade-off that must be stated in the
  terms.
