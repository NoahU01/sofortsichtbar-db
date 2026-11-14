-- =====================================================================
-- LinkedIn-Reaktionen (Firmenseite sofort sichtbar und Daniels Beiträge)
--
-- Quelle: Die Reaktionsliste eines Beitrags wird in LinkedIn kopiert und im
-- Cockpit eingefügt („Liste einfügen“). Das Cockpit erkennt Name, Position
-- und Art der Reaktion; gespeichert wird hier. Kein Scraping, keine API.
--
--   core.linkedin_beitraege  ein Beitrag (Firmenseite oder Daniel)
--   core.linkedin_personen   wer reagiert hat (Name + Position), optional
--                            einem Kontakt zugeordnet oder ignoriert
--   core.linkedin_reaktionen wer auf welchen Beitrag reagiert hat
--
-- Zugeordnet zu Kontakten wird nur von Hand (Name allein ist kein sicherer
-- Schlüssel). Ist eine Person einem Kontakt zugeordnet, steht jede ihrer
-- Reaktionen als linkedin_reaction in seiner Timeline – auch rückwirkend.
-- Die Soll-Zahl je Beitrag (reaktionen_laut_buffer) füllt später der
-- Buffer-Import; das Cockpit zeigt dann „47 laut Buffer · 31 erfasst“.
-- =====================================================================

create table core.linkedin_beitraege (
  beitrag_id             uuid primary key default gen_random_uuid(),
  kanal                  text not null check (kanal in ('firmenseite', 'daniel')),
  titel                  text not null,
  url                    text,
  veroeffentlicht        date,
  buffer_post_id         text,
  reaktionen_laut_buffer integer,
  kommentare_laut_buffer integer,
  buffer_stand           timestamptz,
  angelegt_von           text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create unique index linkedin_beitraege_url_key on core.linkedin_beitraege (url) where url is not null;
create unique index linkedin_beitraege_buffer_key on core.linkedin_beitraege (buffer_post_id) where buffer_post_id is not null;
create trigger linkedin_beitraege_updated_at before update on core.linkedin_beitraege
  for each row execute function core.set_updated_at();

create table core.linkedin_personen (
  person_id   uuid primary key default gen_random_uuid(),
  schluessel  text not null unique,        -- Name klein, Leerzeichen vereinheitlicht
  name        text not null,
  position    text,                        -- Headline, wie LinkedIn sie zeigt (letzter Stand)
  contact_id  uuid references core.contacts on delete set null,
  ignoriert   boolean not null default false,
  erstmals    timestamptz not null default now(),
  zuletzt     timestamptz not null default now()
);
create index linkedin_personen_contact_idx on core.linkedin_personen (contact_id) where contact_id is not null;

create table core.linkedin_reaktionen (
  beitrag_id uuid not null references core.linkedin_beitraege on delete cascade,
  person_id  uuid not null references core.linkedin_personen on delete cascade,
  art        text not null check (art in ('like', 'celebrate', 'support', 'love', 'insightful', 'funny', 'reaktion')),
  erfasst_am timestamptz not null default now(),
  primary key (beitrag_id, person_id)
);
create index linkedin_reaktionen_person_idx on core.linkedin_reaktionen (person_id);

alter table core.linkedin_beitraege  enable row level security;
alter table core.linkedin_personen   enable row level security;
alter table core.linkedin_reaktionen enable row level security;
grant all on core.linkedin_beitraege, core.linkedin_personen, core.linkedin_reaktionen to service_role;

update core.event_types set beschreibung = 'Reaktion auf einen LinkedIn-Beitrag (Firmenseite oder Daniel); Art in properties.art'
 where event_name = 'linkedin_reaction';

-- Das Team selbst ist kein Signal
insert into core.linkedin_personen (schluessel, name, ignoriert) values
  ('daniel ströbel', 'Daniel Ströbel', true),
  ('noah hermanns', 'Noah Hermanns', true);

create or replace function core.linkedin_schluessel(p_name text)
returns text language sql immutable set search_path = '' as $$
  select lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
$$;

-- ---------------------------------------------------------------------
-- Timeline: Reaktionen zugeordneter Personen als Events (idempotent).
-- Entweder für eine Person oder für einen Beitrag.
-- ---------------------------------------------------------------------
create or replace function core.linkedin_events(p_person_id uuid default null, p_beitrag_id uuid default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer;
begin
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select 'li:' || r.beitrag_id || ':' || r.person_id, 'linkedin_reaction', r.erfasst_am, p.contact_id, 'linkedin',
         jsonb_strip_nulls(jsonb_build_object('art', r.art, 'beitrag', b.titel, 'beitrag_id', b.beitrag_id, 'url', b.url,
                                              'kanal', b.kanal, 'veroeffentlicht', b.veroeffentlicht, 'person_id', p.person_id)),
         'not_required'
    from core.linkedin_reaktionen r
    join core.linkedin_personen p on p.person_id = r.person_id
    join core.linkedin_beitraege b on b.beitrag_id = r.beitrag_id
   where p.contact_id is not null and not p.ignoriert
     and (p_person_id is null or r.person_id = p_person_id)
     and (p_beitrag_id is null or r.beitrag_id = p_beitrag_id)
  on conflict (event_id) do update
     set contact_id = excluded.contact_id, properties = excluded.properties;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Cockpit: Übersicht
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with zaehl as (
    select r.person_id, count(*) as reaktionen, max(r.erfasst_am) as letzte,
           count(*) filter (where b.kanal = 'firmenseite') as firmenseite,
           count(*) filter (where b.kanal = 'daniel') as daniel
      from core.linkedin_reaktionen r join core.linkedin_beitraege b on b.beitrag_id = r.beitrag_id
     group by r.person_id
  ), kontaktnamen as (
    -- Vorschlag nur bei genau einem Kontakt mit diesem Namen
    select lower(concat_ws(' ', c.vorname, c.nachname)) as k, min(c.contact_id::text)::uuid as contact_id, count(*) as n
      from core.contacts c where c.vorname is not null
     group by 1
  )
  select jsonb_build_object(
    'beitraege', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'beitrag_id', b.beitrag_id, 'kanal', b.kanal, 'titel', b.titel, 'url', b.url, 'veroeffentlicht', b.veroeffentlicht,
               'erfasst', (select count(*) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id),
               'laut_buffer', b.reaktionen_laut_buffer, 'buffer_stand', b.buffer_stand,
               'zuletzt_erfasst', (select max(r.erfasst_am) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id))
             order by coalesce(b.veroeffentlicht, b.created_at::date) desc, b.created_at desc), '[]'::jsonb)
        from core.linkedin_beitraege b),
    'personen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'person_id', p.person_id, 'name', p.name, 'position', p.position, 'ignoriert', p.ignoriert,
               'reaktionen', z.reaktionen, 'firmenseite', z.firmenseite, 'daniel', z.daniel, 'letzte', z.letzte,
               'kontakt', case when c.contact_id is not null then jsonb_build_object(
                            'contact_id', c.contact_id, 'name', nullif(concat_ws(' ', c.vorname, c.nachname), ''), 'email', c.email,
                            'stufe', c.lifecycle_stage) end,
               'vorschlag', case when c.contact_id is null and kn.n = 1 then jsonb_build_object(
                            'contact_id', kv.contact_id, 'name', concat_ws(' ', kv.vorname, kv.nachname), 'email', kv.email) end)
             order by z.reaktionen desc, z.letzte desc), '[]'::jsonb)
        from core.linkedin_personen p
        join zaehl z on z.person_id = p.person_id
        left join core.contacts c on c.contact_id = p.contact_id
        left join kontaktnamen kn on kn.k = regexp_replace(p.schluessel, ',.*$', '')
        left join core.contacts kv on kv.contact_id = kn.contact_id)
  )
$$;

-- ---------------------------------------------------------------------
-- Cockpit: Liste einfügen.
-- p: { beitrag_id? | beitrag: {kanal, titel, url?, veroeffentlicht?},
--      personen: [{name, position?, art}] }
-- Gibt { beitrag_id, gesamt, neu_personen, neu_reaktionen } zurück.
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin_erfassen(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_beitrag uuid := nullif(p->>'beitrag_id', '')::uuid;
  v_url     text := nullif(trim(p#>>'{beitrag,url}'), '');
  v_liste   jsonb;
  v_gesamt  integer; v_neu_p integer; v_neu_r integer;
begin
  if v_beitrag is null then
    if v_url is not null then
      select beitrag_id into v_beitrag from core.linkedin_beitraege where url = v_url;
    end if;
    if v_beitrag is null then
      insert into core.linkedin_beitraege (kanal, titel, url, veroeffentlicht, angelegt_von)
      values (p#>>'{beitrag,kanal}', coalesce(nullif(trim(p#>>'{beitrag,titel}'), ''), 'Beitrag'), v_url,
              nullif(p#>>'{beitrag,veroeffentlicht}', '')::date, p_von)
      returning beitrag_id into v_beitrag;
    end if;
  elsif not exists (select 1 from core.linkedin_beitraege where beitrag_id = v_beitrag) then
    raise exception 'Beitrag nicht gefunden';
  end if;

  -- Bereinigte Liste: je Name einmal
  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_liste from (
    select distinct on (core.linkedin_schluessel(x->>'name'))
           core.linkedin_schluessel(x->>'name') as schluessel, left(trim(x->>'name'), 200) as name,
           left(nullif(trim(x->>'position'), ''), 300) as position,
           case when x->>'art' in ('like', 'celebrate', 'support', 'love', 'insightful', 'funny') then x->>'art' else 'reaktion' end as art
      from jsonb_array_elements(coalesce(p->'personen', '[]'::jsonb)) x
     where nullif(trim(x->>'name'), '') is not null) z;
  v_gesamt := jsonb_array_length(v_liste);

  select count(*) filter (where lp.person_id is null),
         count(*) filter (where r.person_id is null)
    into v_neu_p, v_neu_r
    from jsonb_to_recordset(v_liste) n(schluessel text)
    left join core.linkedin_personen lp on lp.schluessel = n.schluessel
    left join core.linkedin_reaktionen r on r.person_id = lp.person_id and r.beitrag_id = v_beitrag;

  insert into core.linkedin_personen (schluessel, name, position)
  select n.schluessel, n.name, n.position from jsonb_to_recordset(v_liste) n(schluessel text, name text, position text)
  on conflict (schluessel) do update
     set position = coalesce(excluded.position, core.linkedin_personen.position), zuletzt = now();

  insert into core.linkedin_reaktionen (beitrag_id, person_id, art)
  select v_beitrag, lp.person_id, n.art
    from jsonb_to_recordset(v_liste) n(schluessel text, art text)
    join core.linkedin_personen lp on lp.schluessel = n.schluessel
  on conflict (beitrag_id, person_id) do update set art = excluded.art;

  perform core.linkedin_events(p_beitrag_id => v_beitrag);
  return jsonb_build_object('beitrag_id', v_beitrag, 'gesamt', v_gesamt, 'neu_personen', v_neu_p, 'neu_reaktionen', v_neu_r);
end $$;

-- ---------------------------------------------------------------------
-- Cockpit: Person bearbeiten.
--   zuordnen (p_contact_id)  · loesen · ignorieren · zurueckholen
--   kontakt_anlegen          legt einen Kontakt aus dem Namen an und ordnet zu
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin_person(p_person_id uuid, p_aktion text, p_contact_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_p core.linkedin_personen;
  v_contact uuid;
  v_name text;
begin
  select * into v_p from core.linkedin_personen where person_id = p_person_id;
  if not found then raise exception 'Person nicht gefunden'; end if;

  if p_aktion = 'zuordnen' then
    if p_contact_id is null or not exists (select 1 from core.contacts where contact_id = p_contact_id) then
      raise exception 'Kontakt nicht gefunden';
    end if;
    v_contact := p_contact_id;
  elsif p_aktion = 'kontakt_anlegen' then
    v_name := trim(regexp_replace(v_p.name, ',.*$', ''));   -- „Holger Diefenbach, LL.M.“ → „Holger Diefenbach“
    insert into core.contacts (vorname, nachname, notizen)
    values (split_part(v_name, ' ', 1),
            nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
            case when v_p.position is not null then 'LinkedIn: ' || v_p.position end)
    returning contact_id into v_contact;
  elsif p_aktion in ('loesen', 'ignorieren') then
    delete from core.events where source = 'linkedin' and properties->>'person_id' = p_person_id::text;
    update core.linkedin_personen set contact_id = case when p_aktion = 'loesen' then null else contact_id end,
                                      ignoriert = (p_aktion = 'ignorieren')
     where person_id = p_person_id;
    return jsonb_build_object('person_id', p_person_id);
  elsif p_aktion = 'zurueckholen' then
    update core.linkedin_personen set ignoriert = false where person_id = p_person_id;
    perform core.linkedin_events(p_person_id => p_person_id);
    return jsonb_build_object('person_id', p_person_id);
  else
    raise exception 'Unbekannte Aktion %', p_aktion;
  end if;

  update core.linkedin_personen set contact_id = v_contact, ignoriert = false where person_id = p_person_id;
  delete from core.events where source = 'linkedin' and properties->>'person_id' = p_person_id::text and contact_id <> v_contact;
  perform core.linkedin_events(p_person_id => p_person_id);
  return jsonb_build_object('person_id', p_person_id, 'contact_id', v_contact);
end $$;

create or replace function public.dashboard_linkedin_beitrag_loeschen(p_beitrag_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_da boolean;
begin
  delete from core.events where source = 'linkedin' and properties->>'beitrag_id' = p_beitrag_id::text;
  delete from core.linkedin_beitraege where beitrag_id = p_beitrag_id;
  v_da := found;
  -- Personen ohne Reaktionen und ohne Entscheidung fallen weg
  delete from core.linkedin_personen lp
   where lp.contact_id is null and not lp.ignoriert
     and not exists (select 1 from core.linkedin_reaktionen r where r.person_id = lp.person_id);
  return v_da;
end $$;

-- ---------------------------------------------------------------------
-- Löschen eines Kontakts entfernt auch seine LinkedIn-Person samt Reaktionen
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
  delete from core.linkedin_personen where contact_id = p_contact_id;   -- Reaktionen per cascade
  delete from core.contacts where contact_id = p_contact_id;            -- Rest per cascade
end $$;
revoke execute on function core.delete_contact(uuid) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.dashboard_linkedin()', 'public.dashboard_linkedin_erfassen(jsonb, text)',
    'public.dashboard_linkedin_person(uuid, text, uuid)', 'public.dashboard_linkedin_beitrag_loeschen(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
