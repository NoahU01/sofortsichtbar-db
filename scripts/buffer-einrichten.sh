#!/usr/bin/env bash
# =====================================================================
# Legt den Buffer-API-Schlüssel ab (Buffer → Einstellungen → API).
#
#   scripts/buffer-einrichten.sh
#
# Der Schlüssel wird unsichtbar eingegeben, in .env gespeichert
# (gitignored, nur für dich lesbar), kurz bei Buffer geprüft und als
# Secret der Edge Functions gesetzt.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
touch "$ENV"; chmod 600 "$ENV"

read -r -s -p "Buffer-API-Schlüssel (unsichtbar): " K; echo
[ -n "$K" ] || { echo "Kein Schlüssel eingegeben."; exit 1; }

echo "Prüfe den Schlüssel bei Buffer …"
CODE=$(curl -s -o /tmp/buffer-pruefung.json -w "%{http_code}" -X POST https://api.buffer.com \
  -H "Authorization: Bearer $K" -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}')
rm -f /tmp/buffer-pruefung.json
if [ "$CODE" != "200" ]; then echo "  Buffer antwortet mit $CODE – Schlüssel prüfen."; exit 1; fi
echo "  Schlüssel ok."

grep -v '^BUFFER_API_KEY=' "$ENV" > "$ENV.tmp" || true
mv "$ENV.tmp" "$ENV"; chmod 600 "$ENV"
printf 'BUFFER_API_KEY=%s\n' "$K" >> "$ENV"

echo "Setze Secrets der Edge Functions …"
supabase secrets set --env-file "$ENV"
echo "Fertig."
