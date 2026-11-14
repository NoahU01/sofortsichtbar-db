-- =====================================================================
-- Postfächer und Kalender (Microsoft 365, alle @sofortsichtbar.de-Postfächer)
--
-- Die Edge Function `postfach-import` holt alle 15 Minuten per Graph-
-- Delta-Abfrage Neues aus Posteingang, Gesendet und Kalender und übergibt es
-- an public.ingest_postfach. Gespeichert werden Metadaten und eine Vorschau
-- (bis 300 Zeichen), keine vollständigen Texte, keine Anhänge.
--
-- Zuordnung zu Kontakten (über E-Mail-Identitäten):
--   eingehend von bekanntem Kontakt     → mail_received in seiner Timeline
--   ausgehend an bekannten Kontakt      → mail_sent
--   ausgehend an unbekannte externe Adresse → Kontakt wird angelegt
--   eingehend von Unbekannten           → kein Kontakt; Liste im Cockpit
--   Kalendertermin mit Kontakt als Teilnehmer → calendar_meeting
-- Wird eine E-Mail-Identität neu angelegt (Buchung, Übernahme im Cockpit …),
-- hängen frühere Mails und Termine rückwirkend am Kontakt (Trigger).
-- Interne Mails werden gespeichert, aber nur zugeordnet, wenn ein Kontakt
-- beteiligt ist.
-- =====================================================================

create table core.mails (
  postfach            text not null,
  graph_id            text not null,
  ordner              text not null check (ordner in ('posteingang', 'gesendet')),
  internet_message_id text,
  conversation_id     text,
  zeit                timestamptz not null,
  von_email           text,
  von_name            text,
  an                  jsonb not null default '[]'::jsonb,   -- [{email, name}], email klein geschrieben
  cc                  jsonb not null default '[]'::jsonb,
  betreff             text,
  vorschau            text,
  hat_anhang          boolean not null default false,
  intern              boolean not null default false,
  abgerufen_am        timestamptz not null default now(),
  primary key (postfach, graph_id)
);
create index mails_von_idx  on core.mails (von_email);
create index mails_zeit_idx on core.mails (zeit desc);
create index mails_an_idx   on core.mails using gin (an jsonb_path_ops);
create index mails_cc_idx   on core.mails using gin (cc jsonb_path_ops);

create table core.kalender (
  postfach          text not null,
  graph_id          text not null,
  ical_uid          text,
  betreff           text,
  beginn            timestamptz,
  ende              timestamptz,
  ort               text,
  organisator_email text,
  teilnehmer        jsonb not null default '[]'::jsonb,     -- [{email, name, antwort}]
  online            boolean not null default false,
  abgesagt          boolean not null default false,
  vorschau          text,
  abgerufen_am      timestamptz not null default now(),
  primary key (postfach, graph_id)
);
create index kalender_teilnehmer_idx on core.kalender using gin (teilnehmer jsonb_path_ops);

-- Stand der Delta-Abfragen je Postfach und Ordner (posteingang, gesendet, kalender)
create table core.postfach_sync (
  postfach     text not null,
  ordner       text not null,
  delta_link   text,
  gestartet    timestamptz not null default now(),   -- Beginn dieser Delta-Kette
  aktualisiert timestamptz not null default now(),
  fehler       text,
  primary key (postfach, ordner)
);

create table core.absender_ignoriert (
  email text primary key check (email = lower(email)),
  seit  timestamptz not null default now()
);

alter table core.mails              enable row level security;
alter table core.kalender           enable row level security;
alter table core.postfach_sync      enable row level security;
alter table core.absender_ignoriert enable row level security;
grant all on core.mails, core.kalender, core.postfach_sync, core.absender_ignoriert to service_role;

insert into core.event_types (event_name, quelle, beschreibung) values
  ('calendar_meeting', 'outlook', 'Termin im Outlook-Kalender mit dem Kontakt als Teilnehmer');
update core.event_types set quelle = 'outlook' where event_name in ('mail_received', 'mail_sent');

-- Automatische Absender, die nie Kontakte werden
create or replace function core.ist_automatisch(p_email text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_email ~* '^(no-?reply|do-?not-?reply|mailer-daemon|postmaster|bounce|notifications?|news(letter)?|info@.*\.(google|microsoft|linkedin)\.)', false)
$$;

-- ---------------------------------------------------------------------
-- Zuordnung: Mails → Timeline. Entweder für bestimmte Mails (p_postfach +
-- p_ids) oder für eine E-Mail-Adresse (p_email, rückwirkend).
-- ---------------------------------------------------------------------
create or replace function core.mail_events(p_postfach text default null, p_ids text[] default null, p_email text default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer;
begin
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select distinct on (eid)
         eid, case when m.ordner = 'gesendet' then 'mail_sent' else 'mail_received' end, m.zeit, i.contact_id, 'outlook',
         jsonb_strip_nulls(jsonb_build_object('betreff', m.betreff, 'vorschau', left(m.vorschau, 300), 'postfach', m.postfach,
                                              'von', m.von_email, 'anhang', nullif(m.hat_anhang, false), 'gespraech', m.conversation_id)),
         'not_required'
    from core.mails m
    cross join lateral (
      select m.von_email as email where m.ordner = 'posteingang'
      union
      select x->>'email' from jsonb_array_elements(m.an || m.cc) x where m.ordner = 'gesendet'
    ) t
    join core.identities i on i.identity_type = 'email' and i.identity_value = t.email
    cross join lateral (select 'mail:' || coalesce(m.internet_message_id, m.postfach || '/' || m.graph_id) || ':' || i.contact_id as eid) e
   where (p_ids is null or (m.postfach = p_postfach and m.graph_id = any (p_ids)))
     and (p_email is null or m.von_email = p_email
          or m.an @> jsonb_build_array(jsonb_build_object('email', p_email))
          or m.cc @> jsonb_build_array(jsonb_build_object('email', p_email)))
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function core.termin_events(p_postfach text default null, p_ids text[] default null, p_email text default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer;
begin
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select distinct on (eid)
         eid, 'calendar_meeting', k.beginn, i.contact_id, 'outlook',
         jsonb_strip_nulls(jsonb_build_object('betreff', k.betreff, 'beginn', k.beginn, 'ende', k.ende, 'ort', k.ort,
                                              'online', nullif(k.online, false), 'abgesagt', nullif(k.abgesagt, false), 'postfach', k.postfach)),
         'not_required'
    from core.kalender k
    cross join lateral jsonb_array_elements(k.teilnehmer) x
    join core.identities i on i.identity_type = 'email' and i.identity_value = x->>'email'
    cross join lateral (select 'kal:' || coalesce(k.ical_uid, k.postfach || '/' || k.graph_id) || ':' || i.contact_id as eid) e
   where k.beginn is not null
     and (p_ids is null or (k.postfach = p_postfach and k.graph_id = any (p_ids)))
     and (p_email is null or k.teilnehmer @> jsonb_build_array(jsonb_build_object('email', p_email)))
  on conflict (event_id) do update
     set occurred_at = excluded.occurred_at, properties = excluded.properties;
  get diagnostics n = row_count;
  return n;
end $$;

-- Neue E-Mail-Identität → frühere Mails und Termine nachziehen
create or replace function core.identities_mails_nachziehen()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform core.mail_events(p_email => new.identity_value);
  perform core.termin_events(p_email => new.identity_value);
  return null;
end $$;
create trigger identities_mails_nachziehen
  after insert on core.identities
  for each row when (new.identity_type = 'email')
  execute function core.identities_mails_nachziehen();

-- ---------------------------------------------------------------------
-- Annahme. p: { postfach, domain, ordner, mails[], termine[], entfernt[],
--               delta_link, neu_gestartet }
-- ---------------------------------------------------------------------
create or replace function public.ingest_postfach(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_postfach text := lower(p->>'postfach');
  v_domain   text := '@' || lower(coalesce(p->>'domain', 'sofortsichtbar.de'));
  v_ordner   text := p->>'ordner';
  v_ids      text[];
  v_neu      integer := 0;
  n_mails integer := 0; n_termine integer := 0; n_events integer := 0; n_kontakte integer := 0;
  r record;
begin
  -- Mails
  with roh as (
    select x->>'id' as graph_id, coalesce(x->>'ordner', v_ordner) as ordner, x->>'internet_message_id' as imid,
           x->>'conversation_id' as conv, (x->>'zeit')::timestamptz as zeit,
           lower(trim(x->>'von_email')) as von_email, left(x->>'von_name', 200) as von_name,
           coalesce((select jsonb_agg(jsonb_build_object('email', lower(trim(a->>'email')), 'name', left(a->>'name', 200)))
                       from jsonb_array_elements(coalesce(x->'an', '[]'::jsonb)) a where a->>'email' is not null), '[]'::jsonb) as an,
           coalesce((select jsonb_agg(jsonb_build_object('email', lower(trim(a->>'email')), 'name', left(a->>'name', 200)))
                       from jsonb_array_elements(coalesce(x->'cc', '[]'::jsonb)) a where a->>'email' is not null), '[]'::jsonb) as cc,
           left(x->>'betreff', 500) as betreff, left(x->>'vorschau', 300) as vorschau, coalesce((x->>'anhang')::boolean, false) as anhang
      from jsonb_array_elements(coalesce(p->'mails', '[]'::jsonb)) x
     where x->>'id' is not null and x->>'zeit' is not null
  ), ein as (
    insert into core.mails (postfach, graph_id, ordner, internet_message_id, conversation_id, zeit, von_email, von_name, an, cc,
                            betreff, vorschau, hat_anhang, intern, abgerufen_am)
    select v_postfach, graph_id, ordner, imid, conv, zeit, von_email, von_name, an, cc, betreff, vorschau, anhang,
           -- intern: alle Beteiligten in der eigenen Domain
           coalesce(von_email like '%' || v_domain, false)
             and not exists (select 1 from jsonb_array_elements(an || cc) z where z->>'email' not like '%' || v_domain),
           now()
      from roh
    on conflict (postfach, graph_id) do update
       set ordner = excluded.ordner, zeit = excluded.zeit, an = excluded.an, cc = excluded.cc, betreff = excluded.betreff,
           vorschau = excluded.vorschau, hat_anhang = excluded.hat_anhang, intern = excluded.intern, abgerufen_am = now()
    returning graph_id
  )
  select array_agg(graph_id) into v_ids from ein;
  n_mails := coalesce(array_length(v_ids, 1), 0);

  if n_mails > 0 then
    -- Wer von uns angeschrieben wurde und extern ist, wird Kontakt
    for r in
      select distinct on (x->>'email') x->>'email' as email, nullif(trim(x->>'name'), '') as name
        from core.mails m cross join lateral jsonb_array_elements(m.an || m.cc) x
       where m.postfach = v_postfach and m.graph_id = any (v_ids) and m.ordner = 'gesendet'
         and x->>'email' not like '%' || v_domain
         and x->>'email' like '%@%.%'
         and not core.ist_automatisch(x->>'email')
         and not exists (select 1 from core.identities i where i.identity_type = 'email' and i.identity_value = x->>'email')
         and not exists (select 1 from core.absender_ignoriert g where g.email = x->>'email')
    loop
      insert into core.contacts (email, vorname, nachname)
      values (r.email,
              case when r.name is not null and r.name not like '%@%' then split_part(r.name, ' ', 1) end,
              case when r.name is not null and r.name not like '%@%' and position(' ' in r.name) > 0
                   then trim(substr(r.name, position(' ' in r.name) + 1)) end)
      on conflict (email) where email is not null do nothing;
      insert into core.identities (contact_id, identity_type, identity_value, source)
      select contact_id, 'email', r.email, 'postfach' from core.contacts where email = r.email
      on conflict (identity_type, identity_value) do nothing;
      get diagnostics v_neu = row_count;
      n_kontakte := n_kontakte + v_neu;
    end loop;
    n_events := n_events + core.mail_events(v_postfach, v_ids);
  end if;

  -- Kalender
  v_ids := null;
  with ein as (
    insert into core.kalender (postfach, graph_id, ical_uid, betreff, beginn, ende, ort, organisator_email, teilnehmer, online, abgesagt, vorschau, abgerufen_am)
    select v_postfach, x->>'id', x->>'ical_uid', left(x->>'betreff', 500), (x->>'beginn')::timestamptz, (x->>'ende')::timestamptz,
           left(x->>'ort', 300), lower(x->>'organisator_email'),
           coalesce((select jsonb_agg(jsonb_build_object('email', lower(trim(a->>'email')), 'name', left(a->>'name', 200), 'antwort', a->>'antwort'))
                       from jsonb_array_elements(coalesce(x->'teilnehmer', '[]'::jsonb)) a where a->>'email' is not null), '[]'::jsonb),
           coalesce((x->>'online')::boolean, false), coalesce((x->>'abgesagt')::boolean, false), left(x->>'vorschau', 300), now()
      from jsonb_array_elements(coalesce(p->'termine', '[]'::jsonb)) x
     where x->>'id' is not null
    on conflict (postfach, graph_id) do update
       set ical_uid = excluded.ical_uid, betreff = excluded.betreff, beginn = excluded.beginn, ende = excluded.ende, ort = excluded.ort,
           organisator_email = excluded.organisator_email, teilnehmer = excluded.teilnehmer, online = excluded.online,
           abgesagt = excluded.abgesagt, vorschau = excluded.vorschau, abgerufen_am = now()
    returning graph_id
  )
  select array_agg(graph_id) into v_ids from ein;
  n_termine := coalesce(array_length(v_ids, 1), 0);
  if n_termine > 0 then
    n_events := n_events + core.termin_events(v_postfach, v_ids);
  end if;

  -- Gelöschte Kalendereinträge entfernen (bei Mails ignoriert: dort meldet
  -- Graph auch verschobene oder gelesene Mails als entfernt)
  if v_ordner = 'kalender' and jsonb_typeof(p->'entfernt') = 'array' then
    delete from core.kalender
     where postfach = v_postfach and graph_id in (select jsonb_array_elements_text(p->'entfernt'));
  end if;

  -- Stand merken
  if v_ordner is not null then
    insert into core.postfach_sync (postfach, ordner, delta_link, gestartet, aktualisiert, fehler)
    values (v_postfach, v_ordner, p->>'delta_link', now(), now(), nullif(p->>'fehler', ''))
    on conflict (postfach, ordner) do update
       set delta_link   = coalesce(excluded.delta_link, core.postfach_sync.delta_link),
           gestartet    = case when coalesce((p->>'neu_gestartet')::boolean, false) then now() else core.postfach_sync.gestartet end,
           aktualisiert = now(),
           fehler       = excluded.fehler;
  end if;

  return jsonb_build_object('mails', n_mails, 'termine', n_termine, 'events', n_events, 'neue_kontakte', n_kontakte);
end $$;

create or replace function public.postfach_stand()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(postfach || '|' || ordner, jsonb_build_object('link', delta_link, 'gestartet', gestartet)), '{}'::jsonb)
    from core.postfach_sync
$$;

create or replace function public.import_protokoll(p_quelle text, p_zeilen integer, p_fehler text)
returns void
language sql security definer set search_path = ''
as $$
  insert into analytics.import_laeufe (quelle, zeilen, fehler) values (p_quelle, p_zeilen, nullif(p_fehler, ''))
$$;

-- ---------------------------------------------------------------------
-- Cockpit
-- ---------------------------------------------------------------------
create or replace function public.dashboard_postfach(p_tage integer default 30)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'postfaecher', (
      select coalesce(jsonb_agg(z order by z->>'postfach'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'postfach', s.postfach,
                 'mails', (select count(*) from core.mails m where m.postfach = s.postfach),
                 'mails_zeitraum', (select count(*) from core.mails m where m.postfach = s.postfach and m.zeit >= now() - make_interval(days => p_tage)),
                 'termine', (select count(*) from core.kalender k where k.postfach = s.postfach),
                 'aktualisiert', max(s.aktualisiert),
                 'fehler', string_agg(s.ordner || ': ' || s.fehler, ' · ') filter (where s.fehler is not null)) as z
          from core.postfach_sync s group by s.postfach) x),
    'unbekannt', (
      select coalesce(jsonb_agg(z order by z->>'letzte' desc), '[]'::jsonb) from (
        select jsonb_build_object('email', m.von_email, 'name', max(m.von_name), 'mails', count(*), 'letzte', max(m.zeit),
                                  'betreff', (array_agg(m.betreff order by m.zeit desc))[1],
                                  'vorschau', (array_agg(m.vorschau order by m.zeit desc))[1]) as z
          from core.mails m
         where m.ordner = 'posteingang' and not m.intern and m.von_email is not null
           -- Absender aus der eigenen Domain (Kolleginnen und Kollegen) sind nie „unbekannt“
           and split_part(m.von_email, '@', 2) not in (select split_part(s.postfach, '@', 2) from core.postfach_sync s)
           and m.zeit >= now() - make_interval(days => p_tage)
           and not core.ist_automatisch(m.von_email)
           and not exists (select 1 from core.identities i where i.identity_type = 'email' and i.identity_value = m.von_email)
           and not exists (select 1 from core.absender_ignoriert g where g.email = m.von_email)
         group by m.von_email
         order by max(m.zeit) desc limit 200) x),
    'zugeordnet', (select count(*) from core.events e where e.source = 'outlook' and e.occurred_at >= now() - make_interval(days => p_tage)),
    'importe', (
      select coalesce(jsonb_agg(jsonb_build_object('gestartet', gestartet, 'zeilen', zeilen, 'fehler', fehler) order by gestartet desc), '[]'::jsonb)
        from (select * from analytics.import_laeufe where quelle = 'postfach' order by gestartet desc limit 5) l)
  )
$$;

create or replace function public.dashboard_absender_uebernehmen(p_email text, p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_email text := lower(trim(p_email));
  v_name  text := nullif(trim(p_name), '');
  v_id    uuid;
begin
  insert into core.contacts (email, vorname, nachname)
  values (v_email,
          case when v_name is not null and v_name not like '%@%' then split_part(v_name, ' ', 1) end,
          case when v_name is not null and v_name not like '%@%' and position(' ' in v_name) > 0 then trim(substr(v_name, position(' ' in v_name) + 1)) end)
  on conflict (email) where email is not null do update set email = excluded.email
  returning contact_id into v_id;
  insert into core.identities (contact_id, identity_type, identity_value, source)
  values (v_id, 'email', v_email, 'postfach')
  on conflict (identity_type, identity_value) do nothing;   -- Trigger hängt frühere Mails an
  delete from core.absender_ignoriert where email = v_email;
  return v_id;
end $$;

create or replace function public.dashboard_absender_ignorieren(p_email text)
returns boolean
language sql security definer set search_path = ''
as $$
  insert into core.absender_ignoriert (email) values (lower(trim(p_email))) on conflict do nothing returning true
$$;

-- ---------------------------------------------------------------------
-- Löschen eines Kontakts entfernt auch seine Mails und Termine
-- ---------------------------------------------------------------------
create or replace function core.delete_contact(p_contact_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_email text;
  v_mails text[];
begin
  select email into v_email from core.contacts where contact_id = p_contact_id;
  select array_agg(identity_value) into v_mails from core.identities
   where contact_id = p_contact_id and identity_type = 'email';
  if v_mails is not null then
    delete from core.mails m
     where m.von_email = any (v_mails)
        or exists (select 1 from jsonb_array_elements(m.an || m.cc) x where x->>'email' = any (v_mails));
    delete from core.kalender k
     where exists (select 1 from jsonb_array_elements(k.teilnehmer) x where x->>'email' = any (v_mails));
  end if;
  delete from raw.cal_webhooks w
   where w.booking_uid in (select e.properties->>'booking_uid' from core.events e
                            where e.contact_id = p_contact_id and e.source = 'cal')
      or (v_email is not null and (lower(w.payload#>>'{payload,responses,email,value}') = v_email
                                   or lower(w.payload#>>'{payload,attendees,0,email}') = v_email));
  delete from core.events e
   using core.identities i
   where i.contact_id = p_contact_id
     and i.identity_type = 'visitor_id'
     and e.visitor_id = i.identity_value;
  delete from core.contacts where contact_id = p_contact_id;  -- Rest per cascade
end $$;
revoke execute on function core.delete_contact(uuid) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.ingest_postfach(jsonb)', 'public.postfach_stand()', 'public.import_protokoll(text, integer, text)',
    'public.dashboard_postfach(integer)', 'public.dashboard_absender_uebernehmen(text, text)', 'public.dashboard_absender_ignorieren(text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
