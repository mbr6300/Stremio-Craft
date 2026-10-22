# Änderungen

Neuerungen kommen laufend unter „Unveröffentlicht“. `scripts/testflight.sh` zählt beim Hochladen die
Version hoch (1.0.2 → 1.0.3), macht aus diesem Abschnitt den Eintrag der neuen Version und zeigt
ihn den Testern in TestFlight unter „Was ist zu testen?“. Ohne Eintrag lädt das Skript nichts hoch.

## Unveröffentlicht

- Empfehlungen: „Empfohlen für dich“ kommt aus einer eigenen Datenbank mit rund 30'000 Filmen und Serien (IMDb ab 6.0) und berücksichtigt ♥, Meine Liste, Gesehenes und die Vorlieben des Profils.
- Profile: Vorlieben einstellbar – Genres, Jahrzehnte, Sprachen, Länge, Mindestbewertung, Altersfreigabe, Lieblingsschauspieler und -regie.
- „Kein Interesse“ (👎) in der Detailansicht und im Kontextmenü: Der Titel und Ähnliches verschwinden aus den Empfehlungen.
- Detailansicht: Die Beschreibung wird ganz angezeigt.
- Profile: Ton- und Untertitelsprache für den integrierten Player wählbar (auch „Original“ bzw. Untertitel aus).
- Integrierter Player: Am Ende einer Folge erscheint „Nächste Folge in 10 s“ – startet die nächste Folge automatisch, abbrechbar.
- Einstellungen → Stream-Auswahl: höchste Auflösung, HDR, grösste Datei und Sprache bestimmen, welcher Stream vorne steht und automatisch startet; bei Serien wird die zuletzt gewählte Gruppe bevorzugt.
- Serien: Staffeln zeigen den Fortschritt („Staffel 2 · 4/10“, „Staffel 1 ✓“), lassen sich ganz als gesehen markieren, und die Detailseite beginnt bei der ersten nicht fertigen Staffel.

## 1.0.2 – 2026-10-21

- Apple TV: Die Knöpfe oben rechts (Alle/Filme/Serien, Region, Profil) lassen sich mit der Fernbedienung erreichen.
- Serien: Jede Folge zeigt ihr Ausstrahlungsdatum; kommende Folgen sind orange markiert.
- Integrierter Player: startet mit englischem Ton und englischen Untertiteln, sofern vorhanden.
