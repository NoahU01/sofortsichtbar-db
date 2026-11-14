#!/usr/bin/env bash
# =====================================================================
# Richtet den täglichen Abruf von Search Console, GA4 und Bing ein.
#
#   scripts/suche-einrichten.sh ~/Downloads/<dienstkonto>.json
#
# Was passiert:
#   1. Schlüssel kommen in .env (gitignored, nur für dich lesbar):
#      Dienstkonto (base64), GA4-Property, Bing-Schlüssel, Import-Secret.
#   2. Diese Werte werden als Secrets der Edge Functions gesetzt.
#   3. Das Import-Secret kommt in den Supabase Vault (für den Zeitplan).
#   4. Erster Abruf: 16 Monate Search Console, Bing komplett.
# Erneut ausführen ist unschädlich (z. B. um später Bing nachzutragen).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
touch "$ENV"; chmod 600 "$ENV"

setze() {   # setze NAME WERT – ersetzt eine vorhandene Zeile
  grep -v "^$1=" "$ENV" > "$ENV.tmp" || true
  mv "$ENV.tmp" "$ENV"; chmod 600 "$ENV"
  printf '%s=%s\n' "$1" "$2" >> "$ENV"
}

if [ -n "${1:-}" ]; then
  [ -f "$1" ] || { echo "Datei nicht gefunden: $1"; exit 1; }
  setze GOOGLE_DIENSTKONTO_B64 "$(base64 < "$1" | tr -d '\n')"
  echo "Dienstkonto übernommen: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["client_email"])' "$1")"
fi
grep -q '^IMPORT_SECRET=' "$ENV" || setze IMPORT_SECRET "$(openssl rand -hex 32)"

read -r -p "GA4-Property-Nummer (Enter = überspringen): " GA4
[ -n "$GA4" ] && setze GA4_PROPERTY "$GA4"
read -r -s -p "Bing-API-Schlüssel (Eingabe unsichtbar, Enter = überspringen): " BING; echo
[ -n "$BING" ] && setze BING_API_KEY "$BING"

echo "Setze Secrets der Edge Functions …"
supabase secrets set --env-file "$ENV"

S=$(grep '^IMPORT_SECRET=' "$ENV" | cut -d= -f2)
echo "Lege Import-Secret im Vault ab …"
supabase db query --remote --yes "select vault.update_secret(id, '$S') from vault.secrets where name = 'suche_import'" > /dev/null
supabase db query --remote --yes "select vault.create_secret('$S', 'suche_import', 'Aufruf von suche-import per pg_cron') where not exists (select 1 from vault.secrets where name = 'suche_import')" > /dev/null

echo "Erster Abruf (kann eine Minute dauern) …"
sleep 5   # Secrets brauchen einen Moment, bis die Function sie sieht
curl -s -X POST "https://udrcjopiixhlntmnsosj.supabase.co/functions/v1/suche-import" \
  -H "x-import-secret: $S" -H "Content-Type: application/json" -d '{"tage": 480}' \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
for q in ("google","ga4","bing"):
    v=d.get(q); print(f"  {q:7}", v if isinstance(v,str) else ("FEHLER: "+v["fehler"] if "fehler" in v else "ok – "+json.dumps(v)))
if d.get("dienstkonto"): print("  Dienstkonto:", d["dienstkonto"])'
echo "Fertig. Ab jetzt täglich um 05:30 UTC automatisch."
