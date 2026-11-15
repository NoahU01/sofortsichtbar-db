-- =====================================================================
-- LinkedIn: nur Beiträge, die zu sofort sichtbar gehören, zählen
--
-- Daniel postet auch für empiria. Zugehörigkeit je Beitrag:
--   sofortsichtbar  #sofortsichtbar im Text oder Buffer-Tag „so.si. …“
--                   (Firmenseite und von Hand angelegte Beiträge immer)
--   empiria         #empiria im Text
--   unklar          kein Kennzeichen → im Cockpit ausgeblendet, von Hand zuordnen
-- Erkannt wird im buffer-import über den vollen Text (gespeichert werden nur
-- 1.000 Zeichen) und die Buffer-Tags. Von Hand gesetzte Zuordnung hat Vorrang.
-- Reaktionen auf andere Beiträge bleiben gespeichert, zählen aber nicht:
-- keine Events in der Timeline, nicht in der Personenliste.
-- =====================================================================

alter table analytics.buffer_beitraege
  add column tags text[] not null default '{}',
  add column kennzeichen text check (kennzeichen in ('sofortsichtbar', 'empiria'));

alter table core.linkedin_beitraege
  add column zugehoerigkeit text not null default 'sofortsichtbar' check (zugehoerigkeit in ('sofortsichtbar', 'empiria', 'unklar')),
  add column zugehoerigkeit_manuell boolean not null default false;

-- Daniels Buffer-Beiträge: bis zum nächsten Abruf unklar
update core.linkedin_beitraege set zugehoerigkeit = 'unklar' where kanal = 'daniel' and buffer_post_id is not null;

-- Timeline-Events nur für Beiträge von sofort sichtbar
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
   where p.contact_id is not null and not p.ignoriert and b.zugehoerigkeit = 'sofortsichtbar'
     and (p_person_id is null or r.person_id = p_person_id)
     and (p_beitrag_id is null or r.beitrag_id = p_beitrag_id)
  on conflict (event_id) do update
     set contact_id = excluded.contact_id, properties = excluded.properties;
  get diagnostics n = row_count;
  return n;
end $$;

-- Events an die aktuelle Zugehörigkeit anpassen
create or replace function core.linkedin_signale_abgleichen()
returns void
language plpgsql set search_path = ''
as $$
begin
  delete from core.events e
   where e.source = 'linkedin' and e.event_name = 'linkedin_reaction'
     and exists (select 1 from core.linkedin_beitraege b
                  where b.beitrag_id::text = e.properties->>'beitrag_id' and b.zugehoerigkeit <> 'sofortsichtbar');
  perform core.linkedin_events();
end $$;

-- Cockpit: Beitrag von Hand zuordnen
create or replace function public.dashboard_linkedin_zuordnen(p_beitrag_id uuid, p_zugehoerigkeit text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if p_zugehoerigkeit not in ('sofortsichtbar', 'empiria', 'unklar') then raise exception 'unbekannte Zugehörigkeit'; end if;
  update core.linkedin_beitraege set zugehoerigkeit = p_zugehoerigkeit, zugehoerigkeit_manuell = true
   where beitrag_id = p_beitrag_id;
  if not found then return false; end if;
  perform core.linkedin_signale_abgleichen();
  return true;
end $$;

-- Import mit Tags und Kennzeichen
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
           coalesce(x->'kennzahlen', '{}'::jsonb) as k, (x->>'kennzahlen_stand')::timestamptz as stand,
           coalesce((select array_agg(left(t, 100)) from jsonb_array_elements_text(coalesce(x->'tags', '[]'::jsonb)) t), '{}') as tags,
           case when x->>'kennzeichen' in ('sofortsichtbar', 'empiria') then x->>'kennzeichen' end as kennzeichen
      from jsonb_array_elements(coalesce(p->'beitraege', '[]'::jsonb)) x
     where x->>'id' is not null and x->>'channel_id' is not null
  )
  insert into analytics.buffer_beitraege (post_id, channel_id, service, gesendet, link, text, reaktionen, kommentare, impressionen,
                                         reichweite, klicks, reposts, engagement_rate, kennzahlen, kennzahlen_stand, abgerufen_am, tags, kennzeichen)
  select post_id, channel_id, service, gesendet, link, text,
         (k->>'reactions')::numeric::integer, (k->>'comments')::numeric::integer, (k->>'impressions')::numeric::integer,
         (k->>'reach')::numeric::integer, (k->>'clicks')::numeric::integer, (k->>'reposts')::numeric::integer,
         (k->>'engagementRate')::numeric, k, stand, now(), tags, kennzeichen
    from roh
  on conflict (post_id) do update
     set channel_id = excluded.channel_id, service = excluded.service, gesendet = excluded.gesendet, link = excluded.link,
         text = excluded.text, reaktionen = excluded.reaktionen, kommentare = excluded.kommentare,
         impressionen = excluded.impressionen, reichweite = excluded.reichweite, klicks = excluded.klicks,
         reposts = excluded.reposts, engagement_rate = excluded.engagement_rate, kennzahlen = excluded.kennzahlen,
         kennzahlen_stand = excluded.kennzahlen_stand, abgerufen_am = now(), tags = excluded.tags, kennzeichen = excluded.kennzeichen;
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
                                                   reaktionen integer, kommentare integer, stand timestamptz, zugehoerigkeit text) on commit drop;
  truncate pg_temp.buffer_li;
  insert into pg_temp.buffer_li
  select b.post_id,
         case when k.typ = 'page' then 'firmenseite' else 'daniel' end,
         coalesce(nullif(left(regexp_replace(split_part(trim(b.text), E'\n', 1), '\s+', ' ', 'g'), 90), ''), 'Beitrag'),
         b.link, (b.gesendet at time zone 'Europe/Berlin')::date, b.reaktionen, b.kommentare, b.kennzahlen_stand,
         case when k.typ = 'page' then 'sofortsichtbar' else coalesce(b.kennzeichen, 'unklar') end
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
                                       kommentare_laut_buffer, buffer_stand, angelegt_von, zugehoerigkeit)
  select l.kanal, l.titel, l.link, l.tag, l.post_id, l.reaktionen, l.kommentare, l.stand, 'buffer', l.zugehoerigkeit
    from pg_temp.buffer_li l
   where not exists (select 1 from core.linkedin_beitraege x where x.url = l.link and x.buffer_post_id is distinct from l.post_id)
  on conflict (buffer_post_id) where buffer_post_id is not null do update
     set reaktionen_laut_buffer = excluded.reaktionen_laut_buffer,
         kommentare_laut_buffer = excluded.kommentare_laut_buffer,
         buffer_stand = excluded.buffer_stand,
         veroeffentlicht = coalesce(core.linkedin_beitraege.veroeffentlicht, excluded.veroeffentlicht),
         url = coalesce(core.linkedin_beitraege.url, excluded.url),
         zugehoerigkeit = case when core.linkedin_beitraege.zugehoerigkeit_manuell then core.linkedin_beitraege.zugehoerigkeit
                               else excluded.zugehoerigkeit end;
  get diagnostics n_linkedin = row_count;

  perform core.linkedin_signale_abgleichen();

  return jsonb_build_object('beitraege', n_beitraege, 'linkedin', n_linkedin);
end $$;

-- Übersicht: nur sofort sichtbar, Ausgeblendete zum Zuordnen
create or replace function public.dashboard_linkedin()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with zaehl as (
    select r.person_id, count(*) as reaktionen, max(r.erfasst_am) as letzte,
           count(*) filter (where b.kanal = 'firmenseite') as firmenseite,
           count(*) filter (where b.kanal = 'daniel') as daniel
      from core.linkedin_reaktionen r join core.linkedin_beitraege b on b.beitrag_id = r.beitrag_id
     where b.zugehoerigkeit = 'sofortsichtbar'
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
     where b.zugehoerigkeit = 'sofortsichtbar'
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
    'ausgeblendet', (
      select jsonb_build_object(
        'unklar', count(*) filter (where b.zugehoerigkeit = 'unklar'),
        'empiria', count(*) filter (where b.zugehoerigkeit = 'empiria'),
        'beitraege', coalesce(jsonb_agg(jsonb_build_object(
                       'beitrag_id', b.beitrag_id, 'titel', b.titel, 'url', b.url, 'veroeffentlicht', b.veroeffentlicht,
                       'zugehoerigkeit', b.zugehoerigkeit, 'laut_buffer', b.reaktionen_laut_buffer)
                     order by b.veroeffentlicht desc nulls last) filter (where b.zugehoerigkeit = 'unklar'), '[]'::jsonb))
        from core.linkedin_beitraege b where b.zugehoerigkeit <> 'sofortsichtbar'),
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


select core.linkedin_signale_abgleichen();

do $$
declare f text;
begin
  foreach f in array array['public.ingest_buffer(jsonb)', 'public.dashboard_linkedin()', 'public.dashboard_linkedin_zuordnen(uuid, text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
