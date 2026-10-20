#!/bin/sh
# Baut Stremio Craft und lädt es zu TestFlight hoch (nur interne Tester).
#
#   scripts/testflight.sh            # Apple TV, iPad und Mac
#   scripts/testflight.sh tvos ios   # nur bestimmte Plattformen (tvos | ios | mac)
#
# Zugangsdaten: BuildSupport/testflight.env (siehe testflight.env.example).
set -eu
cd "$(dirname "$0")/.."

ENV_FILE=BuildSupport/testflight.env
if [ ! -f "$ENV_FILE" ]; then
  echo "Fehlt: $ENV_FILE – siehe BuildSupport/testflight.env.example" >&2
  exit 1
fi
. "$ENV_FILE"
[ -f "$ASC_KEY_PATH" ] || { echo "API-Schlüssel nicht gefunden: $ASC_KEY_PATH" >&2; exit 1; }
[ -f StremioCraft/LocalSecrets.plist ] || { echo "Fehlt: StremioCraft/LocalSecrets.plist (TMDB-Schlüssel, Sync-Server)" >&2; exit 1; }

# Fortlaufende Build-Nummer: Datum und Uhrzeit plus Plattform-Ziffer (.1 tvOS, .2 iPad, .3 Mac).
# Mac Catalyst und iPad teilen sich die Bundle-ID und dürfen keine gleichen Nummern haben.
STAMP=$(date +%Y%m%d%H%M)
PLATFORMS=${*:-"tvos ios mac"}

xc() {
  xcodebuild "$@" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

# FFmpegKit (KSPlayer) bringt für Mac Catalyst statische Bibliotheken in flachen iOS-Framework-
# Hüllen mit. Xcode linkt den Code fest ein und kopiert nur leere Platzhalter mit, die App Store
# Connect auf dem Mac als „Malformed Framework“ (ITMS-90291/90292) ablehnt. Die App verweist nicht
# darauf – vor dem Export (der neu signiert) aus dem Archiv entfernen.
strip_ffmpeg_stubs() {
  app="$1/Products/Applications/StremioCraft.app"
  binary="$app/Contents/MacOS/StremioCraft"
  for fw in "$app"/Contents/Frameworks/*.framework; do
    [ -f "$fw/Info.plist" ] || continue # nur flache Hüllen; echte macOS-Frameworks bleiben
    fwname=$(basename "$fw" .framework)
    if otool -L "$binary" | grep -q "/$fwname.framework/"; then
      echo "  ⚠︎ $fwname.framework wird verwendet – bleibt" >&2
      continue
    fi
    rm -rf "$fw"
    echo "  – $fwname.framework (Platzhalter) entfernt"
  done
}

upload() {
  name=$1
  destination=$2
  BUILD="$STAMP.$3"
  archive="build/archives/StremioCraft-$name-$BUILD.xcarchive"
  echo "▶︎ $name: Archiv (Build $BUILD)"
  xc -project StremioCraft.xcodeproj -scheme StremioCraft -configuration Release \
     -destination "$destination" -archivePath "$archive" -derivedDataPath build/archive \
     CURRENT_PROJECT_VERSION="$BUILD" archive -quiet
  [ "$name" = Mac ] && strip_ffmpeg_stubs "$archive"
  echo "▶︎ $name: Upload zu App Store Connect"
  xc -exportArchive -archivePath "$archive" -exportPath "build/export/$name-$BUILD" \
     -exportOptionsPlist BuildSupport/ExportOptions-TestFlight.plist
  echo "✓ $name hochgeladen"
}

for platform in $PLATFORMS; do
  case $platform in
    tvos) upload tvOS "generic/platform=tvOS" 1 ;;
    ios) upload iOS "generic/platform=iOS" 2 ;;
    mac) upload Mac "generic/platform=macOS,variant=Mac Catalyst" 3 ;;
    *) echo "Unbekannte Plattform: $platform (tvos | ios | mac)" >&2; exit 1 ;;
  esac
done

# Neue Teammitglieder (z. B. nach testflight-invite.swift) in die Gruppe „Familie“ übernehmen.
echo "▶︎ Testgruppe „Familie“ aktualisieren"
swift scripts/testflight-setup.swift || echo "  (Gruppe konnte nicht aktualisiert werden – später erneut ausführen)"

echo "Fertig. Die Builds erscheinen nach der Verarbeitung (meist 5–15 Minuten) in TestFlight."
