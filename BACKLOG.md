# Backlog

Geplante Funktionen und Änderungen für Stremio Craft. Neue Einträge kommen unten in „Offen“;
Erledigtes wandert mit Version nach „Erledigt“.

## Offen

### iPad: Listen in den Einstellungen per Drag & Drop sortieren
Das Umsortieren der Listen ist heute auf Fernbedienung (Hoch/Runter) und Pfeil-Knöpfe ausgelegt
(`SettingsView.swift`). Auf dem iPad soll man Einträge mit dem Finger ziehen können; die Pfeile können
dort entfallen. tvOS-Bedienung bleibt wie sie ist.

### Reihe „Demnächst“ auf der Startseite
Kommende Folgen der Serien aus „Meine Liste“ nach Ausstrahlungsdatum, nutzt die vorhandenen
Episodendaten (`EpisodeInfo.airDate`).

### Weiterschauen auf dem Apple-TV-Homescreen (Top Shelf)
Top-Shelf-Erweiterung für tvOS: „Weiterschauen“ erscheint auf dem Homescreen, wenn die App oben im Dock
liegt; ein Klick öffnet direkt die Detailseite (`stremiocraft://detail/…`).

### Trakt-Anbindung
Watchlist und Verlauf mit Trakt abgleichen, damit auch andere Apps den Stand kennen.

### Ähnliche Titel im Detail
Reihe „Ähnlich wie …“ unter der Detailansicht, aus der eigenen Titeldatenbank (Worker `/v1/recommend`
mit dem Titel als einzigem Ausgangspunkt).

### Mindestbewertung als Filter für alle Listen
Einstellung „Titel unter IMDb … ausblenden“ (Standard 6.0): Titel mit tieferer IMDb-Bewertung erscheinen
in keiner Reihe und keinem Raster. Titel ohne bekannte Bewertung sichtbar lassen, damit Neuerscheinungen
nicht verschwinden.

### Empfehlungslogik verbessern
„Empfohlen für dich“ soll treffender werden. Offen zu klären: was heute nicht passt (Beispiele sammeln),
dann Gewichte und Ähnlichkeit im Worker (`cloudflare/sync-worker/src/recommend.js`) nachschärfen.

### Empfehlungen „Alle anzeigen“: auch beherzte Titel zeigen
Oben im Raster der Empfehlungen eine Umschaltung: „Nur neue Vorschläge“ (noch ohne ♥, wie heute)
oder „Mit Lieblingstiteln“ (beherzte Titel dazwischen).

## Erledigt

- Unveröffentlicht: eigene Titeldatenbank auf Cloudflare (rund 30'000 Filme und Serien, IMDb ab 6.0,
  alle 3 Monate neu) als Grundlage für „Empfohlen für dich“, Vorlieben im Profil, „Kein Interesse“.
  Abweichung vom Plan: Stichworte und Besetzung kommen von TMDB, weil IMDb Anfragen aus dem
  Cloudflare-Netz sperrt; Bewertungen, Art und Jahr aus den IMDb-Datendateien.
- Unveröffentlicht: Beschreibung im Detail ganz, Ton- und Untertitelsprache pro Profil, nächste Folge
  automatisch (integrierter Player), Stream-Regeln samt Merken pro Serie, Staffelfortschritt.
  „Gesehen pro Folge“ gab es teilweise schon (automatisch ab 92 %, von Hand); neu sind Fortschritt pro
  Staffel, ganze Staffel markieren und der Einstieg bei der ersten nicht fertigen Staffel.

- 1.0.2: tvOS-Kopfzeile per Fernbedienung bedienbar, Ausstrahlungsdaten bei Folgen,
  englischer Ton und Untertitel als Startwahl im integrierten Player.
