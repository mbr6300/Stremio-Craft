-- Titeldatenbank für Empfehlungen (eigene D1-Datenbank „stremio-craft-catalog“, Binding CATALOG).

-- Importstand und Sperre.
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- Kandidaten aus den IMDb-Datendateien (ab 6.0, genug Stimmen); daraus werden die Titel gewählt.
CREATE TABLE IF NOT EXISTS pool (
  imdb_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,          -- movie | tv
  year INTEGER,
  end_year INTEGER,
  runtime INTEGER,
  title_en TEXT,
  original_title TEXT,
  votes INTEGER NOT NULL,
  rating REAL NOT NULL,
  dach INTEGER NOT NULL DEFAULT 0,
  skip INTEGER NOT NULL DEFAULT 0, -- Talkshow, Nachrichten, Reality, Spielshow (sofern nicht sehr bekannt)
  score REAL NOT NULL,         -- Stimmen / Wurzel(Alter in Jahren + 1)
  picked INTEGER NOT NULL DEFAULT 0,
  run INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pool_rank ON pool (kind, picked, skip, score DESC);

-- Die gewählten Titel mit allen Angaben für die Auswahllogik.
CREATE TABLE IF NOT EXISTS titles (
  imdb_id TEXT PRIMARY KEY,
  id TEXT,                     -- "movie-<tmdb>" bzw. "tv-<tmdb>", wie in der App
  kind TEXT NOT NULL,
  tmdb_id INTEGER,
  run INTEGER NOT NULL,
  enriched INTEGER NOT NULL DEFAULT 0,
  ok INTEGER NOT NULL DEFAULT 0, -- vollständig (TMDB-Eintrag, Poster, Beschreibung)
  title TEXT,                  -- deutsch
  title_en TEXT,
  original_title TEXT,
  overview TEXT,
  poster TEXT,
  backdrop TEXT,
  year INTEGER,
  end_year INTEGER,
  genres TEXT NOT NULL DEFAULT '[]',   -- TMDB-Film-Genre-IDs (Serien-Mischgenres aufgeteilt)
  imdb_rating REAL,
  imdb_votes INTEGER,
  quality REAL,                -- gewichtete Bewertung
  score REAL,
  dach INTEGER NOT NULL DEFAULT 0,
  popularity REAL,
  language TEXT,
  countries TEXT NOT NULL DEFAULT '[]',
  cast_names TEXT NOT NULL DEFAULT '[]',
  crew_names TEXT NOT NULL DEFAULT '[]', -- Regie bzw. Schöpfer
  keywords TEXT NOT NULL DEFAULT '[]',
  age INTEGER,                 -- Altersfreigabe (FSK, sonst aus US-Freigabe abgeleitet)
  runtime INTEGER,             -- Minuten (bei Serien pro Folge)
  collection INTEGER,
  status TEXT,                 -- Serien: running | ended
  seasons INTEGER,
  episodes INTEGER,
  networks TEXT NOT NULL DEFAULT '[]',
  first_air TEXT,
  last_air TEXT,
  tags TEXT NOT NULL DEFAULT '' -- Merkmale für die Ähnlichkeit (siehe tags-Tabelle)
);
CREATE INDEX IF NOT EXISTS titles_id ON titles (id);
CREATE INDEX IF NOT EXISTS titles_quality ON titles (ok, quality DESC);
CREATE INDEX IF NOT EXISTS titles_todo ON titles (enriched, run, score DESC);

-- Volltextindex über die Merkmale (Stichworte, Personen, Reihe, Genres) für ähnliche Titel.
CREATE VIRTUAL TABLE IF NOT EXISTS tags USING fts5 (
  imdb_id UNINDEXED,
  body,
  tokenize = "unicode61 tokenchars '_'"
);

-- Titel, die in einer Region bei einem der Streaming-Anbieter der App im Abo laufen.
CREATE TABLE IF NOT EXISTS availability (
  region TEXT NOT NULL,
  id TEXT NOT NULL,
  run INTEGER NOT NULL,
  PRIMARY KEY (region, id)
);
