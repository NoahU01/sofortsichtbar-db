#!/usr/bin/env bash
# =====================================================================
# Legt den Zugang für den Newsletter-Versand über Amazon SES ab
# (IAM-Benutzer „cockpit-newsletter“ → Zugriffsschlüssel).
#
#   scripts/ses-einrichten.sh
#
# Schlüssel-ID und geheimer Schlüssel werden unsichtbar eingegeben, bei
# SES (Frankfurt) geprüft, in .env gespeichert (gitignored, nur für dich
# lesbar) und als Secrets der Edge Functions gesetzt.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
REGION=eu-central-1
touch "$ENV"; chmod 600 "$ENV"

read -r -s -p "Zugriffsschlüssel-ID (beginnt mit AKIA, unsichtbar): " KID; echo
read -r -s -p "Geheimer Zugriffsschlüssel (unsichtbar): " KSEC; echo
[ -n "$KID" ] && [ -n "$KSEC" ] || { echo "Nicht beides eingegeben."; exit 1; }

echo "Prüfe den Zugang bei Amazon SES (Frankfurt) …"
ANTWORT=$(mktemp)
CODE=$(curl -s -o "$ANTWORT" -w "%{http_code}" \
  --aws-sigv4 "aws:amz:$REGION:ses" --user "$KID:$KSEC" \
  "https://email.$REGION.amazonaws.com/v2/email/account")
if [ "$CODE" != "200" ]; then
  echo "  SES antwortet mit $CODE:"; head -c 300 "$ANTWORT"; echo; rm -f "$ANTWORT"; exit 1
fi
python3 -I -c "
import json,sys
d=json.load(open(sys.argv[1]))
q=d.get('SendQuota',{})
print('  Zugang ok.')
print('  Echter Versand freigegeben:', 'ja' if d.get('ProductionAccessEnabled') else 'NEIN (noch Testmodus – nur bestätigte Adressen)')
print('  Kontingent: %d Mails / 24 h, %d pro Sekunde' % (q.get('Max24HourSend',0), q.get('MaxSendRate',0)))
" "$ANTWORT"
rm -f "$ANTWORT"

grep -v -E '^(SES_ACCESS_KEY_ID|SES_SECRET_ACCESS_KEY|SES_REGION)=' "$ENV" > "$ENV.tmp" || true
mv "$ENV.tmp" "$ENV"; chmod 600 "$ENV"
printf 'SES_ACCESS_KEY_ID=%s\nSES_SECRET_ACCESS_KEY=%s\nSES_REGION=%s\n' "$KID" "$KSEC" "$REGION" >> "$ENV"

echo "Setze Secrets der Edge Functions …"
supabase secrets set --env-file "$ENV"
echo "Fertig."
