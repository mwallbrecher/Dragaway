// AI Drop — hosted free-tier metering proxy (Cloudflare Worker).
//
// Holds the host Gemini key as a secret and forwards completions, metering each
// device: a one-time TRIAL_TOTAL-call trial, then FREE_DAILY_CAP calls/day. A
// GLOBAL_DAILY_CAP circuit-breaker bounds total daily spend regardless of abuse.
//
// The macOS app never sees GEMINI_API_KEY — it only knows this Worker's URL.
//
// Endpoints:
//   POST /v1/complete  { action, system, content, image?: {mime, data(base64)} }
//                      headers: X-Device-Id  → { text, usage }
//   GET  /v1/usage     headers: X-Device-Id  → { usage }   (no quota consumed)

const GEMINI_URL =
  "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

const MAX_CONTENT_CHARS = 20_000;       // bounds token cost (client caps at ~12k)
const MAX_IMAGE_BASE64_BYTES = 7_000_000; // ~5MB image after base64 inflation

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    try {
      if (url.pathname === "/v1/complete" && request.method === "POST") {
        return cors(await handleComplete(request, env));
      }
      if (url.pathname === "/v1/usage" && request.method === "GET") {
        return cors(await handleUsage(request, env));
      }
      if (url.pathname === "/" || url.pathname === "/health") {
        return cors(json({ ok: true, service: "aidrop" }));
      }
      return cors(json({ error: "Not found" }, 404));
    } catch (err) {
      return cors(json({ error: "Server error", detail: String(err) }, 500));
    }
  },
};

// ── /v1/complete ────────────────────────────────────────────────────────────

async function handleComplete(request, env) {
  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId) return json({ error: "Missing X-Device-Id" }, 400);

  const body = await request.json().catch(() => null);
  if (!body || typeof body.content !== "string") {
    return json({ error: "Missing content" }, 400);
  }
  if (body.content.length > MAX_CONTENT_CHARS) {
    return json({ error: "Content too large" }, 413);
  }
  if (body.image && typeof body.image.data === "string" &&
      body.image.data.length > MAX_IMAGE_BASE64_BYTES) {
    return json({ error: "Image too large for hosted tier — use your own key." }, 413);
  }

  const limits = readLimits(env);
  const day = utcDay();

  // Budget circuit-breaker: hard stop on total daily interactions.
  const globalCount = await getCount(
    env, "SELECT count FROM global_usage WHERE day = ?", [day]
  );
  if (globalCount >= limits.globalDailyCap) {
    return json({ error: "Free tier is busy right now. Try again later or use your own key." }, 503);
  }

  await env.DB.prepare(
    "INSERT OR IGNORE INTO accounts (device_id) VALUES (?)"
  ).bind(deviceId).run();

  const trialUsed = await getCount(
    env, "SELECT trial_used FROM accounts WHERE device_id = ?", [deviceId]
  );
  const inTrial = trialUsed < limits.trialTotal;

  let todayCount = 0;
  if (!inTrial) {
    todayCount = await getCount(
      env, "SELECT count FROM usage WHERE device_id = ? AND day = ?", [deviceId, day]
    );
    if (todayCount >= limits.freeDailyCap) {
      return json(
        { error: "Daily free limit reached.", usage: usagePayload(limits, trialUsed, todayCount) },
        429
      );
    }
  }

  // Forward to Gemini. Quota is only consumed on a successful completion.
  const result = await callGemini(env, body);
  if (!result.ok) {
    return json({ error: result.error || "Upstream error" }, 502);
  }

  // Consume one interaction.
  if (inTrial) {
    await env.DB.prepare(
      "UPDATE accounts SET trial_used = trial_used + 1 WHERE device_id = ?"
    ).bind(deviceId).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO usage (device_id, day, count) VALUES (?, ?, 1)
       ON CONFLICT(device_id, day) DO UPDATE SET count = count + 1`
    ).bind(deviceId, day).run();
  }
  await env.DB.prepare(
    `INSERT INTO global_usage (day, count) VALUES (?, 1)
     ON CONFLICT(day) DO UPDATE SET count = count + 1`
  ).bind(day).run();

  const newTrial = inTrial ? trialUsed + 1 : trialUsed;
  const newToday = inTrial ? todayCount : todayCount + 1;
  return json({ text: result.text, usage: usagePayload(limits, newTrial, newToday) });
}

// ── /v1/usage ─────────────────────────────────────────────────────────────────

async function handleUsage(request, env) {
  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId) return json({ error: "Missing X-Device-Id" }, 400);

  const limits = readLimits(env);
  const day = utcDay();
  const trialUsed = await getCount(
    env, "SELECT trial_used FROM accounts WHERE device_id = ?", [deviceId]
  );
  const todayCount = await getCount(
    env, "SELECT count FROM usage WHERE device_id = ? AND day = ?", [deviceId, day]
  );
  return json({ usage: usagePayload(limits, trialUsed, todayCount) });
}

// ── Gemini call ─────────────────────────────────────────────────────────────

async function callGemini(env, body) {
  const system = typeof body.system === "string" && body.system.length
    ? body.system : "You are a helpful assistant.";

  let userContent = body.content;
  if (body.image && body.image.data) {
    const mime = body.image.mime || "image/png";
    userContent = [
      { type: "image_url", image_url: { url: `data:${mime};base64,${body.image.data}` } },
      { type: "text", text: body.content || system },
    ];
  }

  const payload = {
    model: env.GEMINI_MODEL || "gemini-2.5-flash",
    messages: [
      { role: "system", content: system },
      { role: "user", content: userContent },
    ],
    max_tokens: 1024,
    temperature: 0.3,
  };

  const resp = await fetch(GEMINI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GEMINI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const data = await resp.json().catch(() => null);
  if (!resp.ok) {
    return { ok: false, error: data?.error?.message || `HTTP ${resp.status}` };
  }
  const text = data?.choices?.[0]?.message?.content;
  if (!text) return { ok: false, error: "Empty response" };
  return { ok: true, text };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function readLimits(env) {
  return {
    trialTotal: parseInt(env.TRIAL_TOTAL ?? "30", 10),
    freeDailyCap: parseInt(env.FREE_DAILY_CAP ?? "10", 10),
    globalDailyCap: parseInt(env.GLOBAL_DAILY_CAP ?? "2000", 10),
  };
}

function usagePayload(limits, trialUsed, todayCount) {
  const inTrial = trialUsed < limits.trialTotal;
  const trialRemaining = Math.max(0, limits.trialTotal - trialUsed);
  const dailyRemaining = Math.max(0, limits.freeDailyCap - todayCount);
  return {
    tier: "free",
    inTrial,
    trialRemaining,
    dailyRemaining,
    remaining: inTrial ? trialRemaining : dailyRemaining,
    resetAt: nextUtcMidnightISO(),
  };
}

async function getCount(env, sql, binds) {
  const row = await env.DB.prepare(sql).bind(...binds).first();
  if (!row) return 0;
  const v = row.count ?? row.trial_used ?? 0;
  return typeof v === "number" ? v : 0;
}

function utcDay() {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
}

function nextUtcMidnightISO() {
  const now = new Date();
  const next = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0
  ));
  return next.toISOString();
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cors(resp) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  resp.headers.set("Access-Control-Allow-Headers", "Content-Type, X-Device-Id");
  return resp;
}
