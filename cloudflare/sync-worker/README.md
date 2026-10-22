# Stremio Craft – Sync-Worker

Cloudflare-Worker mit D1-Datenbank für den Geräte-Sync. Er speichert nur verschlüsselte Datenblöcke
(die App verschlüsselt mit einem Schlüssel aus dem Sync-Code) und kurzlebige Kopplungs-PINs.

## Einmalig veröffentlichen

```sh
cd cloudflare/sync-worker
npx wrangler login
npx wrangler d1 create stremio-craft-sync          # ausgegebene database_id in wrangler.toml eintragen
npx wrangler d1 execute stremio-craft-sync --remote --file schema.sql
npx wrangler deploy                                 # → https://stremio-craft-sync.<subdomain>.workers.dev
sh test.sh https://stremio-craft-sync.<subdomain>.workers.dev
```

Danach die Adresse in `StremioCraft/LocalSecrets.plist` (nicht im Repository) eintragen und die Apps
neu bauen:

```xml
<key>SYNC_URL</key>
<string>https://stremio-craft-sync.<subdomain>.workers.dev</string>
```

Alternativ lässt sich die Adresse in der App unter Einstellungen → Geräte-Sync eintragen.

## Lokal testen

```sh
npx wrangler d1 execute stremio-craft-sync --local --file schema.sql
npx wrangler dev --port 8787
sh test.sh
```

Simulatoren erreichen den lokalen Worker unter `http://127.0.0.1:8787`
(in der App als Sync-Server eintragen oder per Startargument `-syncServerURL http://127.0.0.1:8787`).

## Titeldatenbank für Empfehlungen

Eigene D1-Datenbank `stremio-craft-catalog` (Binding `CATALOG`, Schema `catalog-schema.sql`) mit den
bekanntesten rund 30'000 Filmen und Serien (IMDb ab 6.0). Der Cron-Trigger füllt sie Schritt für
Schritt (`src/catalog.js`) und beginnt alle 3 Monate von vorn; `POST /v1/recommend` berechnet daraus
die Empfehlungen (`src/recommend.js`). Braucht **Workers Paid** (Einlesen der IMDb-Datendateien).

Einmalig einrichten:

```sh
npx wrangler d1 create stremio-craft-catalog      # database_id in wrangler.toml eintragen
npx wrangler d1 execute stremio-craft-catalog --remote --file catalog-schema.sql
plutil -extract TMDB_API_KEY raw ../../StremioCraft/LocalSecrets.plist | npx wrangler secret put TMDB_API_KEY
npx wrangler deploy
```

Stand des Imports: `curl https://stremio-craft-sync.<subdomain>.workers.dev/v1/catalog/status`.
Lokal: TMDB-Schlüssel in `.dev.vars` (`TMDB_API_KEY=…`), dann `npx wrangler dev --test-scheduled`
und Schritte mit `curl "http://127.0.0.1:8787/__scheduled?cron=*+*+*+*+*"` auslösen.

IMDb sperrt Anfragen aus dem Cloudflare-Netz an seine Schnittstelle (429); darum stammen Bewertungen,
Art und Jahr aus den offiziellen Datendateien (datasets.imdbws.com), alles Weitere von TMDB.

## Ratenbegrenzung

Eingebaut über die Workers-Rate-Limit-Bindings in `wrangler.toml` (auch unter `workers.dev` wirksam,
Dashboard-WAF-Regeln gehen dort nicht): Kopplung 60, Sync 120 Anfragen pro Minute und IP. Darüber
antwortet der Worker mit `429`. `sh test.sh <URL> --rate-limit` prüft das – danach ist die Kopplung
für die eigene IP eine Minute gesperrt.
