-- =====================================================================
-- Einstellungen → Datenquellen: ein Blick, ob alle Anbindungen laufen.
-- Abrufe (Postfach, Buffer, Google, GA4, Bing) aus analytics.import_laeufe,
-- eingehende Quellen (Website, Terminbuchung) über ihr letztes Ereignis,
-- dazu der Stand je Postfach, der Newsletter-Versand und wann zuletzt
-- LinkedIn-Reaktionen eingefügt wurden.
-- =====================================================================

create or replace function public.dashboard_datenquellen()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'abrufe', (
      select coalesce(jsonb_object_agg(quelle, z), '{}'::jsonb) from (
        select l.quelle,
               jsonb_build_object(
                 'letzter',    max(l.gestartet),
                 'letzter_ok', max(l.gestartet) filter (where l.fehler is null or l.fehler = ''),
                 'zeilen',     (array_agg(l.zeilen order by l.gestartet desc))[1],
                 'fehler',     nullif((array_agg(l.fehler order by l.gestartet desc))[1], ''),
                 'laeufe_7t',  count(*) filter (where l.gestartet >= now() - interval '7 days'),
                 'fehler_7t',  count(*) filter (where l.gestartet >= now() - interval '7 days' and nullif(l.fehler, '') is not null)) as z
          from analytics.import_laeufe l
         group by l.quelle) x),
    'ereignisse', (
      select coalesce(jsonb_object_agg(source, z), '{}'::jsonb) from (
        select e.source,
               jsonb_build_object('letzter', max(e.occurred_at),
                                  'anzahl_7t', count(*) filter (where e.occurred_at >= now() - interval '7 days')) as z
          from core.events e
         where e.occurred_at >= now() - interval '90 days'
         group by e.source) x),
    'postfaecher', (
      select coalesce(jsonb_agg(z order by z->>'postfach'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'postfach', s.postfach,
                 'mails', (select count(*) from core.mails m where m.postfach = s.postfach),
                 'termine', (select count(*) from core.kalender k where k.postfach = s.postfach),
                 'aktualisiert', max(s.aktualisiert),
                 'fehler', string_agg(s.ordner || ': ' || s.fehler, ' · ') filter (where s.fehler is not null)) as z
          from core.postfach_sync s group by s.postfach) x),
    'newsletter', (select to_jsonb(n) - 'id' from analytics.newsletter_status n),
    'linkedin', jsonb_build_object(
      'reaktionen_zuletzt', (select max(r.erfasst_am) from core.linkedin_reaktionen r),
      'personen', (select count(*) from core.linkedin_personen p where not p.ignoriert))
  )
$$;

revoke all on function public.dashboard_datenquellen() from public, anon, authenticated;
grant execute on function public.dashboard_datenquellen() to service_role;
