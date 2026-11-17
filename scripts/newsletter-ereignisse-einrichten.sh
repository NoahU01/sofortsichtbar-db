#!/usr/bin/env bash
# =====================================================================
# Rückmeldungen von Amazon SES (Zustellung, Bounce, Spam-Beschwerde)
# an die Datenbank anbinden.
#
#   scripts/newsletter-ereignisse-einrichten.sh
#
# Erzeugt einen geheimen Schlüssel, legt ihn in .env ab (gitignored), setzt
# ihn als Secret der Edge Functions, merkt sich den Namen des SES-
# Konfigurationssatzes und zeigt die Adresse, die in AWS beim SNS-Abo
# eingetragen wird.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
touch "$ENV"; chmod 600 "$ENV"

KEY=$(grep '^NEWSLETTER_EREIGNIS_KEY=' "$ENV" | cut -d= -f2- || true)
if [ -z "$KEY" ]; then
  KEY=$(openssl rand -hex 24)
  printf 'NEWSLETTER_EREIGNIS_KEY=%s\n' "$KEY" >> "$ENV"
fi
grep -q '^SES_CONFIG_SET=' "$ENV" || printf 'SES_CONFIG_SET=newsletter\n' >> "$ENV"

echo "Setze Secrets der Edge Functions …"
supabase secrets set --env-file "$ENV"

REF=udrcjopiixhlntmnsosj
echo
echo "Diese Adresse in AWS beim SNS-Abonnement (Protokoll HTTPS) als Endpunkt eintragen:"
echo
echo "  https://${REF}.supabase.co/functions/v1/newsletter-ereignisse?k=${KEY}"
echo
echo "Name des SES-Konfigurationssatzes: newsletter"
