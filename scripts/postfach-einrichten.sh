#!/usr/bin/env bash
# =====================================================================
# Legt die Zugangsdaten für Microsoft 365 (Postfächer + Kalender) ab.
#
#   scripts/postfach-einrichten.sh
#
# Fragt Verzeichnis-ID (Mandant), Anwendungs-ID (Client) und den geheimen
# Clientschlüssel ab, schreibt sie in .env (gitignored, nur für dich lesbar)
# und setzt sie als Secrets der Edge Functions. Der Schlüssel wird unsichtbar
# eingegeben und nirgends angezeigt. Erneut ausführen ist unschädlich
# (Enter = vorhandenen Wert behalten).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
touch "$ENV"; chmod 600 "$ENV"

setze() {
  grep -v "^$1=" "$ENV" > "$ENV.tmp" || true
  mv "$ENV.tmp" "$ENV"; chmod 600 "$ENV"
  printf '%s=%s\n' "$1" "$2" >> "$ENV"
}

read -r -p "Verzeichnis-ID (Mandant): " T;          [ -n "$T" ] && setze MS_TENANT_ID "$T"
read -r -p "Anwendungs-ID (Client): " C;            [ -n "$C" ] && setze MS_CLIENT_ID "$C"
read -r -s -p "Geheimer Clientschlüssel – der WERT (unsichtbar): " S; echo
[ -n "$S" ] && setze MS_CLIENT_SECRET "$S"
read -r -p "Postfach-Domain [sofortsichtbar.de]: " D; setze MS_DOMAIN "${D:-sofortsichtbar.de}"

for k in MS_TENANT_ID MS_CLIENT_ID MS_CLIENT_SECRET; do
  grep -q "^$k=" "$ENV" || { echo "Fehlt noch: $k"; exit 1; }
done

echo "Prüfe die Anmeldung bei Microsoft …"
TID=$(grep '^MS_TENANT_ID=' "$ENV" | cut -d= -f2)
CID=$(grep '^MS_CLIENT_ID=' "$ENV" | cut -d= -f2)
CSE=$(grep '^MS_CLIENT_SECRET=' "$ENV" | cut -d= -f2-)
ANTWORT=$(curl -s -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSE" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" --data-urlencode "grant_type=client_credentials")
if echo "$ANTWORT" | grep -q '"access_token"'; then
  echo "  Anmeldung ok."
else
  echo "  Anmeldung fehlgeschlagen:"; echo "$ANTWORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ", d.get("error"), "-", (d.get("error_description") or "")[:200])'
  exit 1
fi

echo "Setze Secrets der Edge Functions …"
supabase secrets set --env-file "$ENV"
echo "Fertig."
