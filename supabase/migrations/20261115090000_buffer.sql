-- =====================================================================
-- Buffer: gesendete Beiträge und ihre Kennzahlen
--
-- Die Edge Function `buffer-import` holt zweimal täglich alle gesendeten
-- Beiträge aller Buffer-Kanäle (LinkedIn Daniel + Firmenseite, Facebook,
-- Instagram) samt Kennzahlen und übergibt sie an public.ingest_buffer.
-- Buffer selbst aktualisiert die Kennzahlen einmal am Tag. Personenbezug:
-- keiner – Buffer liefert nur Summen.
--
-- LinkedIn-Beiträge von Daniel und der Firmenseite werden zusätzlich als
-- core.linkedin_beitraege geführt (Soll-Zahl für den Vollständigkeits-
-- abgleich im Cockpit). Andere LinkedIn-Profile werden dort NICHT angelegt.
-- =====================================================================

create table analytics.buffer_kanaele (
  channel_id   text primary key,
  name         text,
  service      text not null,
  typ          text,
  link         text,
  aktualisiert timestamptz not null default now()
);

create table analytics.buffer_beitraege (
  post_id          text primary key,
  channel_id       text not null,
  service          text not null,
  gesendet         timestamptz,
  link             text,
  text             text,
  reaktionen       integer,
  kommentare       integer,
  impressionen     integer,
  reichweite       integer,
  klicks           integer,
  reposts          integer,
  engagement_rate  numeric,
  kennzahlen       jsonb not null default '{}'::jsonb,   -- alle Kennzahlen, {typ: wert}
  kennzahlen_stand timestamptz,
  abgerufen_am     timestamptz not null default now()
);
create index buffer_beitraege_gesendet_idx on analytics.buffer_beitraege (gesendet desc);

-- Tagesstand je Beitrag (Wachstum über die Zeit)
create table analytics.buffer_tage (
  post_id      text not null references analytics.buffer_beitraege on delete cascade,
  tag          date not null,
  reaktionen   integer,
  kommentare   integer,
  impressionen integer,
  reichweite   integer,
  primary key (post_id, tag)
);

alter table analytics.buffer_kanaele   enable row level security;
alter table analytics.buffer_beitraege enable row level security;
alter table analytics.buffer_tage      enable row level security;
grant all on analytics.buffer_kanaele, analytics.buffer_beitraege, analytics.buffer_tage to service_role;

-- Reaktionen von Seiten/Firmen (ohne Personenprofil), z. B. die Firmenseite
-- auf ihren eigenen Beitrag. Buffer zählt sie mit, darum für den Abgleich.
alter table core.linkedin_beitraege add column weitere_reaktionen integer not null default 0;

-- ---------------------------------------------------------------------
-- Annahme. p: { kanaele: [{id, name, service, typ, link}],
--               beitraege: [{id, channel_id, service, gesendet, link, text, kennzahlen:{typ:wert}, kennzahlen_stand}] }
-- ---------------------------------------------------------------------
create or replace function public.ingest_buffer(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare n_beitraege integer; n_linkedin integer;
begin
  insert into analytics.buffer_kanaele (channel_id, name, service, typ, link, aktualisiert)
  select x->>'id', left(x->>'name', 200), x->>'service', x->>'typ', left(x->>'link', 500), now()
    from jsonb_array_elements(coalesce(p->'kanaele', '[]'::jsonb)) x
   where x->>'id' is not null and x->>'service' is not null
  on conflict (channel_id) do update
     set name = excluded.name, service = excluded.service, typ = excluded.typ, link = excluded.link, aktualisiert = now();

  with roh as (
    select x->>'id' as post_id, x->>'channel_id' as channel_id, x->>'service' as service,
           (x->>'gesendet')::timestamptz as gesendet, left(x->>'link', 500) as link, left(x->>'text', 1000) as text,
           coalesce(x->'kennzahlen', '{}'::jsonb) as k, (x->>'kennzahlen_stand')::timestamptz as stand
      from jsonb_array_elements(coalesce(p->'beitraege', '[]'::jsonb)) x
     where x->>'id' is not null and x->>'channel_id' is not null
  )
  insert into analytics.buffer_beitraege (post_id, channel_id, service, gesendet, link, text, reaktionen, kommentare, impressionen,
                                         reichweite, klicks, reposts, engagement_rate, kennzahlen, kennzahlen_stand, abgerufen_am)
  select post_id, channel_id, service, gesendet, link, text,
         (k->>'reactions')::numeric::integer, (k->>'comments')::numeric::integer, (k->>'impressions')::numeric::integer,
         (k->>'reach')::numeric::integer, (k->>'clicks')::numeric::integer, (k->>'reposts')::numeric::integer,
         (k->>'engagementRate')::numeric, k, stand, now()
    from roh
  on conflict (post_id) do update
     set channel_id = excluded.channel_id, service = excluded.service, gesendet = excluded.gesendet, link = excluded.link,
         text = excluded.text, reaktionen = excluded.reaktionen, kommentare = excluded.kommentare,
         impressionen = excluded.impressionen, reichweite = excluded.reichweite, klicks = excluded.klicks,
         reposts = excluded.reposts, engagement_rate = excluded.engagement_rate, kennzahlen = excluded.kennzahlen,
         kennzahlen_stand = excluded.kennzahlen_stand, abgerufen_am = now();
  get diagnostics n_beitraege = row_count;

  -- Tagesstand (Tag nach deutscher Zeit; mehrere Läufe am Tag überschreiben)
  insert into analytics.buffer_tage (post_id, tag, reaktionen, kommentare, impressionen, reichweite)
  select b.post_id, (now() at time zone 'Europe/Berlin')::date, b.reaktionen, b.kommentare, b.impressionen, b.reichweite
    from analytics.buffer_beitraege b
   where b.post_id in (select x->>'id' from jsonb_array_elements(coalesce(p->'beitraege', '[]'::jsonb)) x)
  on conflict (post_id, tag) do update
     set reaktionen = excluded.reaktionen, kommentare = excluded.kommentare,
         impressionen = excluded.impressionen, reichweite = excluded.reichweite;

  -- LinkedIn: nur Firmenseite (Seite) und Daniels Profil
  create temporary table if not exists pg_temp.buffer_li (post_id text, kanal text, titel text, link text, tag date,
                                                   reaktionen integer, kommentare integer, stand timestamptz) on commit drop;
  truncate pg_temp.buffer_li;
  insert into pg_temp.buffer_li
  select b.post_id,
         case when k.typ = 'page' then 'firmenseite' else 'daniel' end,
         coalesce(nullif(left(regexp_replace(split_part(trim(b.text), E'\n', 1), '\s+', ' ', 'g'), 90), ''), 'Beitrag'),
         b.link, (b.gesendet at time zone 'Europe/Berlin')::date, b.reaktionen, b.kommentare, b.kennzahlen_stand
    from analytics.buffer_beitraege b
    join analytics.buffer_kanaele k on k.channel_id = b.channel_id
   where b.service = 'linkedin'
     and (k.typ = 'page' or (k.typ = 'profile' and (k.name ilike 'daniel%' or k.link ilike '%/in/daniel-stroebel%')));

  -- Von Hand angelegte Beiträge mit gleichem Link übernehmen
  update core.linkedin_beitraege lb
     set buffer_post_id = l.post_id
    from pg_temp.buffer_li l
   where lb.buffer_post_id is null and lb.url is not null and lb.url = l.link
     and not exists (select 1 from core.linkedin_beitraege x where x.buffer_post_id = l.post_id);

  insert into core.linkedin_beitraege (kanal, titel, url, veroeffentlicht, buffer_post_id, reaktionen_laut_buffer,
                                       kommentare_laut_buffer, buffer_stand, angelegt_von)
  select l.kanal, l.titel, l.link, l.tag, l.post_id, l.reaktionen, l.kommentare, l.stand, 'buffer'
    from pg_temp.buffer_li l
   where not exists (select 1 from core.linkedin_beitraege x where x.url = l.link and x.buffer_post_id is distinct from l.post_id)
  on conflict (buffer_post_id) where buffer_post_id is not null do update
     set reaktionen_laut_buffer = excluded.reaktionen_laut_buffer,
         kommentare_laut_buffer = excluded.kommentare_laut_buffer,
         buffer_stand = excluded.buffer_stand,
         veroeffentlicht = coalesce(core.linkedin_beitraege.veroeffentlicht, excluded.veroeffentlicht),
         url = coalesce(core.linkedin_beitraege.url, excluded.url);
  get diagnostics n_linkedin = row_count;

  return jsonb_build_object('beitraege', n_beitraege, 'linkedin', n_linkedin);
end $$;

-- ---------------------------------------------------------------------
-- Cockpit: LinkedIn-Übersicht mit Buffer-Zahlen und „nachtragen“
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
    select lower(concat_ws(' ', c.vorname, c.nachname)) as k, min(c.contact_id::text)::uuid as contact_id, count(*) as n
      from core.contacts c where c.vorname is not null
     group by 1
  ), beitr as (
    select b.*, bb.impressionen, bb.reichweite, bb.engagement_rate,
           (select count(*) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id) as erfasst,
           (select max(r.erfasst_am) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id) as zuletzt_erfasst
      from core.linkedin_beitraege b
      left join analytics.buffer_beitraege bb on bb.post_id = b.buffer_post_id
  )
  select jsonb_build_object(
    'beitraege', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'beitrag_id', b.beitrag_id, 'kanal', b.kanal, 'titel', b.titel, 'url', b.url, 'veroeffentlicht', b.veroeffentlicht,
               'erfasst', b.erfasst, 'weitere', b.weitere_reaktionen, 'zuletzt_erfasst', b.zuletzt_erfasst,
               'laut_buffer', b.reaktionen_laut_buffer, 'kommentare_laut_buffer', b.kommentare_laut_buffer, 'buffer_stand', b.buffer_stand,
               'impressionen', b.impressionen, 'engagement_rate', b.engagement_rate, 'aus_buffer', b.buffer_post_id is not null,
               'fehlen', greatest(coalesce(b.reaktionen_laut_buffer, 0) - b.erfasst - b.weitere_reaktionen, 0),
               -- „nachtragen“: schon einmal erfasst oder jünger als 30 Tage
               'beobachtet', b.erfasst > 0 or b.weitere_reaktionen > 0 or b.veroeffentlicht >= current_date - 30 or b.buffer_post_id is null)
             order by coalesce(b.veroeffentlicht, b.created_at::date) desc, b.created_at desc), '[]'::jsonb)
        from beitr b),
    'buffer', (
      select jsonb_build_object('stand', max(kennzahlen_stand), 'abgerufen', max(abgerufen_am), 'beitraege', count(*))
        from analytics.buffer_beitraege),
    'import', (
      select jsonb_build_object('gestartet', gestartet, 'zeilen', zeilen, 'fehler', fehler)
        from analytics.import_laeufe where quelle = 'buffer' order by gestartet desc limit 1),
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
-- Einfügen: zusätzlich p.weitere = Reaktionen von Seiten ohne Personenprofil
-- (höchster eingefügter Wert gilt)
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

  update core.linkedin_beitraege
     set weitere_reaktionen = greatest(weitere_reaktionen, least(coalesce((p->>'weitere')::integer, 0), 50))
   where beitrag_id = v_beitrag;

  perform core.linkedin_events(p_beitrag_id => v_beitrag);
  return jsonb_build_object('beitrag_id', v_beitrag, 'gesamt', v_gesamt, 'neu_personen', v_neu_p, 'neu_reaktionen', v_neu_r);
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.ingest_buffer(jsonb)', 'public.dashboard_linkedin()', 'public.dashboard_linkedin_erfassen(jsonb, text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
