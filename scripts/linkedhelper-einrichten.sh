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
echo "ADRESSE 1 – Vernetzungs-Kampagne, Aktion „Send person to webhook“ nach angenommener Einladung:"
echo "  ${BASIS}&art=vernetzung"
echo
echo "ADRESSE 2 – Vernetzungs-Kampagne, Plugin „Send replied to Webhook“:"
echo "  ${BASIS}&art=antwort"
echo
echo "ADRESSE 3 – Sammel-Kampagnen „Beitrags-Interaktionen“ und „Follower Firmenseite“:"
echo "  ${BASIS}&art=profil"
echo
echo "Die Adressen enthalten einen geheimen Schlüssel – nur an Daniel geben."
