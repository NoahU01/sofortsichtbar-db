#!/usr/bin/env bash
# =====================================================================
# Cockpit-Zugang anlegen oder Passwort neu setzen.
#
#   scripts/zugang-anlegen.sh <email> ["Vor- und Nachname"]
#
# Erzeugt ein zufälliges Passwort, legt den Benutzer in Supabase Auth an
# (oder setzt bei bestehendem Benutzer das Passwort neu), schaltet die
# Adresse für das Cockpit frei (core.dashboard_zugang) und zeigt das
# Passwort EINMAL hier im Terminal. Es wird nirgends gespeichert.
# Der Admin-Schlüssel wird zur Laufzeit über die Supabase-CLI geholt und
# nur im Speicher dieses Skripts gehalten.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

EMAIL=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)
NAME="${2:-}"
if ! printf '%s' "$EMAIL" | grep -Eq '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'; then
  echo "Aufruf: scripts/zugang-anlegen.sh name@firma.de \"Vor- und Nachname\"" >&2; exit 1
fi
REF=udrcjopiixhlntmnsosj
URL="https://${REF}.supabase.co"

KEY=$(supabase projects api-keys --reveal --output-format json 2>/dev/null \
  | python3 -I -c 'import json,sys; print(next(k["api_key"] for k in json.load(sys.stdin)["keys"] if k["name"]=="service_role"))')
[ -n "$KEY" ] || { echo "Konnte den Admin-Schlüssel nicht holen (supabase login?)." >&2; exit 1; }

PASSWORT=$(python3 -I -c '
import secrets, string
a = string.ascii_letters + string.digits
while True:
    p = "".join(secrets.choice(a) for _ in range(20))
    if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p): print(p); break')

# Gibt es den Benutzer schon?
ID=$(curl -fsS "${URL}/auth/v1/admin/users?per_page=1000" -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" \
  | EMAIL="$EMAIL" python3 -I -c 'import json,os,sys; u=json.load(sys.stdin).get("users",[]); print(next((x["id"] for x in u if (x.get("email") or "").lower()==os.environ["EMAIL"]), ""))')

KOERPER=$(EMAIL="$EMAIL" PW="$PASSWORT" NAME="$NAME" python3 -I -c 'import json,os; print(json.dumps({"email": os.environ["EMAIL"], "password": os.environ["PW"], "email_confirm": True, "user_metadata": {"name": os.environ["NAME"]} if os.environ["NAME"] else {}}))')
if [ -n "$ID" ]; then
  curl -fsS -X PUT "${URL}/auth/v1/admin/users/${ID}" -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" -d "$KOERPER" >/dev/null
  WAS="Passwort neu gesetzt"
else
  curl -fsS -X POST "${URL}/auth/v1/admin/users" -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" -d "$KOERPER" >/dev/null
  WAS="Benutzer angelegt"
fi
unset KEY

# Für das Cockpit freischalten
NAME_SQL=$(printf '%s' "$NAME" | sed "s/'/''/g")
supabase db query --remote --yes "insert into core.dashboard_zugang (email, name) values ('${EMAIL}', nullif('${NAME_SQL}', '')) on conflict (email) do update set name = coalesce(excluded.name, core.dashboard_zugang.name)" >/dev/null

echo
echo "  ${WAS}: ${EMAIL}"
echo "  Passwort:  ${PASSWORT}"
echo
echo "  Login: https://sofortsichtbar-cockpit.vercel.app"
echo "  Das Passwort wird nirgends gespeichert – jetzt in den Passwort-Manager übernehmen."
