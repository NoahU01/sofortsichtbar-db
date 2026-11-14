# sofortsichtbar-db

Zentrale Marketing- & Vertriebsdatenbank für Sofortsichtbar (Supabase).
Hintergrund und Zielbild: internes Briefing (liegt nur lokal unter `docs/briefing.md`).

## Aufbau

| Schema | Inhalt |
|---|---|
| `core` | contacts (CRM), companies, identities, event_types, events, consents |
| `scoring` | signals (Katalog aus `daten/signale.csv`), später Score-Views |
| `raw` | Roh-Payloads je Quelle: cal_webhooks |
| `analytics` | Aggregate wie search_queries, post_metrics (folgt) |
| `agent` | recommendations (folgt) |

Kein Schema ist für `anon`/`authenticated` freigegeben. Zugriff nur serverseitig
(Edge Functions, Service-Role). RLS ist überall an.

**Identity-Stitching** steckt in der Datenbank selbst: Ein Event mit bekannter
`visitor_id` wird beim Einfügen dem Kontakt zugeordnet. Kommt eine neue bestätigte
`visitor_id` hinzu (Formular, Newsletter-Klick, Termin), werden alle früheren
anonymen Events dieses Besuchers rückwirkend zugeordnet.

**Löschen:** `select core.delete_contact('<uuid>');` entfernt den Kontakt mit allen
Identitäten, Events, Einwilligungen und rohen Cal.com-Webhooks.
Website-Events ohne Kontakt löscht ein täglicher pg_cron-Job nach 24 Monaten
(so steht es in der Datenschutzerklärung).

## Quellen

| Quelle | Weg | Ergebnis |
|---|---|---|
| Website | `sofortsichtbar.de/api/track` (Vercel, Repo sofortsichtbar) → `public.ingest_events` | Events mit visitor_id (nur mit Einwilligung) |
| Cal.com | Webhook → Edge Function `cal-webhook` (HMAC-Prüfung) → `public.ingest_cal_webhook` | Kontakt + E-Mail-Identität + meeting_booked/rescheduled/canceled/no_show |
| Calls (ChatGPT-Transkripte) | Seite „sofort sichtbar · Calls“ in Daniels empiria-dashboard → Edge Function `dashboard` → `public.dashboard_*` | `core.calls` (Volltextsuche deutsch) + call_recorded in der Timeline |

| Search Console + GA4 | Edge Function `suche-import` (Dienstkonto, täglich 05:30 UTC per pg_cron) → `public.ingest_suche` | `analytics.suchbegriffe`, `analytics.suche_tage`, `analytics.ga4_tage` |
| Bing Webmaster Tools | dieselbe Function (API-Schlüssel) | wie oben, Suchbegriffe wochenweise |

| Microsoft 365 (Mails, Kalender) | Edge Function `postfach-import` (App-Registrierung, Mail/Kalender per Exchange-RBAC auf @sofortsichtbar.de begrenzt, alle 15 min) → `public.ingest_postfach` | `core.mails`, `core.kalender`, mail_received/mail_sent/calendar_meeting |

| LinkedIn-Reaktionen (Firmenseite, Daniel) | Reaktionsliste in LinkedIn kopieren → Cockpit „LinkedIn“ → `public.dashboard_linkedin_erfassen` | `core.linkedin_beitraege/_personen/_reaktionen`; zugeordnete Personen → linkedin_reaction |

LinkedIn: Kein API-Weg für Namen – Buffer liefert nur Summen, die Community
Management API verbietet CRM-/Lead-Nutzung und erlaubt nur 48 h Speicherung.
Darum Einfügen von Hand; Zuordnung zu Kontakten nur bestätigt (Name ist kein
sicherer Schlüssel). `reaktionen_laut_buffer` füllt später der Buffer-Import.

Einrichten Microsoft 365: `scripts/postfach-einrichten.sh`. In Entra nur `User.Read.All`
(Anwendung) vergeben – Mail.Read/Calendars.Read NICHT in Entra, sondern per
`New-ManagementRoleAssignment` mit Bereich `sofortsichtbar-postfaecher`, sonst gilt der
Zugriff für alle Postfächer des Mandanten.

Einrichten der Suchquellen: `scripts/suche-einrichten.sh <dienstkonto.json>` (setzt
Secrets, Vault-Eintrag, erster Abruf). Jeder Abruf steht in `analytics.import_laeufe`.

Verknüpfung Website ↔ Termin: Der Browser meldet `meeting_booked` mit
`properties.booking_uid`. Gleiche uid im Webhook ⇒ die visitor_id wird dem
Kontakt zugeordnet, alle früheren Besuche hängen rückwirkend an ihm. Die
Reihenfolge, in der Webhook und Browser-Event ankommen, ist egal.

**Dashboard-Brücke:** Die Function `dashboard` prüft das Login-Token beim
Supabase-Projekt des empiria-dashboards (`/auth/v1/user`) und dann, ob die
E-Mail in `core.dashboard_zugang` steht. Zugang geben:
`insert into core.dashboard_zugang (email, name) values ('…', '…');`

**Cal.com einrichten:** Settings → Developer → Webhooks → New.
Subscriber-URL `https://<ref>.supabase.co/functions/v1/cal-webhook`, Trigger
Booking Created / Rescheduled / Cancelled / No-Show Updated, Secret = Wert von
`CAL_WEBHOOK_SECRET` (lokal in `.env`, gitignored; in Supabase per
`supabase secrets set --env-file .env`). Function deployen:
`supabase functions deploy cal-webhook --use-api --no-verify-jwt`.

## Cockpit

Eigene Oberfläche: https://sofortsichtbar-cockpit.vercel.app (Ordner `cockpit/`,
Vercel-Projekt `sofortsichtbar-cockpit`, baut bei jedem Push auf `main`).
Bereiche: Website (eigenes Tracking), Suche, LinkedIn, Kontakte (Timeline, Bearbeiten), Postfach, Calls.
Login per Login-Link, nur angelegte Konten; Zugriff zusätzlich nur mit Eintrag
in `core.dashboard_zugang`. Neues Konto: Nutzer in Supabase Auth anlegen
(Dashboard → Authentication → Add user) und E-Mail in `dashboard_zugang` eintragen.

## Projekte

| Umgebung | Projekt-Ref |
|---|---|
| dev | `udrcjopiixhlntmnsosj` |
| prod | noch nicht angelegt |

## Arbeitsweise

- Schema nur über Migrationen: `supabase migration new <name>` → SQL schreiben → `supabase db push`.
- Nie per Klick im Dashboard an prod ändern.
- Signal-Gewichte ändern: `daten/signale.csv` anpassen, `node scripts/signale-zu-sql.mjs`
  ausführen und das Ergebnis als Upsert in eine neue Migration übernehmen.
- Keine Schlüssel im Repo. Secrets über `supabase secrets set`.

## Offen

- Fit-Score: bewusst zurückgestellt, wird gemeinsam ausgearbeitet.
- `ss_vid` in Cookiebot als Statistik einordnen.
- Deals/Pipeline-Felder und Daniels CRM-Felder festziehen.
- prod-Projekt, Pro-Plan, Umzug auf Firmen-Account (dabei ToS + DPA im Namen der empiria GmbH akzeptieren; der DPA gilt per ToS, keine separate Unterschrift).
