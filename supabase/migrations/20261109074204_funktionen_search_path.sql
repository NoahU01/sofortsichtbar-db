-- Supabase-Advisor 0011: Funktionen mit festem, leerem search_path.
-- Alle Tabellenzugriffe in den Funktionen sind schema-qualifiziert (core.…),
-- eingebaute Funktionen (now, lower, trim) liegen in pg_catalog und bleiben erreichbar.
alter function core.set_updated_at()              set search_path = '';
alter function core.normalize_contact()           set search_path = '';
alter function core.events_attach_contact()       set search_path = '';
alter function core.identities_backfill_events()  set search_path = '';
alter function core.delete_contact(uuid)          set search_path = '';
