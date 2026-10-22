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

### Eigene Filmdatenbank (Top 10'000) als Grundlage für Empfehlungen
Datenbank mit den bekanntesten rund 10'000 Filmen anlegen. Die Empfehlungsliste greift darauf zurück,
nicht nur auf das, was Streaming-Anbieter gerade im Angebot haben.
- Pro Film Metadaten, die für die Auswahllogik taugen: TMDB/IMDb-ID, Titel (de/en), Jahr, Genres,
  Laufzeit, Bewertung und Stimmenzahl, Popularität, Originalsprache, Produktionsland, Regie,
  Hauptdarsteller, Stichworte (TMDB-Keywords), Altersfreigabe, Sammlung/Reihe.
- Offen zu klären: Auswahlkriterium für „die bekanntesten“ (z. B. Stimmenzahl), wo die Daten liegen
  (in der App mitgeliefert oder über den Sync-Worker), wie oft sie aktualisiert werden.

## Erledigt

- 1.0.2: tvOS-Kopfzeile per Fernbedienung bedienbar, Ausstrahlungsdaten bei Folgen,
  englischer Ton und Untertitel als Startwahl im integrierten Player.
