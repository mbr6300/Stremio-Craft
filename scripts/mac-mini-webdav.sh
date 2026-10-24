#!/bin/bash
# Macht einen Ordner auf dem Mac (z. B. Mac mini) für „Meine Mediathek“ in Stremio Craft verfügbar:
# WebDAV-Server (rclone, nur lesen, mit Passwort) plus Bonjour-Ankündigung, damit die App ihn im
# Heimnetz von selbst findet. Läuft als LaunchAgent und startet nach jeder Anmeldung neu.
#
#   scripts/mac-mini-webdav.sh ~/Movies            # einrichten (Port 8090)
#   scripts/mac-mini-webdav.sh ~/Movies 8091       # anderer Port
#   scripts/mac-mini-webdav.sh --remove            # wieder entfernen
#
# Danach in der App: Einstellungen → Meine Mediathek → „Im Netzwerk gefunden: …“, Benutzer „stremio“
# und das unten ausgegebene Passwort eintragen. Damit es zuverlässig läuft, in den Systemeinstellungen
# unter „Energie“ verhindern, dass der Mac in den Ruhezustand geht (bzw. „Bei Netzwerkzugriff aufwachen“).
set -euo pipefail

LABEL="ch.stremiocraft.webdav"
SUPPORT="$HOME/Library/Application Support/StremioCraftWebDAV"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
USER_NAME="stremio"

if [ "${1:-}" = "--remove" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  rm -rf "$SUPPORT"
  echo "Entfernt."
  exit 0
fi

FOLDER="${1:?Ordner angeben, z. B. ~/Movies}"
PORT="${2:-8090}"
FOLDER="$(cd "$FOLDER" && pwd)"

if ! command -v rclone >/dev/null; then
  if ! command -v brew >/dev/null; then
    echo "rclone fehlt. Homebrew installieren (https://brew.sh) und das Skript erneut starten." >&2
    exit 1
  fi
  echo "▶︎ rclone installieren (Homebrew)"
  brew install rclone
fi
RCLONE="$(command -v rclone)"

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"

# Passwort einmal zufällig erzeugen; bei erneutem Ausführen bleibt es gleich.
if [ ! -f "$SUPPORT/password" ]; then
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 >"$SUPPORT/password"
  chmod 600 "$SUPPORT/password"
fi
PASSWORD="$(cat "$SUPPORT/password")"
htpasswd -bcB "$SUPPORT/htpasswd" "$USER_NAME" "$PASSWORD" 2>/dev/null
chmod 600 "$SUPPORT/htpasswd"

NAME="$(scutil --get ComputerName) Mediathek"
cat >"$SUPPORT/run.sh" <<EOF
#!/bin/bash
# Von launchd gestartet: Bonjour-Ankündigung und WebDAV-Server (nur lesen).
/usr/bin/dns-sd -R "$NAME" _webdav._tcp local $PORT path=/ >/dev/null &
ANNOUNCE=\$!
trap 'kill \$ANNOUNCE 2>/dev/null' EXIT
"$RCLONE" serve webdav "$FOLDER" --addr ":$PORT" --htpasswd "$SUPPORT/htpasswd" --read-only \
  --dir-cache-time 1m --log-file "$SUPPORT/webdav.log" --log-level NOTICE
EOF
chmod 700 "$SUPPORT/run.sh"

cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$SUPPORT/run.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

HOST="$(scutil --get LocalHostName).local"
echo
echo "✓ Mediathek läuft: http://$HOST:$PORT/  (Ordner: $FOLDER)"
echo "  In der App erscheint sie als „$NAME“."
echo "  Benutzer: $USER_NAME"
echo "  Passwort: $PASSWORD"
echo "  Beim ersten Start fragt macOS eventuell, ob eingehende Verbindungen erlaubt sind – zulassen."
