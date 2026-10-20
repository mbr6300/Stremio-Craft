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

## Ratenbegrenzung

Eingebaut über die Workers-Rate-Limit-Bindings in `wrangler.toml` (auch unter `workers.dev` wirksam,
Dashboard-WAF-Regeln gehen dort nicht): Kopplung 60, Sync 120 Anfragen pro Minute und IP. Darüber
antwortet der Worker mit `429`. `sh test.sh <URL> --rate-limit` prüft das – danach ist die Kopplung
für die eigene IP eine Minute gesperrt.
