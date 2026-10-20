#!/bin/sh
# Rauchtest gegen einen laufenden Worker: sh test.sh [http://127.0.0.1:8787]
BASE="${1:-http://127.0.0.1:8787}"
ID=$(printf 'test-%s' "$(date +%s%N)" | shasum -a 256 | cut -d' ' -f1)
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (erwartet $3, erhalten $2)"; FAILED=1; fi; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check "unbekannter Space → 404" "$(status "$BASE/v1/space/$ID")" 404
check "erstes Speichern → 200" "$(status -X PUT -H 'Content-Type: application/json' -d '{"version":0,"blob":"AAA"}' "$BASE/v1/space/$ID")" 200
check "Laden → 200" "$(status "$BASE/v1/space/$ID")" 200
check "If-None-Match → 304" "$(status -H 'If-None-Match: "1"' "$BASE/v1/space/$ID")" 304
check "Speichern mit Version 1 → 200" "$(status -X PUT -d '{"version":1,"blob":"BBB"}' "$BASE/v1/space/$ID")" 200
check "veraltete Version → 409" "$(status -X PUT -d '{"version":1,"blob":"CCC"}' "$BASE/v1/space/$ID")" 409
check "ungültige ID → 400" "$(status "$BASE/v1/space/xyz")" 400

PIN=$(curl -s -X POST -d '{"publicKey":"cHVibGljLWtleQ=="}' "$BASE/v1/pair" | sed -n 's/.*"pin":"\([0-9]*\)".*/\1/p')
check "Kopplung angelegt" "$(echo "$PIN" | grep -c '^[0-9]\{6\}$')" 1
check "Kopplung lesen → 200" "$(status "$BASE/v1/pair/$PIN")" 200
check "Kopplung beantworten → 204" "$(status -X PUT -d '{"payload":"secret"}' "$BASE/v1/pair/$PIN")" 204
check "zweite Antwort → 409" "$(status -X PUT -d '{"payload":"other"}' "$BASE/v1/pair/$PIN")" 409
check "Kopplung löschen → 204" "$(status -X DELETE "$BASE/v1/pair/$PIN")" 204
check "gelöschte Kopplung → 404" "$(status "$BASE/v1/pair/$PIN")" 404
check "Space löschen → 204" "$(status -X DELETE "$BASE/v1/space/$ID")" 204
if [ "$2" = "--rate-limit" ]; then
  # Absichtlich zu viele Kopplungsanfragen: nach gut 60 pro Minute kommt 429
  # (Cloudflare zählt pro Rechenzentrum und setzt mit kurzer Verzögerung durch).
  LIMITED=0
  for i in $(seq 1 150); do
    [ "$(status "$BASE/v1/pair/000000")" = "429" ] && LIMITED=1 && break
  done
  check "Ratenbegrenzung Kopplung → 429" "$LIMITED" 1
fi
[ -z "$FAILED" ] && echo "Alle Tests bestanden."
