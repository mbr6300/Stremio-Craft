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

### Eigene Titeldatenbank (Top 30'000) auf Cloudflare als Grundlage für Empfehlungen
Datenbank mit den bekanntesten rund 30'000 Titeln (Filme und Serien) anlegen. Die Empfehlungsliste
greift darauf zurück, nicht nur auf das, was Streaming-Anbieter gerade im Angebot haben.
- Liegt auf Cloudflare, nicht in der App: D1-Datenbank mit einem Worker davor (wie der Geräte-Sync);
  die App fragt nur gefilterte Ausschnitte ab.
- Befüllt und alle 3 Monate aktualisiert per geplantem Worker-Lauf (Cron) aus TMDB; der TMDB-Schlüssel
  bleibt als Secret im Worker.
- Metadaten für die Auswahllogik, für alle Titel: TMDB/IMDb-ID, Art (Film/Serie), Titel (de/en), Jahr,
  Genres, Bewertung und Stimmenzahl, Popularität, Originalsprache, Produktionsland, Hauptdarsteller,
  Stichworte (TMDB-Keywords), Altersfreigabe.
  - Nur Filme: Laufzeit, Regie, Sammlung/Reihe.
  - Nur Serien: Status (laufend/beendet), Anzahl Staffeln und Folgen, Sender, erste und letzte
    Ausstrahlung, Folgenlänge, Schöpfer.
- Auswahl der 30'000 Titel:
  - Bekanntheit nach Stimmenzahl, ergänzt durch die frei verfügbaren IMDb-Daten (`title.ratings`,
    Stimmen pro Titel).
  - Getrennte Anteile, damit Serien nicht von Filmen verdrängt werden: etwa 20'000 Filme und 10'000 Serien.
  - Neuere Titel nach Stimmen pro Jahr seit Erscheinen werten, sonst fehlen die letzten zwei Jahre.
  - Eigenes Kontingent für deutschsprachige Produktionen (DE/CH/AT), die international weniger Stimmen haben.
  - Ausschliessen: Titel ohne Poster oder Beschreibung, Erwachseneninhalte, bei Serien Talkshows,
    Nachrichten und Reality-Formate (sofern nicht sehr bekannt).
- Vorlieben im Profil (alle optional):
  - Lieblings- und unerwünschte Genres.
  - Bevorzugte Jahrzehnte.
  - Sprache: Originalsprachen, die ohne Untertitel gehen.
  - Maximale Laufzeit bzw. Folgenlänge.
  - Mindestbewertung.
  - Höchste Altersfreigabe (z. B. für ein Kinderprofil, als harter Filter).
  - Lieblingsschauspieler und -regie.
- Empfehlungslogik:
  - Harte Filter: Altersfreigabe, unerwünschte Genres, bereits Gesehenes.
  - Grundwert: Qualität als gewichtete Bewertung, damit Titel mit wenigen Stimmen nicht zu hoch landen.
  - Passung zu den Profilvorlieben.
  - Ähnlichkeit zu Titeln aus „Meine Liste“, „Weiterschauen“ und Gesehenem über Genres, Stichworte,
    Darsteller und Regie.
  - Bonus, wenn der Titel bei den eigenen Streaming-Anbietern der Region verfügbar ist.
  - Daumen hoch/runter auf Titeln als zusätzliches Signal.
  - Vielfalt: nicht mehrere Teile derselben Reihe oder lauter Titel eines Genres nacheinander.
  - Die Berechnung läuft im Worker, die App erhält nur die fertige Liste pro Profil.

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

- 1.0.2: tvOS-Kopfzeile per Fernbedienung bedienbar, Ausstrahlungsdaten bei Folgen,
  englischer Ton und Untertitel als Startwahl im integrierten Player.
