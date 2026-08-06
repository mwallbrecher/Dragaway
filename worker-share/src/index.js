/**
 * Dragaway Share — a deliberately dumb relay for exposed sessions.
 * MIT licensed. Protocol: docs/SHARE_ARCHITECTURE.md §4.
 *
 * The server NEVER sees plaintext. It stores an opaque ciphertext blob plus metadata.
 * In the password tier it holds no key material at all; in the code-only tier it holds
 * the key and releases it on the correct code — which is exactly why the app must not
 * call that tier "end-to-end encrypted".
 *
 * Because it is this dumb, anyone can self-host it: implement three endpoints, point
 * BackendConfig.shareBaseURL at your instance.
 *
 * Storage goes through put/get/del below so a port to S3/Postgres stays mechanical.
 */

const TTL_SECONDS = 24 * 60 * 60;   // 24 h — matches the app's disclosure text
const MAX_BYTES = 25 * 1024 * 1024; // keep in sync with ShareBundle.maxFileBytes
const MAX_ATTEMPTS = 10;            // wrong-code guesses before a share locks
const MAX_FETCHES = 5;              // successful downloads before it stops serving

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    try {
      if (path === "/v1/share" && request.method === "POST") {
        return cors(await createShare(request, env));
      }
      const m = path.match(/^\/v1\/share\/(\d{6})(\/ack)?$/);
      if (m) {
        const code = m[1];
        if (m[2] && request.method === "POST") return cors(await ackShare(code, env));
        if (request.method === "GET")          return cors(await readShare(code, env));
        if (request.method === "DELETE")       return cors(await revokeShare(code, env));
      }
      return cors(json({ error: "Not found" }, 404));
    } catch (err) {
      return cors(json({ error: String(err && err.message || err) }, 500));
    }
  },

  /**
   * Hourly sweep — precise TTL for shares that were never fetched. KV expires payloads on
   * its own; this clears the D1 metadata so a code can never resolve past its lifetime.
   */
  async scheduled(_event, env) {
    await env.DB.prepare("DELETE FROM shares WHERE expires_at < ?")
      .bind(Math.floor(Date.now() / 1000)).run();
  },
};

// ── endpoints ────────────────────────────────────────────────────────────────

async function createShare(request, env) {
  const body = await request.json();
  const { payload, tier, key, salt, file_name, has_password } = body || {};

  if (!payload || typeof payload !== "string") return json({ error: "Missing payload" }, 400);
  if (tier !== "codeOnly" && tier !== "password") return json({ error: "Bad tier" }, 400);
  // base64 is ~4/3 of the raw size; check the decoded length against the real limit.
  if (Math.floor(payload.length * 3 / 4) > MAX_BYTES) return json({ error: "Too large" }, 413);
  if (tier === "codeOnly" && !key) return json({ error: "Missing key" }, 400);
  if (tier === "password" && !salt) return json({ error: "Missing salt" }, 400);

  const code = await freshCode(env);
  const now = Math.floor(Date.now() / 1000);
  const expires = now + TTL_SECONDS;

  await put(env, code, payload);
  await env.DB.prepare(
    `INSERT INTO shares (code, tier, enc_key, salt, file_name, has_password,
                         attempts, fetches, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)`
  ).bind(code, tier, key || null, salt || null, file_name || "", has_password ? 1 : 0,
         now, expires).run();

  return json({ code, expires_at: expires });
}

async function readShare(code, env) {
  const row = await env.DB.prepare("SELECT * FROM shares WHERE code = ?").bind(code).first();
  if (!row) return json({ error: "Not found" }, 404);

  if (row.expires_at < Math.floor(Date.now() / 1000)) {
    await destroy(env, code);
    return json({ error: "Expired" }, 410);
  }
  if (row.attempts >= MAX_ATTEMPTS) return json({ error: "Locked" }, 423);
  if (row.fetches >= MAX_FETCHES)   return json({ error: "Fetch limit reached" }, 423);

  const payload = await get(env, code);
  if (!payload) { await destroy(env, code); return json({ error: "Not found" }, 404); }

  await env.DB.prepare("UPDATE shares SET fetches = fetches + 1 WHERE code = ?").bind(code).run();

  return json({
    payload,
    tier: row.tier,
    key: row.enc_key || undefined,   // codeOnly only — this is the tier's honest weakness
    salt: row.salt || undefined,     // password tier — public by design
    file_name: row.file_name,
    has_password: !!row.has_password,
  });
}

/**
 * Deletion is ack-driven, never triggered by the download itself: a dropped connection or
 * a crash must not destroy a share the recipient never actually received (§3).
 */
async function ackShare(code, env) {
  await destroy(env, code);
  return json({ ok: true });
}

async function revokeShare(code, env) {
  await destroy(env, code);
  return json({ ok: true });
}

// ── helpers ──────────────────────────────────────────────────────────────────

/** CSPRNG, never sequential; retries on the (rare) collision with a live share. */
async function freshCode(env) {
  for (let i = 0; i < 12; i++) {
    const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1000000;
    const code = String(n).padStart(6, "0");
    const existing = await env.DB.prepare("SELECT code FROM shares WHERE code = ?")
      .bind(code).first();
    if (!existing) return code;
  }
  throw new Error("Could not allocate a code");
}

async function destroy(env, code) {
  await del(env, code);
  await env.DB.prepare("DELETE FROM shares WHERE code = ?").bind(code).run();
}

// ── storage seam (swap these four to port off Cloudflare) ────────────────────

async function put(env, code, payload) {
  // KV expires the value itself — the common case needs no cron at all.
  await env.SHARES.put(`share:${code}`, payload, { expirationTtl: TTL_SECONDS });
}
async function get(env, code) { return env.SHARES.get(`share:${code}`); }
async function del(env, code) { await env.SHARES.delete(`share:${code}`); }

// ── plumbing ─────────────────────────────────────────────────────────────────

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { "Content-Type": "application/json" },
  });
}

function cors(res) {
  const h = new Headers(res.headers);
  h.set("Access-Control-Allow-Origin", "*");
  h.set("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  h.set("Access-Control-Allow-Headers", "Content-Type,X-Device-Id");
  return new Response(res.body, { status: res.status, headers: h });
}
