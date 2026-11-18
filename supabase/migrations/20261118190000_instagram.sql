-- =====================================================================
-- Instagram (sofort-sichtbar-Account)
--
-- Beiträge und Zahlen kommen aus Buffer (analytics.buffer_beitraege,
-- service 'instagram'). Wer gelikt oder kommentiert hat, liefert Meta
-- offiziell nicht für Likes – die Like-Liste wird im Cockpit eingefügt
-- (wie bei LinkedIn). Buffer zeigt, bei welchem Beitrag Likes fehlen.
--
--   core.instagram_personen    Benutzername (eindeutig) + Anzeigename,
--                              optional Kontakt, optional ausgeschlossen
--   core.instagram_likes       wer welchen Beitrag gelikt hat
--   core.instagram_kommentare  Kommentare (nr je Person und Beitrag)
--
-- Zuordnung zu Kontakten: automatisch nur, wenn der Benutzername schon als
-- Kennung bekannt ist oder genau ein Kontakt denselben Namen hat. Neue
-- Kontakte werden auf Instagram NICHT automatisch angelegt (viele private
-- Konten) – das entscheidet ein Mensch im Cockpit.
-- =====================================================================

insert into core.event_types (event_name, quelle, beschreibung) values
  ('instagram_like', 'instagram', 'Like auf einen Instagram-Beitrag von sofort sichtbar (Zeitpunkt = wann erfasst)'),
  ('instagram_comment', 'instagram', 'Kommentar auf einen Instagram-Beitrag von sofort sichtbar; Text in properties.text')
on conflict (event_name) do nothing;

alter table core.contacts drop constraint if exists contacts_herkunft_check;
alter table core.contacts add constraint contacts_herkunft_check check (herkunft in (
  'termin', 'postfach', 'call', 'website', 'linkedin_follower', 'linkedin_reaktion', 'instagram', 'manuell', 'import'));

create table core.instagram_personen (
  person_id        uuid primary key default gen_random_uuid(),
  benutzername     text not null unique check (benutzername = lower(benutzername) and benutzername ~ '^[a-z0-9._]{1,30}$'),
  name             text,
  contact_id       uuid references core.contacts on delete set null,
  ignoriert        boolean not null default false,
  ausschluss_grund text,
  erstmals         timestamptz not null default now(),
  zuletzt          timestamptz not null default now()
);
create table core.instagram_likes (
  post_id    text not null references analytics.buffer_beitraege on delete cascade,
  person_id  uuid not null references core.instagram_personen on delete cascade,
  erfasst_am timestamptz not null default now(),
  primary key (post_id, person_id)
);
create index instagram_likes_person on core.instagram_likes (person_id);
create table core.instagram_kommentare (
  post_id    text not null references analytics.buffer_beitraege on delete cascade,
  person_id  uuid not null references core.instagram_personen on delete cascade,
  nr         integer not null default 1 check (nr between 1 and 50),
  text       text,
  erfasst_am timestamptz not null default now(),
  primary key (post_id, person_id, nr)
);
create index instagram_kommentare_person on core.instagram_kommentare (person_id);
alter table core.instagram_personen   enable row level security;
alter table core.instagram_likes      enable row level security;
alter table core.instagram_kommentare enable row level security;
grant all on core.instagram_personen, core.instagram_likes, core.instagram_kommentare to service_role;

-- Kontakt löschen nimmt die Instagram-Zuordnung mit (Person bleibt, ohne Kontakt)
-- → erledigt „on delete set null“; Events hängen am Kontakt und gehen mit.

-- ---------------------------------------------------------------------
-- Signale
-- ---------------------------------------------------------------------
create or replace function core.instagram_events(p_person_id uuid default null, p_post_id text default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer; m integer;
begin
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select 'ig:' || l.post_id || ':' || l.person_id, 'instagram_like', l.erfasst_am, p.contact_id, 'instagram',
         jsonb_strip_nulls(jsonb_build_object('post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet::date,
           'beitrag', nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''),
           'person_id', p.person_id, 'benutzername', p.benutzername)), 'not_required'
    from core.instagram_likes l
    join core.instagram_personen p on p.person_id = l.person_id
    join analytics.buffer_beitraege b on b.post_id = l.post_id
   where p.contact_id is not null and not p.ignoriert
     and (p_person_id is null or l.person_id = p_person_id) and (p_post_id is null or l.post_id = p_post_id)
  on conflict (event_id) do update set contact_id = excluded.contact_id, properties = excluded.properties;
  get diagnostics n = row_count;

  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select 'igk:' || k.post_id || ':' || k.person_id || ':' || k.nr, 'instagram_comment', k.erfasst_am, p.contact_id, 'instagram',
         jsonb_strip_nulls(jsonb_build_object('text', left(k.text, 1000), 'post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet::date,
           'beitrag', nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''),
           'person_id', p.person_id, 'benutzername', p.benutzername)), 'not_required'
    from core.instagram_kommentare k
    join core.instagram_personen p on p.person_id = k.person_id
    join analytics.buffer_beitraege b on b.post_id = k.post_id
   where p.contact_id is not null and not p.ignoriert
     and (p_person_id is null or k.person_id = p_person_id) and (p_post_id is null or k.post_id = p_post_id)
  on conflict (event_id) do update set contact_id = excluded.contact_id, properties = excluded.properties;
  get diagnostics m = row_count;
  return n + m;
end $$;

-- Zuordnen (Kennung instagram_username merken) bzw. lösen/ausschließen
create or replace function core.instagram_zuordnen(p_person_id uuid, p_contact_id uuid)
returns void
language plpgsql set search_path = ''
as $$
declare v_p core.instagram_personen;
begin
  select * into v_p from core.instagram_personen where person_id = p_person_id;
  update core.instagram_personen set contact_id = p_contact_id, ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  delete from core.events where source = 'instagram' and properties->>'person_id' = p_person_id::text and contact_id <> p_contact_id;
  insert into core.identities (contact_id, identity_type, identity_value, source)
  values (p_contact_id, 'instagram_username', v_p.benutzername, 'instagram')
  on conflict (identity_type, identity_value) do nothing;
  perform core.instagram_events(p_person_id => p_person_id);
end $$;

-- Automatisch: bekannte Kennung oder genau ein gleichnamiger Kontakt
create or replace function core.instagram_auto_zuordnen(p_post_id text default null)
returns jsonb
language plpgsql set search_path = ''
as $$
declare r record; z record; v_n integer; v_c uuid; n_zu integer := 0;
begin
  for r in
    select p.* from core.instagram_personen p
     where not p.ignoriert and p.contact_id is null
       and (p_post_id is null
            or exists (select 1 from core.instagram_likes l where l.person_id = p.person_id and l.post_id = p_post_id)
            or exists (select 1 from core.instagram_kommentare k where k.person_id = p.person_id and k.post_id = p_post_id))
  loop
    select i.contact_id into v_c from core.identities i
     where i.identity_type = 'instagram_username' and i.identity_value = r.benutzername;
    if v_c is null and r.name is not null then
      select * into z from core.name_zerlegen(core.linkedin_name_sauber(r.name));
      if z.vorname is not null and z.nachname is not null then
        select count(*), min(c.contact_id::text)::uuid into v_n, v_c
          from core.contacts c where lower(concat_ws(' ', c.vorname, c.nachname)) = lower(concat_ws(' ', z.vorname, z.nachname));
        if v_n <> 1 then v_c := null; end if;
      end if;
    end if;
    if v_c is not null then
      perform core.instagram_zuordnen(r.person_id, v_c);
      n_zu := n_zu + 1;
    end if;
  end loop;
  return jsonb_build_object('zugeordnet', n_zu);
end $$;

-- ---------------------------------------------------------------------
-- Cockpit: Übersicht
-- ---------------------------------------------------------------------
create or replace function public.dashboard_instagram()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with b as (
    select b.*,
           (select count(*) from core.instagram_likes l where l.post_id = b.post_id) as erfasst,
           (select count(*) from core.instagram_kommentare k where k.post_id = b.post_id) as kommentare_erfasst
      from analytics.buffer_beitraege b where b.service = 'instagram'
  ), z as (
    select x.person_id, count(*) filter (where x.was = 'l') as likes, count(*) filter (where x.was = 'k') as kommentare, max(x.zeit) as letzte
      from (select person_id, 'l' as was, erfasst_am as zeit from core.instagram_likes
            union all select person_id, 'k', erfasst_am from core.instagram_kommentare) x
     group by x.person_id
  )
  select jsonb_build_object(
    'beitraege', (select coalesce(jsonb_agg(jsonb_build_object(
        'post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet,
        'titel', coalesce(nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''), 'Beitrag'),
        'likes', b.reaktionen, 'kommentare', b.kommentare, 'impressionen', b.impressionen, 'reichweite', b.reichweite,
        'erfasst', b.erfasst, 'kommentare_erfasst', b.kommentare_erfasst,
        'fehlen', greatest(coalesce(b.reaktionen, 0) - b.erfasst, 0),
        'beobachtet', b.erfasst > 0 or b.gesendet >= now() - interval '30 days')
      order by b.gesendet desc), '[]'::jsonb) from b),
    'personen', (select coalesce(jsonb_agg(jsonb_build_object(
        'person_id', p.person_id, 'benutzername', p.benutzername, 'name', p.name, 'ignoriert', p.ignoriert,
        'likes', z.likes, 'kommentare', z.kommentare, 'letzte', z.letzte,
        'kontakt', case when c.contact_id is not null then jsonb_build_object('contact_id', c.contact_id,
                     'name', nullif(concat_ws(' ', c.vorname, c.nachname), ''), 'email', c.email, 'stufe', c.lifecycle_stage) end)
      order by z.likes + 2 * z.kommentare desc, z.letzte desc), '[]'::jsonb)
      from core.instagram_personen p join z on z.person_id = p.person_id
      left join core.contacts c on c.contact_id = p.contact_id),
    'buffer', (select jsonb_build_object('stand', max(kennzahlen_stand), 'abgerufen', max(abgerufen_am))
                 from analytics.buffer_beitraege where service = 'instagram')
  )
$$;

-- ---------------------------------------------------------------------
-- Cockpit: Like-Liste / Kommentare einfügen
--   p: { post_id, personen: [{benutzername, name}], kommentare: [{benutzername, name, text}] }
-- ---------------------------------------------------------------------
create or replace function public.dashboard_instagram_erfassen(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_post text := p->>'post_id';
  v_l jsonb; v_k jsonb; v_neu_p integer; v_neu_l integer; v_neu_k integer; v_auto jsonb;
begin
  if not exists (select 1 from analytics.buffer_beitraege where post_id = v_post and service = 'instagram') then
    raise exception 'Instagram-Beitrag nicht gefunden';
  end if;
  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_l from (
    select distinct on (lower(trim(x->>'benutzername'))) lower(trim(x->>'benutzername')) as benutzername, left(nullif(trim(x->>'name'), ''), 200) as name
      from jsonb_array_elements(coalesce(p->'personen', '[]'::jsonb)) x
     where lower(trim(x->>'benutzername')) ~ '^[a-z0-9._]{1,30}$') z;
  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_k from (
    select lower(trim(x->>'benutzername')) as benutzername, left(nullif(trim(x->>'name'), ''), 200) as name,
           left(nullif(trim(x->>'text'), ''), 5000) as text,
           row_number() over (partition by lower(trim(x->>'benutzername')) order by o)::integer as nr
      from jsonb_array_elements(coalesce(p->'kommentare', '[]'::jsonb)) with ordinality t(x, o)
     where lower(trim(x->>'benutzername')) ~ '^[a-z0-9._]{1,30}$') z;

  select count(*) into v_neu_p from (
    select benutzername from jsonb_to_recordset(v_l) n(benutzername text)
    union select benutzername from jsonb_to_recordset(v_k) n(benutzername text)) a
   where not exists (select 1 from core.instagram_personen ip where ip.benutzername = a.benutzername);
  select count(*) into v_neu_l from jsonb_to_recordset(v_l) n(benutzername text)
   where not exists (select 1 from core.instagram_likes l join core.instagram_personen ip on ip.person_id = l.person_id
                      where ip.benutzername = n.benutzername and l.post_id = v_post);
  select count(*) into v_neu_k from jsonb_to_recordset(v_k) n(benutzername text, nr integer)
   where not exists (select 1 from core.instagram_kommentare k join core.instagram_personen ip on ip.person_id = k.person_id
                      where ip.benutzername = n.benutzername and k.post_id = v_post and k.nr = n.nr);

  insert into core.instagram_personen (benutzername, name)
  select distinct on (a.benutzername) a.benutzername, a.name from (
    select benutzername, name from jsonb_to_recordset(v_l) n(benutzername text, name text)
    union all select benutzername, name from jsonb_to_recordset(v_k) n(benutzername text, name text)) a
   order by a.benutzername, a.name nulls last
  on conflict (benutzername) do update set name = coalesce(excluded.name, core.instagram_personen.name), zuletzt = now();

  insert into core.instagram_likes (post_id, person_id)
  select v_post, ip.person_id from jsonb_to_recordset(v_l) n(benutzername text)
    join core.instagram_personen ip on ip.benutzername = n.benutzername
  on conflict do nothing;
  insert into core.instagram_kommentare (post_id, person_id, nr, text)
  select v_post, ip.person_id, least(n.nr, 50), n.text from jsonb_to_recordset(v_k) n(benutzername text, nr integer, text text)
    join core.instagram_personen ip on ip.benutzername = n.benutzername
  on conflict (post_id, person_id, nr) do update set text = coalesce(excluded.text, core.instagram_kommentare.text);

  v_auto := core.instagram_auto_zuordnen(v_post);
  perform core.instagram_events(p_post_id => v_post);
  return jsonb_build_object('post_id', v_post, 'gesamt', jsonb_array_length(v_l), 'neu_personen', v_neu_p, 'neu_likes', v_neu_l,
                            'kommentare', jsonb_array_length(v_k), 'neu_kommentare', v_neu_k, 'zugeordnet', v_auto->'zugeordnet');
end $$;

-- p_aktion: zuordnen | loesen | ignorieren | zurueckholen | kontakt_anlegen
create or replace function public.dashboard_instagram_person(p_person_id uuid, p_aktion text, p_contact_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_p core.instagram_personen; z record; v_c uuid; v_n integer;
begin
  select * into v_p from core.instagram_personen where person_id = p_person_id;
  if not found then raise exception 'Person nicht gefunden'; end if;
  if p_aktion = 'zuordnen' then
    if p_contact_id is null or not exists (select 1 from core.contacts where contact_id = p_contact_id) then raise exception 'Kontakt nicht gefunden'; end if;
    perform core.instagram_zuordnen(p_person_id, p_contact_id);
    return jsonb_build_object('person_id', p_person_id, 'contact_id', p_contact_id);
  elsif p_aktion = 'kontakt_anlegen' then
    select * into z from core.name_zerlegen(coalesce(core.linkedin_name_sauber(v_p.name), v_p.benutzername));
    select count(*), min(c.contact_id::text)::uuid into v_n, v_c
      from core.contacts c where z.nachname is not null and lower(concat_ws(' ', c.vorname, c.nachname)) = lower(concat_ws(' ', z.vorname, z.nachname));
    if v_n <> 1 then
      insert into core.contacts (titel, vorname, nachname, herkunft) values (z.titel, z.vorname, z.nachname, 'instagram')
      returning contact_id into v_c;
    end if;
    perform core.instagram_zuordnen(p_person_id, v_c);
    return jsonb_build_object('person_id', p_person_id, 'contact_id', v_c);
  elsif p_aktion in ('loesen', 'ignorieren') then
    delete from core.events where source = 'instagram' and properties->>'person_id' = p_person_id::text;
    update core.instagram_personen set contact_id = null, ignoriert = (p_aktion = 'ignorieren') where person_id = p_person_id;
  elsif p_aktion = 'zurueckholen' then
    update core.instagram_personen set ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  else
    raise exception 'Unbekannte Aktion %', p_aktion;
  end if;
  return jsonb_build_object('person_id', p_person_id);
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_instagram()', 'public.dashboard_instagram_erfassen(jsonb, text)',
                           'public.dashboard_instagram_person(uuid, text, uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
