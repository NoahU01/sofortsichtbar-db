-- =====================================================================
-- LinkedHelper (läuft bei Daniel) → Webhook → Datenbank
--
-- Die Edge Function linkedhelper-webhook ruft ingest_linkedhelper je Profil
-- auf. Weil die genauen Feldnamen erst mit der ersten Testsendung bekannt
-- sind, wird jede Sendung roh gespeichert (core.linkedhelper_eingang).
-- Schon jetzt: LinkedIn-Profil-URL und E-Mail werden in der Sendung gesucht;
-- gehört eine davon zu einem bestehenden Kontakt, wird die Sendung ihm
-- zugeordnet. Kontakte anlegen und Ereignisse in den Verlauf schreiben kommt
-- mit der Feldzuordnung nach dem Test.
-- =====================================================================

create table core.linkedhelper_eingang (
  eingang_id  bigint generated always as identity primary key,
  empfangen   timestamptz not null default now(),
  art         text not null check (art in ('profil', 'antwort')),
  payload     jsonb not null,
  profil_url  text,
  email       text,
  contact_id  uuid references core.contacts on delete set null,
  verarbeitet boolean not null default false
);
create index linkedhelper_eingang_zeit on core.linkedhelper_eingang (empfangen desc);
create index linkedhelper_eingang_contact on core.linkedhelper_eingang (contact_id);
alter table core.linkedhelper_eingang enable row level security;
grant all on core.linkedhelper_eingang to service_role;

-- LinkedIn-Profil-URL vereinheitlichen: https://www.linkedin.com/in/<name>
create or replace function core.linkedin_profil_norm(p text)
returns text language sql immutable set search_path = '' as $$
  select 'https://www.linkedin.com/in/' || lower(m[1])
    from regexp_match(coalesce(p, ''), 'linkedin\.com/in/([^/?#\s"]+)', 'i') m
$$;

create or replace function public.ingest_linkedhelper(p jsonb, p_art text default 'profil')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_url text; v_mail text; v_contact uuid; v_id bigint;
begin
  -- alle Textwerte der Sendung durchsuchen, egal wie die Felder heißen
  select core.linkedin_profil_norm(t #>> '{}') into v_url
    from jsonb_path_query(p, 'strict $.**') t
   where jsonb_typeof(t) = 'string' and (t #>> '{}') ~* 'linkedin\.com/in/'
   limit 1;
  select lower(trim(t #>> '{}')) into v_mail
    from jsonb_path_query(p, 'strict $.**') t
   where jsonb_typeof(t) = 'string' and (t #>> '{}') ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'
   limit 1;

  if v_url is not null then
    select i.contact_id into v_contact from core.identities i
     where i.identity_type = 'linkedin_profile_url' and core.linkedin_profil_norm(i.identity_value) = v_url limit 1;
    if v_contact is null then
      select lp.contact_id into v_contact from core.linkedin_personen lp
       where lp.contact_id is not null and not lp.ignoriert and core.linkedin_profil_norm(lp.profil_url) = v_url limit 1;
    end if;
  end if;
  if v_contact is null and v_mail is not null then
    select i.contact_id into v_contact from core.identities i where i.identity_type = 'email' and i.identity_value = v_mail limit 1;
  end if;

  insert into core.linkedhelper_eingang (art, payload, profil_url, email, contact_id)
  values (case when p_art = 'antwort' then 'antwort' else 'profil' end, p, v_url, v_mail, v_contact)
  returning eingang_id into v_id;
  return jsonb_build_object('eingang_id', v_id, 'profil_url', v_url, 'contact_id', v_contact);
end $$;

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
    'linkedhelper', (select jsonb_build_object('letzter', max(l.empfangen), 'anzahl', count(*),
                                               'anzahl_7t', count(*) filter (where l.empfangen >= now() - interval '7 days'),
                                               'zugeordnet', count(*) filter (where l.contact_id is not null))
                       from core.linkedhelper_eingang l),
    'linkedin', jsonb_build_object(
      'reaktionen_zuletzt', (select max(r.erfasst_am) from core.linkedin_reaktionen r),
      'personen', (select count(*) from core.linkedin_personen p where not p.ignoriert))
  )
$$;

revoke all on function public.ingest_linkedhelper(jsonb, text) from public, anon, authenticated;
grant execute on function public.ingest_linkedhelper(jsonb, text) to service_role;
revoke all on function public.dashboard_datenquellen() from public, anon, authenticated;
grant execute on function public.dashboard_datenquellen() to service_role;
