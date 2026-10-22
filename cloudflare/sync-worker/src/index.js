// Stremio Craft – Geräte-Sync
//
// Speichert pro „Space“ (= gemeinsamer Sync-Code mehrerer Geräte) einen Datenblock, den die App
// vorher selbst verschlüsselt hat. Der Worker sieht weder den Sync-Code noch Klartext:
// die Space-ID ist ein SHA-256-Hash des Codes, der Block ist AES-GCM-verschlüsselt.
//
// Endpunkte
//   GET    /v1/space/:id          → { version, blob, updatedAt } | 404   (If-None-Match: <version> → 304)
//   PUT    /v1/space/:id          { version: <erwartet>, blob } → { version } | 409 { version, blob, updatedAt }
//   DELETE /v1/space/:id          → 204
//   POST   /v1/pair               { publicKey } → { pin, expiresAt }
//   GET    /v1/pair/:pin          → { publicKey, payload|null } | 404
//   PUT    /v1/pair/:pin          { payload } → 204 | 409 (schon beantwortet)
//   DELETE /v1/pair/:pin          → 204
//   POST   /v1/recommend          Empfehlungen aus der Titeldatenbank (siehe recommend.js)
//   GET    /v1/catalog/status     Stand der Titeldatenbank und des Imports
//
// Zu viele Anfragen einer IP → 429 (Kopplung 60/min, Sync und Empfehlungen 120/min).
// Der Cron-Trigger (jede Minute) füllt und erneuert die Titeldatenbank (siehe catalog.js).

import { catalogStatus, runImportStep } from "./catalog.js";
import { recommend } from "./recommend.js";

const SPACE_ID = /^[0-9a-f]{64}$/;
const PIN = /^[0-9]{6}$/;
const MAX_BLOB = 1_500_000; // Zeichen (Base64), reicht für tausende Einträge
const MAX_PAYLOAD = 4_000;
const MAX_KEY = 100;
const PAIR_TTL_MS = 10 * 60 * 1000;

export default {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      return json({ error: "server", message: String(error?.message ?? error) }, 500);
    }
  },

  async scheduled(event, env) {
    await runImportStep(env);
  },
};

async function route(request, env, ctx) {
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts[0] !== "v1") return json({ error: "not_found" }, 404);

  // Ratenbegrenzung pro IP: Kopplungen streng (PINs nicht durchprobierbar), Sync großzügig.
  const limiter = parts[1] === "pair" ? env.PAIR_LIMITER : env.SPACE_LIMITER;
  if (limiter) {
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await limiter.limit({ key: ip });
    if (!success) return json({ error: "rate_limited" }, 429, { "Retry-After": "60" });
  }

  if (parts[1] === "space" && parts.length === 3) {
    const id = parts[2];
    if (!SPACE_ID.test(id)) return json({ error: "bad_id" }, 400);
    switch (request.method) {
      case "GET": return getSpace(request, env, id);
      case "PUT": return putSpace(request, env, id);
      case "DELETE":
        await env.DB.prepare("DELETE FROM spaces WHERE id = ?").bind(id).run();
        return new Response(null, { status: 204 });
    }
  }

  if (parts[1] === "recommend" && parts.length === 2 && request.method === "POST") {
    return recommend(request, env, ctx, json);
  }
  if (parts[1] === "catalog" && parts[2] === "status" && request.method === "GET") {
    return env.CATALOG ? json(await catalogStatus(env)) : json({ error: "no_catalog" }, 503);
  }

  if (parts[1] === "pair") {
    await env.DB.prepare("DELETE FROM pairings WHERE expires_at < ?").bind(Date.now()).run();
    if (parts.length === 2 && request.method === "POST") return createPairing(request, env);
    if (parts.length === 3) {
      const pin = parts[2];
      if (!PIN.test(pin)) return json({ error: "bad_pin" }, 400);
      switch (request.method) {
        case "GET": return getPairing(env, pin);
        case "PUT": return answerPairing(request, env, pin);
        case "DELETE":
          await env.DB.prepare("DELETE FROM pairings WHERE pin = ?").bind(pin).run();
          return new Response(null, { status: 204 });
      }
    }
  }

  return json({ error: "not_found" }, 404);
}

// MARK: - Spaces

async function getSpace(request, env, id) {
  const row = await env.DB.prepare("SELECT version, blob, updated_at FROM spaces WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not_found" }, 404);
  const etag = `"${row.version}"`;
  if (request.headers.get("If-None-Match") === etag) {
    return new Response(null, { status: 304, headers: { ETag: etag } });
  }
  return json({ version: row.version, blob: row.blob, updatedAt: row.updated_at }, 200, { ETag: etag });
}

async function putSpace(request, env, id) {
  const body = await readJSON(request);
  if (!body || typeof body.blob !== "string" || !Number.isInteger(body.version) || body.version < 0) {
    return json({ error: "bad_request" }, 400);
  }
  if (body.blob.length > MAX_BLOB) return json({ error: "too_large" }, 413);

  const now = Date.now();
  const next = body.version + 1;
  // Optimistische Sperre: nur schreiben, wenn der Stand des Geräts noch aktuell ist.
  const result = body.version === 0
    ? await env.DB.prepare("INSERT INTO spaces (id, version, blob, updated_at) VALUES (?, 1, ?, ?) ON CONFLICT(id) DO NOTHING")
        .bind(id, body.blob, now).run()
    : await env.DB.prepare("UPDATE spaces SET version = ?, blob = ?, updated_at = ? WHERE id = ? AND version = ?")
        .bind(next, body.blob, now, id, body.version).run();

  if (result.meta.changes === 1) return json({ version: next, updatedAt: now });

  const current = await env.DB.prepare("SELECT version, blob, updated_at FROM spaces WHERE id = ?").bind(id).first();
  if (!current) return json({ error: "not_found" }, 404);
  return json({ error: "conflict", version: current.version, blob: current.blob, updatedAt: current.updated_at }, 409);
}

// MARK: - Kopplung per PIN

async function createPairing(request, env) {
  const body = await readJSON(request);
  if (!body || typeof body.publicKey !== "string" || body.publicKey.length > MAX_KEY) {
    return json({ error: "bad_request" }, 400);
  }
  const expiresAt = Date.now() + PAIR_TTL_MS;
  for (let attempt = 0; attempt < 8; attempt++) {
    const pin = randomPIN();
    const result = await env.DB.prepare(
      "INSERT INTO pairings (pin, public_key, payload, expires_at) VALUES (?, ?, NULL, ?) ON CONFLICT(pin) DO NOTHING"
    ).bind(pin, body.publicKey, expiresAt).run();
    if (result.meta.changes === 1) return json({ pin, expiresAt }, 201);
  }
  return json({ error: "busy" }, 503);
}

async function getPairing(env, pin) {
  const row = await env.DB.prepare("SELECT public_key, payload FROM pairings WHERE pin = ?").bind(pin).first();
  if (!row) return json({ error: "not_found" }, 404);
  return json({ publicKey: row.public_key, payload: row.payload ?? null });
}

async function answerPairing(request, env, pin) {
  const body = await readJSON(request);
  if (!body || typeof body.payload !== "string" || body.payload.length > MAX_PAYLOAD) {
    return json({ error: "bad_request" }, 400);
  }
  // Nur die erste Antwort zählt.
  const result = await env.DB.prepare("UPDATE pairings SET payload = ? WHERE pin = ? AND payload IS NULL AND expires_at >= ?")
    .bind(body.payload, pin, Date.now()).run();
  if (result.meta.changes === 1) return new Response(null, { status: 204 });
  const exists = await env.DB.prepare("SELECT 1 FROM pairings WHERE pin = ?").bind(pin).first();
  return json({ error: exists ? "already_answered" : "not_found" }, exists ? 409 : 404);
}

// MARK: - Hilfsfunktionen

function randomPIN() {
  const value = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return value.toString().padStart(6, "0");
}

async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

function json(value, status = 200, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}
