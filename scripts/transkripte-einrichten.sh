#!/usr/bin/env bash
# =====================================================================
# Ordner für Call-Transkripte an den Import anbinden.
#
#   scripts/transkripte-einrichten.sh
#
# Fragt driveId und id des Ordners ab (aus dem Graph Explorer, siehe
# Anleitung) und setzt sie als Secrets der Edge Functions. Keine Schlüssel.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
read -r -p "driveId (beginnt meist mit b!): " DRIVE
read -r -p "id des Ordners: " ORDNER
DRIVE=$(printf '%s' "$DRIVE" | tr -d '"[:space:]'); ORDNER=$(printf '%s' "$ORDNER" | tr -d '"[:space:]')
[ -n "$DRIVE" ] && [ -n "$ORDNER" ] || { echo "Beides wird gebraucht." >&2; exit 1; }
TMP=$(mktemp); chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
printf 'MS_TRANSKRIPT_DRIVE=%s\nMS_TRANSKRIPT_ORDNER=%s\n' "$DRIVE" "$ORDNER" > "$TMP"
supabase secrets set --env-file "$TMP" --yes >/dev/null
echo "Eingerichtet. Neue Dateien im Ordner werden alle 15 Minuten abgeholt und erscheinen im Cockpit unter Calls."
