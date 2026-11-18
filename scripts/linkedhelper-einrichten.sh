#!/usr/bin/env bash
# =====================================================================
# LinkedHelper (bei Daniel) an die Datenbank anbinden.
#
#   scripts/linkedhelper-einrichten.sh
#
# Erzeugt einen geheimen Schlüssel, legt ihn in .env ab (gitignored), setzt
# ihn als Secret der Edge Functions und zeigt die zwei Adressen, die Daniel
# in LinkedHelper einträgt. Mehrfach ausführbar: der Schlüssel bleibt gleich.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
touch "$ENV"; chmod 600 "$ENV"
KEY=$(grep '^LINKEDHELPER_KEY=' "$ENV" | cut -d= -f2- || true)
if [ -z "$KEY" ]; then
  KEY=$(openssl rand -hex 24)
  printf 'LINKEDHELPER_KEY=%s\n' "$KEY" >> "$ENV"
fi
echo "Setze den Schlüssel als Secret der Edge Functions …"
TMP=$(mktemp); chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
printf 'LINKEDHELPER_KEY=%s\n' "$KEY" > "$TMP"
supabase secrets set --env-file "$TMP" --yes
BASIS="https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/linkedhelper-webhook?k=${KEY}"
echo
echo "Für Daniel – ADRESSE 1 (Aktion „Send person to webhook“):"
echo
echo "  ${BASIS}&art=profil"
echo
echo "Für Daniel – ADRESSE 2 (Plugin „Send replied to Webhook“):"
echo
echo "  ${BASIS}&art=antwort"
echo
echo "Die Adressen enthalten einen geheimen Schlüssel – nur an Daniel geben."
