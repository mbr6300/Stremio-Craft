-- Verschlüsselte Datenblöcke je Sync-Space (ID = SHA-256 des Sync-Codes).
CREATE TABLE IF NOT EXISTS spaces (
  id TEXT PRIMARY KEY,
  version INTEGER NOT NULL,
  blob TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Kurzlebige Kopplungen per 6-stelliger PIN (10 Minuten gültig).
CREATE TABLE IF NOT EXISTS pairings (
  pin TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  payload TEXT,
  expires_at INTEGER NOT NULL
);
