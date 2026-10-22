// Empfehlungen aus der Titeldatenbank.
//
// POST /v1/recommend
//   { kind: "all"|"movie"|"tv", region: "CH", limit: 60,
//     seeds: [{ id: "movie-27205", w: 3 }],   // ♥ stark, Merkliste/Gesehenes schwächer, 👎 negativ
//     exclude: ["movie-27205", …],            // schon markiert, gesehen oder abgelehnt
//     prefs: { likedGenres, dislikedGenres, decades, languages, maxRuntime, minRating, maxAge, people } }
//   → { items: [{ id, kind, tmdbId, imdbId, title, overview, poster, backdrop, year, rating }] }
//   503, solange die Datenbank noch leer ist (die App nutzt dann die bisherigen TMDB-Empfehlungen).
//
// Ablauf: harte Filter (Freigabe, unerwünschte Genres, Gesehenes, Laufzeit, Mindestbewertung) in SQL;
// Kandidaten aus ähnlichen Titeln (Volltextindex über Stichworte, Personen, Reihe, Genres) und aus den
// besten Titeln; dann Punkte für Ähnlichkeit, Qualität, Bekanntheit, Vorlieben und Verfügbarkeit bei
// den eigenen Anbietern; zum Schluss Abwechslung (keine zwei Teile einer Reihe, Genres gemischt).

import { token } from "./catalog.js";

const ID = /^(movie|tv)-\d{1,9}$/;
const CACHE_SECONDS = 6 * 60 * 60;
// Gewicht je Merkmalsart: eine gemeinsame Reihe sagt mehr als ein gemeinsames Genre.
const TAG_WEIGHT = { k: 1, p: 1.6, c: 3, g: 0.35 };
const COLUMNS = `t.imdb_id, t.id, t.kind, t.tmdb_id, t.title, t.overview, t.poster, t.backdrop, t.year, t.imdb_rating,
  t.imdb_votes, t.quality, t.genres, t.language, t.collection, t.tags`;

export async function recommend(request, env, ctx, json) {
  const db = env.CATALOG;
  if (!db) return json({ error: "no_catalog" }, 503);
  const raw = await request.text();
  if (raw.length > 200_000) return json({ error: "too_large" }, 413);
  const input = parse(raw);
  if (!input) return json({ error: "bad_request" }, 400);

  const cacheKey = new Request(`https://catalog.cache/recommend/${await sha256(raw)}`);
  const cached = await caches.default.match(cacheKey);
  if (cached) return cached;

  if (!(await db.prepare("SELECT 1 FROM titles WHERE ok = 1 LIMIT 1").first())) {
    return json({ error: "catalog_empty" }, 503);
  }
  const items = await compute(db, input);
  const response = json({ items }, 200, { "Cache-Control": `max-age=${CACHE_SECONDS}` });
  ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
  return response;
}

function parse(raw) {
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!body || typeof body !== "object") return null;
  const list = (value, max, check) => (Array.isArray(value) ? value.filter(check).slice(0, max) : []);
  const number = (value, min, max) => (typeof value === "number" && value >= min && value <= max ? value : null);
  const prefs = body.prefs && typeof body.prefs === "object" ? body.prefs : {};
  return {
    kind: ["movie", "tv"].includes(body.kind) ? body.kind : null,
    region: typeof body.region === "string" && /^[A-Z]{2}$/.test(body.region) ? body.region : null,
    limit: Math.round(number(body.limit, 1, 100) ?? 60),
    seeds: list(body.seeds, 300, (s) => s && ID.test(s.id) && typeof s.w === "number" && Math.abs(s.w) <= 10),
    exclude: list(body.exclude, 5000, (id) => typeof id === "string" && ID.test(id)),
    prefs: {
      likedGenres: list(prefs.likedGenres, 30, Number.isInteger),
      dislikedGenres: list(prefs.dislikedGenres, 30, Number.isInteger),
      decades: list(prefs.decades, 15, Number.isInteger),
      languages: list(prefs.languages, 15, (l) => typeof l === "string" && /^[a-z]{2}$/.test(l)),
      people: list(prefs.people, 20, (p) => typeof p === "string" && p.length <= 80).map(token).filter(Boolean),
      maxRuntime: number(prefs.maxRuntime, 10, 600),
      minRating: number(prefs.minRating, 1, 10),
      maxAge: number(prefs.maxAge, 0, 18),
    },
  };
}

async function compute(db, input) {
  const { prefs } = input;

  // 1. Merkmale der Ausgangstitel gewichten (Abgelehntes zieht ab), dazu Lieblingspersonen und -genres.
  const weights = new Map();
  const add = (word, w) => weights.set(word, (weights.get(word) ?? 0) + w * (TAG_WEIGHT[word[0]] ?? 1));
  if (input.seeds.length) {
    const seedWeight = new Map(input.seeds.map((s) => [s.id, s.w]));
    const rows = (await db.prepare("SELECT id, tags FROM titles WHERE ok = 1 AND id IN (SELECT value FROM json_each(?))")
      .bind(JSON.stringify([...seedWeight.keys()])).all()).results;
    for (const row of rows) {
      for (const word of row.tags.split(" ")) if (word) add(word, seedWeight.get(row.id) ?? 0);
    }
  }
  for (const person of prefs.people) add(`p_${person}`, 4);
  for (const genre of prefs.likedGenres) add(`g_${genre}`, 1.5);

  // 2. Kandidaten: ähnliche Titel und die besten Titel, jeweils mit den harten Filtern.
  const filter = hardFilter(input);
  const statements = [
    db.prepare(`SELECT ${COLUMNS} FROM titles t WHERE ${filter.sql} ORDER BY t.quality DESC LIMIT 300`).bind(...filter.binds),
  ];
  if (prefs.likedGenres.length) {
    statements.push(db.prepare(`SELECT ${COLUMNS} FROM titles t WHERE ${filter.sql}
      AND EXISTS (SELECT 1 FROM json_each(t.genres) g WHERE g.value IN (SELECT value FROM json_each(?)))
      ORDER BY t.quality DESC LIMIT 200`).bind(...filter.binds, JSON.stringify(prefs.likedGenres)));
  }
  if (prefs.decades.length) {
    statements.push(db.prepare(`SELECT ${COLUMNS} FROM titles t WHERE ${filter.sql}
      AND (t.year / 10) * 10 IN (SELECT value FROM json_each(?)) ORDER BY t.quality DESC LIMIT 150`)
      .bind(...filter.binds, JSON.stringify(prefs.decades)));
  }
  const positive = [...weights].filter(([, w]) => w > 0).sort((a, b) => b[1] - a[1]).slice(0, 80);
  if (positive.length) {
    const match = positive.map(([word]) => `"${word}"`).join(" OR ");
    statements.push(db.prepare(`SELECT ${COLUMNS} FROM titles t WHERE ${filter.sql} AND t.imdb_id IN
      (SELECT imdb_id FROM tags WHERE tags MATCH ? ORDER BY rank LIMIT 400)`).bind(...filter.binds, match));
  }
  const candidates = new Map();
  for (const result of await db.batch(statements)) {
    for (const row of result.results) if (!candidates.has(row.id)) candidates.set(row.id, row);
  }
  if (!candidates.size) return [];

  // 3. Verfügbarkeit bei den eigenen Anbietern in der Region.
  const available = new Set();
  if (input.region) {
    const rows = (await db.prepare("SELECT id FROM availability WHERE region = ? AND id IN (SELECT value FROM json_each(?))")
      .bind(input.region, JSON.stringify([...candidates.keys()])).all()).results;
    for (const row of rows) available.add(row.id);
  }

  // 4. Punkte.
  const scored = [...candidates.values()].map((row) => {
    const genres = JSON.parse(row.genres);
    let overlap = 0;
    for (const word of row.tags.split(" ")) overlap += weights.get(word) ?? 0;
    return { row, genres, overlap };
  });
  const maxOverlap = Math.max(0, ...scored.map((s) => s.overlap));
  const clamp = (value) => Math.min(1, Math.max(0, value));
  for (const s of scored) {
    const { row } = s;
    const parts = [];
    if (prefs.likedGenres.length) parts.push(s.genres.some((g) => prefs.likedGenres.includes(g)) ? 1 : 0);
    if (prefs.decades.length) parts.push(prefs.decades.includes(Math.floor((row.year ?? 0) / 10) * 10) ? 1 : 0);
    if (prefs.languages.length) parts.push(prefs.languages.includes(row.language) ? 1 : 0);
    const pref = parts.length ? parts.reduce((a, b) => a + b, 0) / parts.length : 0;
    const sim = maxOverlap > 0 ? clamp(s.overlap / maxOverlap) : 0;
    const q = clamp(((row.quality ?? 6.5) - 6.3) / 2.2);
    const pop = clamp((Math.log10(row.imdb_votes || 1) - 3) / 3.5);
    const avail = available.has(row.id) ? 1 : 0;
    s.score = maxOverlap > 0
      ? 0.42 * sim + 0.22 * q + 0.10 * pop + 0.14 * pref + 0.12 * avail
      : 0.45 * q + 0.20 * pop + 0.20 * pref + 0.15 * avail;
    if (s.overlap < 0) s.score -= 0.2; // ähnelt eher Abgelehntem
  }
  scored.sort((a, b) => b.score - a.score);

  // 5. Abwechslung: höchstens ein Teil pro Reihe, gleiche Hauptgenres werden zunehmend abgewertet.
  const pool = scored.slice(0, 400);
  const picked = [];
  const collections = new Set();
  const genreCount = new Map();
  while (picked.length < input.limit && pool.length) {
    let best = -1;
    let bestScore = -Infinity;
    for (let i = 0; i < pool.length; i++) {
      const s = pool[i];
      if (s.row.collection && collections.has(s.row.collection)) continue;
      const value = s.score * 0.9 ** (genreCount.get(s.genres[0]) ?? 0);
      if (value > bestScore) {
        bestScore = value;
        best = i;
      }
    }
    if (best < 0) break;
    const [s] = pool.splice(best, 1);
    picked.push(s.row);
    if (s.row.collection) collections.add(s.row.collection);
    genreCount.set(s.genres[0], (genreCount.get(s.genres[0]) ?? 0) + 1);
  }

  return picked.map((row) => ({
    id: row.id,
    kind: row.kind,
    tmdbId: row.tmdb_id,
    imdbId: row.imdb_id,
    title: row.title,
    overview: row.overview,
    poster: row.poster,
    backdrop: row.backdrop,
    year: row.year,
    rating: row.imdb_rating,
  }));
}

function hardFilter(input) {
  const { prefs } = input;
  const sql = ["t.ok = 1"];
  const binds = [];
  if (input.kind) {
    sql.push("t.kind = ?");
    binds.push(input.kind);
  }
  if (input.exclude.length) {
    sql.push("t.id NOT IN (SELECT value FROM json_each(?))");
    binds.push(JSON.stringify(input.exclude));
  }
  if (prefs.minRating) {
    sql.push("t.imdb_rating >= ?");
    binds.push(prefs.minRating);
  }
  if (prefs.maxRuntime) {
    sql.push("(t.runtime IS NULL OR t.runtime <= ?)");
    binds.push(prefs.maxRuntime);
  }
  if (prefs.maxAge !== null) {
    // Ohne bekannte Freigabe nur für Profile ab 16 – für Kinder lieber nichts Ungewisses.
    sql.push(prefs.maxAge >= 16 ? "(t.age IS NULL OR t.age <= ?)" : "t.age <= ?");
    binds.push(prefs.maxAge);
  }
  if (prefs.dislikedGenres.length) {
    sql.push("NOT EXISTS (SELECT 1 FROM json_each(t.genres) g WHERE g.value IN (SELECT value FROM json_each(?)))");
    binds.push(JSON.stringify(prefs.dislikedGenres));
  }
  return { sql: sql.join(" AND "), binds };
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
