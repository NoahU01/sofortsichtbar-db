-- =====================================================================
-- Aufbewahrung (so in der Datenschutzerklärung zugesagt):
-- Website-Nutzungsdaten ohne Bezug zu einem Kontakt werden nach
-- 24 Monaten gelöscht. Läuft täglich per pg_cron.
-- =====================================================================

create or replace function core.loesche_alte_nutzungsdaten()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  delete from core.events
   where source = 'website'
     and contact_id is null
     and occurred_at < now() - interval '24 months';
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function core.loesche_alte_nutzungsdaten() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('nutzungsdaten-24-monate', '17 3 * * *',
                     'select core.loesche_alte_nutzungsdaten()');
