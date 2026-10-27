# Änderungen

Neuerungen kommen laufend unter „Unveröffentlicht“. `scripts/testflight.sh` zählt beim Hochladen die
Version hoch (1.0.2 → 1.0.3), macht aus diesem Abschnitt den Eintrag der neuen Version und zeigt
ihn den Testern in TestFlight unter „Was ist zu testen?“. Ohne Eintrag lädt das Skript nichts hoch.

## Unveröffentlicht

- Neu im Menü: YouTube ohne Werbung und ohne Ablenkung. Kanäle suchen und abonnieren, ihre neuesten Videos erscheinen unter „Neu von deinen Abos“ – ohne Shorts und ohne Vorschläge. Die Abos gelten auf allen Geräten, und die App merkt sich, wo du aufgehört hast. Gibt YouTube ein Video gerade nur eingeschränkt frei, läuft es in 360p.
- iPhone, iPad und Mac: Unter YouTube → „Web“ gibt es zusätzlich die echte YouTube-Seite mit Werbeblocker. Dort kannst du dich mit deinem Google-Konto anmelden und deine eigenen Abos, Playlists und Kommentare nutzen; Shorts und Vorschläge bleiben ausgeblendet.
- Schauspieler und Regie: Auf der Detailseite steht neu die Reihe „Regie & Besetzung“ mit Fotos. Ein Klick auf eine Person zeigt ihre Filme und Serien – bei der Regie ihre anderen Filme, bei Schauspielern alles, worin sie mitspielen.
- Der integrierte Player ist jetzt überall voreingestellt (auch auf Apple TV und iPad). Wer lieber Infuse oder VLC nutzt, stellt das in den Einstellungen wieder um.

## 1.0.7 – 2026-10-25

- Neu auch fürs iPhone: Stremio Craft läuft jetzt auf dem iPhone, mit angepassten Grössen. Die Knöpfe auf der Detailseite lassen sich seitlich wischen, Kategorien stehen zu zweit nebeneinander.

## 1.0.6 – 2026-10-24

- Meine Mediathek mit mehreren Quellen: z. B. NAS und Mac mini nebeneinander. Server im Heimnetz findet die App von selbst – in den Einstellungen erscheinen sie als „Im Netzwerk gefunden“, du gibst nur noch Benutzer und Passwort ein.
- Mac mini als Mediathek: Das Skript `scripts/mac-mini-webdav.sh` gibt einen Filmordner auf dem Mac frei (nur lesen, mit Passwort) und kündigt ihn im Heimnetz an.

## 1.0.5 – 2026-10-24

- Meine Mediathek: Das NAS lässt sich jetzt auch unter seinem Namen (z. B. …synology.me) mit selbstsigniertem Zertifikat einbinden, nicht nur über die IP-Adresse.
- Einstellungen: Jeder Zugang zeigt auf einen Blick, ob er funktioniert – grünes Häkchen = eingerichtet und geprüft, orangener Kreis = fehlt noch, rotes Warnzeichen = Fehler (Real-Debrid, TMDB, Torrentio, Mediathek, Geräte-Sync). Dazu mehr Abstand zwischen den Abschnitten und besser lesbare Titel.

## 1.0.4 – 2026-10-24

- Meine Mediathek: Eigene Filme und Serien vom NAS (z. B. Synology) direkt in der App ansehen. Im Menü gibt es dafür den neuen Punkt „Meine Mediathek“; eingerichtet wird sie unter Einstellungen → „Meine Mediathek (NAS)“ mit Adresse, Benutzer und Passwort. Ordner lassen sich durchblättern, Videos starten im gewohnten Player, und die App merkt sich, wo du aufgehört hast.

## 1.0.3 – 2026-10-22

- Bessere Empfehlungen: „Empfohlen für dich“ wählt jetzt aus rund 30'000 gut bewerteten Filmen und Serien und richtet sich nach dem, was du magst, gemerkt oder schon geschaut hast.
- Deine Vorlieben im Profil: Lieblingsgenres, Jahrzehnte, Sprachen, Länge, Mindestbewertung, Altersgrenze (gut für Kinderprofile) und Lieblingsschauspieler.
- Neuer Daumen nach unten 👎: Titel, die dich nicht interessieren, und Ähnliches tauchen in den Empfehlungen nicht mehr auf.
- Nächste Folge: Am Ende einer Folge läuft nach 10 Sekunden automatisch die nächste – mit „Abbrechen“ lässt sich das stoppen.
- Sprache pro Profil: Jedes Profil wählt selbst, mit welchem Ton und welchen Untertiteln der Player startet (Untertitel auch ganz aus).
- Passender Stream: In den Einstellungen unter „Stream-Auswahl“ legst du fest, was dir wichtig ist (z. B. höchstens 1080p oder lieber deutscher Ton). Bei Serien nimmt die App wieder einen ähnlichen Stream wie bei der letzten Folge.
- Serien-Fortschritt: Die Staffeln zeigen, wie viel du gesehen hast („Staffel 1 ✓“, „Staffel 2 · 4/10“). Eine ganze Staffel lässt sich auf einmal als gesehen markieren, und die Seite öffnet direkt bei der Staffel, mit der du weitermachst.
- Die Beschreibung eines Films oder einer Serie wird jetzt ganz angezeigt.

## 1.0.2 – 2026-10-21

- Apple TV: Die Knöpfe oben rechts (Alle/Filme/Serien, Region, Profil) lassen sich mit der Fernbedienung erreichen.
- Serien: Jede Folge zeigt ihr Ausstrahlungsdatum; kommende Folgen sind orange markiert.
- Integrierter Player: startet mit englischem Ton und englischen Untertiteln, sofern vorhanden.
