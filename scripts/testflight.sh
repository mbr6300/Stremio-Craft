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

# Fortlaufende Build-Nummer: Datum und Uhrzeit, für alle Plattformen eines Laufs gleich.
BUILD=$(date +%Y%m%d%H%M)
PLATFORMS=${*:-"tvos ios mac"}

xc() {
  xcodebuild "$@" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

upload() {
  name=$1
  destination=$2
  archive="build/archives/StremioCraft-$name-$BUILD.xcarchive"
  echo "▶︎ $name: Archiv (Build $BUILD)"
  xc -project StremioCraft.xcodeproj -scheme StremioCraft -configuration Release \
     -destination "$destination" -archivePath "$archive" -derivedDataPath build/archive \
     CURRENT_PROJECT_VERSION="$BUILD" archive -quiet
  echo "▶︎ $name: Upload zu App Store Connect"
  xc -exportArchive -archivePath "$archive" -exportPath "build/export/$name-$BUILD" \
     -exportOptionsPlist BuildSupport/ExportOptions-TestFlight.plist
  echo "✓ $name hochgeladen"
}

for platform in $PLATFORMS; do
  case $platform in
    tvos) upload tvOS "generic/platform=tvOS" ;;
    ios) upload iOS "generic/platform=iOS" ;;
    mac) upload Mac "generic/platform=macOS,variant=Mac Catalyst" ;;
    *) echo "Unbekannte Plattform: $platform (tvos | ios | mac)" >&2; exit 1 ;;
  esac
done

echo "Fertig. Die Builds erscheinen nach der Verarbeitung (meist 5–15 Minuten) in TestFlight."
