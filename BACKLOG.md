# Backlog

Geplante Funktionen und Änderungen für Stremio Craft. Neue Einträge kommen unten in „Offen“;
Erledigtes wandert mit Version nach „Erledigt“.

## Offen

### Detail: Beschreibung vollständig anzeigen
Der Lead-Text in der Detailansicht wird nach drei Zeilen abgeschnitten (`DetailView.swift`, `lineLimit(3)`),
obwohl dort genügend Platz ist. Ganz anzeigen; auf allen Plattformen prüfen, dass das Layout darunter nicht verrutscht.

### iPad: Listen in den Einstellungen per Drag & Drop sortieren
Das Umsortieren der Listen ist heute auf Fernbedienung (Hoch/Runter) und Pfeil-Knöpfe ausgelegt
(`SettingsView.swift`). Auf dem iPad soll man Einträge mit dem Finger ziehen können; die Pfeile können
dort entfallen. tvOS-Bedienung bleibt wie sie ist.

### Ton- und Untertitelsprache einstellbar
Heute startet der integrierte Player fest mit Englisch (`KSPlayerScreen.swift`). In den Einstellungen
pro Profil wählbar machen: Sprache für Ton, Sprache für Untertitel, Untertitel auch ganz aus.

### Nächste Folge automatisch
Am Ende einer Folge eine Karte „Nächste Folge in 10 s“ (abbrechbar), die mit derselben Quelle und
Qualität weiterspielt. Spätestens beim Abspann einblenden.

### Bevorzugte Quelle merken
Stream nach Regeln vorwählen (z. B. im Real-Debrid-Cache, 4K/HDR, maximale Grösse, Sprache), damit ein
Klick auf „Abspielen“ genügt. Die vollständige Liste bleibt erreichbar.

### Gesehen pro Folge
Folgen als gesehen markieren (automatisch ab ~90 % sowie von Hand), Fortschritt pro Staffel anzeigen,
im Detail „Weiter mit S2E5“. Über den Geräte-Sync abgleichen.

### Reihe „Demnächst“ auf der Startseite
Kommende Folgen der Serien aus „Meine Liste“ nach Ausstrahlungsdatum, nutzt die vorhandenen
Episodendaten (`EpisodeInfo.airDate`).

### Weiterschauen auf dem Apple-TV-Homescreen (Top Shelf)
Top-Shelf-Erweiterung für tvOS: „Weiterschauen“ erscheint auf dem Homescreen, wenn die App oben im Dock
liegt; ein Klick öffnet direkt die Detailseite (`stremiocraft://detail/…`).

### Trakt-Anbindung
Watchlist und Verlauf mit Trakt abgleichen, damit auch andere Apps den Stand kennen.

### Ähnliche Titel im Detail
Reihe „Ähnlich wie …“ unter der Detailansicht; zuerst über TMDB-Empfehlungen, später aus der eigenen
Filmdatenbank (siehe oben).

## Erledigt

- Unveröffentlicht: eigene Titeldatenbank auf Cloudflare (rund 30'000 Filme und Serien, IMDb ab 6.0,
  alle 3 Monate neu) als Grundlage für „Empfohlen für dich“, Vorlieben im Profil, „Kein Interesse“.
  Abweichung vom Plan: Stichworte und Besetzung kommen von TMDB, weil IMDb Anfragen aus dem
  Cloudflare-Netz sperrt; Bewertungen, Art und Jahr aus den IMDb-Datendateien.

- 1.0.2: tvOS-Kopfzeile per Fernbedienung bedienbar, Ausstrahlungsdaten bei Folgen,
  englischer Ton und Untertitel als Startwahl im integrierten Player.
