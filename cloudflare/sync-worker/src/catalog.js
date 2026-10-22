// Titeldatenbank: die bekanntesten rund 30'000 Filme und Serien (IMDb ab 6.0) mit den Angaben,
// die die Empfehlungen brauchen.
//
// Der Import läuft per Cron (jede Minute ein Schritt, braucht Workers Paid wegen der Rechenzeit)
// und beginnt alle 3 Monate von vorn. Bestehende Titel bleiben währenddessen nutzbar und werden ersetzt.
// Die IMDb-Schnittstelle sperrt Anfragen aus dem Cloudflare-Netz; darum kommen Bewertungen, Art und
// Jahr aus den offiziellen IMDb-Datendateien und alles Weitere von TMDB.
//
// Phasen: datasets → dach → select → enrich → providers → finalize → idle
//   datasets   IMDb-Dateien (Bewertungen, Titel): ab 6.0, genug Stimmen, ohne Erwachseneninhalte → pool
//   dach       Deutschsprachige Produktionen (DE/CH/AT) über TMDB markieren – eigenes Kontingent
//   select     Rang = Stimmen / √(Alter + 1); Kontingente Filme/Serien, deutschsprachig zuerst
//   enrich     TMDB: deutsche Titel, Poster, Genres, Reihe, Stichworte, Besetzung, Freigabe, Sender
//   providers  Verfügbarkeit bei den Streaming-Anbietern der App je Region
//   finalize   Nicht mehr gewählte Titel entfernen, nächsten Lauf planen

const MOVIE_QUOTA = 20_000;
const TV_QUOTA = 10_000;
const DACH_MOVIES = 1_500;
const DACH_TV = 500;
const OVERSELECT = 1.05; // Reserve für Titel ohne TMDB-Eintrag, Poster oder Beschreibung
// Stimmen: allgemein bzw. für deutschsprachige Produktionen, die international weniger bewertet werden.
const MIN_VOTES = { movie: 1000, tv: 500 };
const MIN_VOTES_DACH = { movie: 300, tv: 200 };
const REFRESH_MS = 90 * 24 * 60 * 60 * 1000;
const LOCK_MS = 15 * 60 * 1000;
const TV_SKIPPED_GENRES = ["Talk-Show", "News", "Reality-TV", "Game-Show"];
const VERY_KNOWN = 50_000; // Stimmen, ab denen auch solche Serien bleiben
// Netflix, Disney+, Prime Video (2 IDs), HBO/Max, Paramount+, Hulu – wie TMDBClient.providers in der App.
const PROVIDERS = "8|337|9|119|1899|531|15";
const REGIONS = ["CH", "DE", "AT", "US", "GB", "FR", "IT"];
const DATASETS = "https://datasets.imdbws.com";
const PARALLEL = 6; // gleichzeitige TMDB-Anfragen (Workers erlauben 6 offene Verbindungen)

export const QUALITY_PRIOR = { votes: 10_000, rating: 6.8 };

/// Ein Importschritt; wird vom Cron-Trigger jede Minute aufgerufen.
export async function runImportStep(env) {
  const db = env.CATALOG;
  if (!db || !env.TMDB_API_KEY) return;
  if (!(await acquireLock(db))) return;
  // Unter der Grenze von 1000 externen Anfragen pro Lauf (Workers Paid).
  const limits = {
    dachPages: Number(env.IMPORT_DACH_PAGES ?? 40),
    enrichBatch: Number(env.IMPORT_ENRICH_BATCH ?? 250),
    providerPages: Number(env.IMPORT_PROVIDER_PAGES ?? 400),
  };
  let state = await loadState(db);
  try {
    if (state.phase === "idle") {
      if (Date.now() < (state.nextRunAt ?? 0)) return;
      state = { phase: "datasets", run: (state.run ?? 0) + 1, startedAt: Date.now(), nextRunAt: state.nextRunAt };
    }
    await PHASES[state.phase](env, state, limits);
    state.error = null;
  } catch (error) {
    // Nichts weiterschalten – der nächste Lauf versucht denselben Schritt erneut.
    state.error = String(error?.message ?? error).slice(0, 500);
    state.errorAt = Date.now();
  } finally {
    await saveState(db, state);
    await db.prepare("UPDATE meta SET value = '0' WHERE key = 'lock'").run();
  }
}

export async function catalogStatus(env) {
  const db = env.CATALOG;
  const state = await loadState(db);
  const counts = await db.prepare(
    "SELECT kind, COUNT(*) AS total, SUM(ok) AS ready FROM titles GROUP BY kind"
  ).all();
  const { dachQueue, providerQueue, ...rest } = state;
  return {
    ...rest,
    dachOpen: dachQueue?.length,
    providersOpen: providerQueue?.length,
    titles: Object.fromEntries(counts.results.map((r) => [r.kind, { total: r.total, ready: r.ready }])),
  };
}

const PHASES = { datasets, dach, select, enrich, providers, finalize };

// MARK: - Phasen

async function datasets(env, state) {
  const db = env.CATALOG;
  const ratings = new Map();
  for await (const line of tsvLines(`${DATASETS}/title.ratings.tsv.gz`)) {
    const [id, rating, votes] = line.split("\t");
    const value = Number(rating);
    const count = Number(votes);
    if (value >= 6 && count >= MIN_VOTES_DACH.tv) ratings.set(id, [value, count]);
  }
  if (ratings.size < 10_000) throw new Error(`IMDb-Bewertungen unvollständig (${ratings.size})`);

  const year = new Date().getUTCFullYear();
  let statements = [];
  let count = 0;
  for await (const line of tsvLines(`${DATASETS}/title.basics.tsv.gz`)) {
    const id = line.slice(0, line.indexOf("\t"));
    const rated = ratings.get(id);
    if (!rated) continue;
    const [, type, primaryTitle, originalTitle, adult, start, end, runtime, genreList] = line.split("\t");
    const kind = type === "movie" ? "movie" : (type === "tvSeries" || type === "tvMiniSeries" ? "tv" : null);
    if (!kind || adult === "1") continue;
    const [rating, votes] = rated;
    if (votes < MIN_VOTES_DACH[kind]) continue;
    const released = nullable(start);
    const genres = genreList === "\\N" ? [] : genreList.split(",");
    const skip = kind === "tv" && votes < VERY_KNOWN && genres.some((g) => TV_SKIPPED_GENRES.includes(g));
    const score = votes / Math.sqrt(Math.max(1, year - (released ?? year) + 1));
    statements.push(db.prepare(
      `INSERT INTO pool (imdb_id, kind, year, end_year, runtime, title_en, original_title, votes, rating, dach, skip, score, run)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
       ON CONFLICT(imdb_id) DO UPDATE SET kind = excluded.kind, year = excluded.year, end_year = excluded.end_year,
         runtime = excluded.runtime, title_en = excluded.title_en, original_title = excluded.original_title,
         votes = excluded.votes, rating = excluded.rating, dach = 0, skip = excluded.skip, score = excluded.score,
         picked = 0, run = excluded.run`
    ).bind(id, kind, released, nullable(end), nullable(runtime), primaryTitle, originalTitle, votes, rating, skip ? 1 : 0, score, state.run));
    if (statements.length === 500) {
      await db.batch(statements);
      count += statements.length;
      statements = [];
    }
  }
  if (statements.length) await db.batch(statements);
  state.poolSize = count + statements.length;
  state.phase = "dach";
  state.dachQueue = [
    { kind: "movie", page: 1, last: 100 },
    { kind: "tv", page: 1, last: 50 },
  ];
}

/// Deutschsprachige Produktionen nach TMDB-Herkunftsland; IMDb-ID über external_ids.
async function dach(env, state, limits) {
  const db = env.CATALOG;
  let budget = limits.dachPages;
  while (budget > 0) {
    const item = state.dachQueue[0];
    if (!item) {
      state.phase = "select";
      return;
    }
    const pages = Math.min(budget, item.last - item.page + 1, 10);
    const results = await mapLimited(Array.from({ length: pages }, (_, i) => item.page + i), PARALLEL, (page) =>
      tmdb(env, `/discover/${item.kind}`, {
        with_origin_country: "DE|CH|AT",
        sort_by: "vote_count.desc",
        "vote_count.gte": "20",
        page: String(page),
      }));
    const ids = results.flatMap((r) => (r?.results ?? []).map((entry) => entry.id));
    const external = await mapLimited(ids, PARALLEL, (id) => tmdb(env, `/${item.kind}/${id}/external_ids`));
    const statements = external
      .map((e) => e?.imdb_id)
      .filter(Boolean)
      .map((imdbId) => db.prepare("UPDATE pool SET dach = 1 WHERE imdb_id = ? AND run = ?").bind(imdbId, state.run));
    if (statements.length) await db.batch(statements);
    item.last = Math.min(item.last, results[0]?.total_pages ?? 1);
    item.page += pages;
    budget -= pages;
    if (item.page > item.last) state.dachQueue.shift();
  }
}

async function select(env, state) {
  const db = env.CATALOG;
  const run = state.run;
  await db.prepare("UPDATE pool SET picked = 0 WHERE picked = 1").run();
  for (const [kind, quota, dachQuota] of [["movie", MOVIE_QUOTA, DACH_MOVIES], ["tv", TV_QUOTA, DACH_TV]]) {
    const dachPicked = await db.prepare(
      `UPDATE pool SET picked = 1 WHERE imdb_id IN (SELECT imdb_id FROM pool
         WHERE kind = ? AND run = ? AND dach = 1 AND skip = 0 ORDER BY score DESC LIMIT ?)`
    ).bind(kind, run, Math.round(dachQuota * OVERSELECT)).run();
    await db.prepare(
      `UPDATE pool SET picked = 1 WHERE imdb_id IN (SELECT imdb_id FROM pool
         WHERE kind = ? AND run = ? AND picked = 0 AND skip = 0 AND votes >= ? ORDER BY score DESC LIMIT ?)`
    ).bind(kind, run, MIN_VOTES[kind], Math.max(0, Math.round(quota * OVERSELECT) - dachPicked.meta.changes)).run();
  }
  await db.prepare(
    `INSERT INTO titles (imdb_id, kind, run, year, end_year, runtime, title_en, original_title, imdb_rating, imdb_votes, score, dach)
       SELECT imdb_id, kind, run, year, end_year, runtime, title_en, original_title, rating, votes, score, dach
       FROM pool WHERE picked = 1 AND run = ?
     ON CONFLICT(imdb_id) DO UPDATE SET kind = excluded.kind, run = excluded.run, year = excluded.year,
       end_year = excluded.end_year, runtime = excluded.runtime, title_en = excluded.title_en,
       original_title = excluded.original_title, imdb_rating = excluded.imdb_rating,
       imdb_votes = excluded.imdb_votes, score = excluded.score, dach = excluded.dach, enriched = 0`
  ).bind(run).run();
  state.phase = "enrich";
}

async function enrich(env, state, limits) {
  const db = env.CATALOG;
  const rows = (await db.prepare(
    `SELECT imdb_id, kind, year, end_year, runtime, title_en, original_title, imdb_rating, imdb_votes
     FROM titles WHERE enriched = 0 AND run = ? ORDER BY score DESC LIMIT ?` // Bekannteste zuerst nutzbar
  ).bind(state.run, limits.enrichBatch).all()).results;
  if (!rows.length) {
    state.phase = "providers";
    state.providerQueue = REGIONS.flatMap((region) => ["movie", "tv"].map((kind) => ({ region, kind, page: 1 })));
    return;
  }
  const enriched = await mapLimited(rows, PARALLEL, (row) => tmdbDetails(env, row));
  const statements = [];
  for (const [index, row] of rows.entries()) {
    const t = enriched[index];
    statements.push(db.prepare(
      `UPDATE titles SET id = ?, kind = ?, tmdb_id = ?, enriched = 1, ok = ?, title = ?, overview = ?, poster = ?,
         backdrop = ?, genres = ?, quality = ?, popularity = ?, language = ?, countries = ?, cast_names = ?,
         crew_names = ?, keywords = ?, age = ?, runtime = ?, collection = ?, status = ?, seasons = ?, episodes = ?,
         networks = ?, first_air = ?, last_air = ?, tags = ?
       WHERE imdb_id = ?`
    ).bind(
      t.id, t.kind, t.tmdbId, t.ok ? 1 : 0, t.title, t.overview, t.poster, t.backdrop, JSON.stringify(t.genres),
      t.quality, t.popularity, t.language, JSON.stringify(t.countries), JSON.stringify(t.cast), JSON.stringify(t.crew),
      JSON.stringify(t.keywords), t.age, t.runtime, t.collection, t.status, t.seasons, t.episodes,
      JSON.stringify(t.networks), t.firstAir, t.lastAir, t.tags, row.imdb_id
    ));
    statements.push(db.prepare("DELETE FROM tags WHERE imdb_id = ?").bind(row.imdb_id));
    if (t.ok) statements.push(db.prepare("INSERT INTO tags (imdb_id, body) VALUES (?, ?)").bind(row.imdb_id, t.tags));
  }
  await db.batch(statements);
}

async function providers(env, state, limits) {
  const db = env.CATALOG;
  let budget = limits.providerPages;
  while (budget > 0) {
    const item = state.providerQueue[0];
    if (!item) {
      state.phase = "finalize";
      return;
    }
    // Erste Seite allein (liefert die Seitenzahl), danach mehrere parallel.
    const pages = item.total ? Math.min(budget, item.total - item.page + 1, 20) : 1;
    const results = await mapLimited(Array.from({ length: pages }, (_, i) => item.page + i), PARALLEL, (page) =>
      tmdb(env, `/discover/${item.kind}`, {
        watch_region: item.region,
        with_watch_providers: PROVIDERS,
        with_watch_monetization_types: "flatrate",
        sort_by: "vote_count.desc",
        "vote_count.gte": "30",
        page: String(page),
      }));
    const statements = [];
    for (const result of results) {
      for (const entry of result?.results ?? []) {
        const id = `${item.kind}-${entry.id}`;
        statements.push(db.prepare(
          `INSERT INTO availability (region, id, run) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM titles WHERE id = ?)
           ON CONFLICT(region, id) DO UPDATE SET run = excluded.run`
        ).bind(item.region, id, state.run, id));
      }
    }
    if (statements.length) await db.batch(statements);
    item.total = Math.min(results[0]?.total_pages ?? 1, 500);
    item.page += pages;
    budget -= pages;
    if (item.page > item.total) state.providerQueue.shift();
  }
}

async function finalize(env, state) {
  const db = env.CATALOG;
  const run = state.run;
  // Über die Kontingente hinaus Gewählte (Reserve) entfernen: deutschsprachige zuerst behalten.
  const trims = [["movie", MOVIE_QUOTA], ["tv", TV_QUOTA]].map(([kind, quota]) => db.prepare(
    `UPDATE titles SET run = run - 1 WHERE imdb_id IN (SELECT imdb_id FROM titles WHERE kind = ? AND run = ? AND ok = 1
       ORDER BY dach DESC, score DESC LIMIT -1 OFFSET ?)`
  ).bind(kind, run, quota));
  await db.batch([
    ...trims,
    db.prepare("DELETE FROM titles WHERE run < ? OR ok = 0").bind(run),
    db.prepare("DELETE FROM tags WHERE imdb_id NOT IN (SELECT imdb_id FROM titles)"),
    db.prepare("DELETE FROM availability WHERE run < ?").bind(run),
    db.prepare("DELETE FROM pool WHERE run < ?").bind(run),
  ]);
  state.phase = "idle";
  state.finishedAt = Date.now();
  state.nextRunAt = state.startedAt + REFRESH_MS;
  delete state.dachQueue;
  delete state.providerQueue;
}

// MARK: - IMDb-Datendateien

/// Zeilen einer gzip-komprimierten TSV-Datei, ohne Kopfzeile, gestreamt.
async function* tsvLines(url) {
  const response = await fetch(url);
  if (!response.ok || !response.body) throw new Error(`IMDb-Datei ${response.status}: ${url}`);
  const reader = response.body.pipeThrough(new DecompressionStream("gzip")).pipeThrough(new TextDecoderStream()).getReader();
  let rest = "";
  let header = true;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    const parts = (rest + value).split("\n");
    rest = parts.pop();
    if (header) {
      parts.shift();
      header = false;
    }
    yield* parts;
  }
  if (rest) yield rest;
}

function nullable(value) {
  return value === "\\N" || value === undefined ? null : Number(value);
}

// MARK: - TMDB

/// TMDB erlaubt rund 40 Anfragen pro Sekunde; bei 429 kurz warten und erneut versuchen.
async function tmdb(env, path, query = {}) {
  const url = new URL(`https://api.themoviedb.org/3${path}`);
  url.searchParams.set("api_key", env.TMDB_API_KEY);
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  for (let attempt = 0; ; attempt++) {
    const response = await fetch(url);
    if (response.status === 404) return null;
    if (response.status === 429 && attempt < 4) {
      await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
      continue;
    }
    if (!response.ok) throw new Error(`TMDB ${response.status} ${path}`);
    return response.json();
  }
}

/// Wie `Promise.all(items.map(fn))`, aber höchstens `limit` gleichzeitig.
async function mapLimited(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index], index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

// Serien-Mischgenres auf Film-Genres abbilden, damit Vorlieben für beide gelten.
const TV_GENRES = { 10759: [28, 12], 10765: [878, 14], 10768: [10752], 10762: [10751], 10766: [18], 10767: [], 10763: [], 10764: [] };
const US_AGES = { G: 0, PG: 6, "PG-13": 12, R: 16, "NC-17": 18, "TV-Y": 0, "TV-Y7": 6, "TV-G": 0, "TV-PG": 6, "TV-14": 12, "TV-MA": 16 };

async function tmdbDetails(env, row) {
  const base = {
    id: null, kind: row.kind, tmdbId: null, ok: false, title: null, overview: null, poster: null, backdrop: null,
    genres: [], quality: quality(row.imdb_rating, row.imdb_votes), popularity: null, language: null, countries: [],
    cast: [], crew: [], keywords: [], age: null, runtime: row.runtime ?? null, collection: null, status: null,
    seasons: null, episodes: null, networks: [], firstAir: null, lastAir: null, tags: "",
  };
  // Filme lassen sich direkt über die IMDb-ID abrufen, Serien nur über /find.
  let kind = row.kind;
  let tmdbId = null;
  if (kind === "tv") {
    const found = await tmdb(env, `/find/${row.imdb_id}`, { external_source: "imdb_id" });
    tmdbId = found?.tv_results?.[0]?.id ?? null;
    if (!tmdbId && found?.movie_results?.[0]) {
      kind = "movie";
      tmdbId = found.movie_results[0].id;
    }
    if (!tmdbId) return base;
  }
  const detail = await tmdb(env, `/${kind}/${tmdbId ?? row.imdb_id}`, {
    language: "de-DE",
    append_to_response: kind === "movie" ? "release_dates,keywords,credits" : "content_ratings,keywords,credits",
  });
  if (!detail?.id) return base;
  let overview = detail.overview?.trim() || null;
  if (!overview) {
    const english = await tmdb(env, `/${kind}/${detail.id}`, { language: "en-US" });
    overview = english?.overview?.trim() || null;
  }
  const certification = (results, key) => {
    for (const country of ["DE", "CH", "AT"]) {
      const value = key((results ?? []).find((r) => r.iso_3166_1 === country));
      const age = value && Number.parseInt(String(value).replace(/\D/g, ""), 10);
      if (Number.isInteger(age)) return age;
    }
    const us = key((results ?? []).find((r) => r.iso_3166_1 === "US"));
    return US_AGES[us] ?? null;
  };
  const credits = detail.credits ?? {};
  const t = {
    ...base,
    kind,
    id: `${kind}-${detail.id}`,
    tmdbId: detail.id,
    title: detail.title ?? detail.name ?? null,
    overview,
    poster: detail.poster_path ?? null,
    backdrop: detail.backdrop_path ?? null,
    genres: [...new Set((detail.genres ?? []).flatMap((g) => TV_GENRES[g.id] ?? [g.id]))],
    popularity: detail.popularity ?? null,
    language: detail.original_language ?? null,
    countries: detail.origin_country ?? (detail.production_countries ?? []).map((c) => c.iso_3166_1),
    cast: (credits.cast ?? []).slice(0, 5).map((c) => c.name).filter(Boolean),
    keywords: (detail.keywords?.keywords ?? detail.keywords?.results ?? []).slice(0, 15).map((k) => k.name).filter(Boolean),
    age: kind === "movie"
      ? certification(detail.release_dates?.results, (e) => e?.release_dates?.map((d) => d.certification).find(Boolean))
      : certification(detail.content_ratings?.results, (e) => e?.rating),
    collection: detail.belongs_to_collection?.id ?? null,
  };
  if (kind === "movie") {
    t.crew = (credits.crew ?? []).filter((c) => c.job === "Director").map((c) => c.name).slice(0, 3);
    t.runtime = detail.runtime || base.runtime;
  } else {
    t.crew = (detail.created_by ?? []).map((c) => c.name).slice(0, 3);
    t.runtime = detail.episode_run_time?.[0] || base.runtime;
    t.status = ["Ended", "Canceled"].includes(detail.status) ? "ended" : "running";
    t.seasons = detail.number_of_seasons ?? null;
    t.episodes = detail.number_of_episodes ?? null;
    t.networks = (detail.networks ?? []).map((n) => n.name).filter(Boolean).slice(0, 3);
    t.firstAir = detail.first_air_date || null;
    t.lastAir = detail.last_air_date || null;
  }
  t.ok = Boolean(t.title && t.poster && t.overview);
  t.tags = tagsFor(t);
  return t;
}

// MARK: - Merkmale

/// Merkmale als Wörter für den Volltextindex: k_ Stichwort, p_ Person, c_ Reihe, g_ Genre.
export function tagsFor(t) {
  const words = [
    ...t.keywords.map((k) => `k_${token(k)}`),
    ...[...t.cast, ...t.crew].map((p) => `p_${token(p)}`),
    ...(t.collection ? [`c_${t.collection}`] : []),
    ...t.genres.map((g) => `g_${g}`),
  ];
  return [...new Set(words.filter((w) => w.length > 2))].join(" ");
}

export function token(text) {
  return String(text).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

export function quality(rating, votes) {
  const { votes: m, rating: c } = QUALITY_PRIOR;
  return (votes / (votes + m)) * rating + (m / (votes + m)) * c;
}

// MARK: - Zustand

async function loadState(db) {
  const row = await db.prepare("SELECT value FROM meta WHERE key = 'import'").first();
  return row ? JSON.parse(row.value) : { phase: "idle", run: 0, nextRunAt: 0 };
}

async function saveState(db, state) {
  await db.prepare("INSERT INTO meta (key, value) VALUES ('import', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    .bind(JSON.stringify(state)).run();
}

/// Verhindert, dass sich zwei Cron-Läufe überlappen.
async function acquireLock(db) {
  const now = Date.now();
  await db.prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('lock', '0')").run();
  const result = await db.prepare("UPDATE meta SET value = ? WHERE key = 'lock' AND CAST(value AS INTEGER) < ?")
    .bind(String(now + LOCK_MS), now).run();
  return result.meta.changes === 1;
}
