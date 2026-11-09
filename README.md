# sofortsichtbar-db

Zentrale Marketing- & Vertriebsdatenbank für Sofortsichtbar (Supabase).
Hintergrund und Zielbild: internes Briefing (liegt nur lokal unter `docs/briefing.md`).

## Aufbau

| Schema | Inhalt |
|---|---|
| `core` | contacts (CRM), companies, identities, event_types, events, consents |
| `scoring` | signals (Katalog aus `daten/signale.csv`), später Score-Views |
| `raw` | Roh-Payloads je Quelle (folgt mit der jeweiligen Anbindung) |
| `analytics` | Aggregate wie search_queries, post_metrics (folgt) |
| `agent` | recommendations (folgt) |

Kein Schema ist für `anon`/`authenticated` freigegeben. Zugriff nur serverseitig
(Edge Functions, Service-Role). RLS ist überall an.

**Identity-Stitching** steckt in der Datenbank selbst: Ein Event mit bekannter
`visitor_id` wird beim Einfügen dem Kontakt zugeordnet. Kommt eine neue bestätigte
`visitor_id` hinzu (Formular, Newsletter-Klick, Termin), werden alle früheren
anonymen Events dieses Besuchers rückwirkend zugeordnet.

**Löschen:** `select core.delete_contact('<uuid>');` entfernt den Kontakt mit allen
Identitäten, Events und Einwilligungen.

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
- First-Party-Tracking (Endpunkt + Script auf sofortsichtbar.de) – nächster Schritt.
- Deals/Pipeline-Felder und Daniels CRM-Felder festziehen.
- prod-Projekt, Pro-Plan, AVV, Umzug auf Firmen-Account.
