-- =====================================================================
-- LinkedIn: Kommentare und Ausschlussliste
--
-- 1) core.linkedin_kommentare: wer welchen Beitrag kommentiert hat (mit Text,
--    falls bekannt). nr zählt die Kommentare einer Person je Beitrag, damit
--    ein erneutes Einfügen nichts doppelt anlegt. Ist die Person einem
--    Kontakt zugeordnet, steht jeder Kommentar als linkedin_comment im Verlauf.
-- 2) Ausschlussliste = linkedin_personen.ignoriert (Team, Bekannte, eigene
--    Seiten, fremde Unternehmen). Diese Personen werden erfasst und zählen für
--    die Vollständigkeit gegen Buffer, werden aber nie einem Kontakt
--    zugeordnet und erzeugen keine Signale. Gepflegt unter Einstellungen.
-- 3) typ: Reaktionen kommen auch von Unternehmensseiten (empiria GmbH …).
-- =====================================================================

alter table core.linkedin_personen add column typ text not null default 'person' check (typ in ('person', 'seite'));
alter table core.linkedin_personen add column ausschluss_grund text;

create table core.linkedin_kommentare (
  beitrag_id  uuid not null references core.linkedin_beitraege on delete cascade,
  person_id   uuid not null references core.linkedin_personen on delete cascade,
  nr          integer not null default 1 check (nr between 1 and 50),
  text        text,
  erfasst_am  timestamptz not null default now(),
  erfasst_von text,
  primary key (beitrag_id, person_id, nr)
);
create index linkedin_kommentare_person on core.linkedin_kommentare (person_id);
alter table core.linkedin_kommentare enable row level security;
grant all on core.linkedin_kommentare to service_role;

update core.event_types set beschreibung = 'Kommentar auf einen LinkedIn-Beitrag (Firmenseite oder Daniel); Text in properties.text'
 where event_name = 'linkedin_comment';

-- Ausgeschlossene sind nie einem Kontakt zugeordnet
update core.linkedin_personen set contact_id = null where ignoriert;

-- ---------------------------------------------------------------------
-- Signale: Reaktionen und Kommentare
-- ---------------------------------------------------------------------
create or replace function core.linkedin_events(p_person_id uuid default null, p_beitrag_id uuid default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer; m integer;
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

  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  select 'lik:' || k.beitrag_id || ':' || k.person_id || ':' || k.nr, 'linkedin_comment', k.erfasst_am, p.contact_id, 'linkedin',
         jsonb_strip_nulls(jsonb_build_object('text', left(k.text, 1000), 'beitrag', b.titel, 'beitrag_id', b.beitrag_id, 'url', b.url,
                                              'kanal', b.kanal, 'veroeffentlicht', b.veroeffentlicht, 'person_id', p.person_id)),
         'not_required'
    from core.linkedin_kommentare k
    join core.linkedin_personen p on p.person_id = k.person_id
    join core.linkedin_beitraege b on b.beitrag_id = k.beitrag_id
   where p.contact_id is not null and not p.ignoriert and b.zugehoerigkeit = 'sofortsichtbar'
     and (p_person_id is null or k.person_id = p_person_id)
     and (p_beitrag_id is null or k.beitrag_id = p_beitrag_id)
  on conflict (event_id) do update
     set contact_id = excluded.contact_id, properties = excluded.properties;
  get diagnostics m = row_count;
  return n + m;
end $$;

create or replace function core.linkedin_signale_abgleichen()
returns void
language plpgsql set search_path = ''
as $$
begin
  delete from core.events e
   where e.source = 'linkedin' and e.event_name in ('linkedin_reaction', 'linkedin_comment')
     and exists (select 1 from core.linkedin_beitraege b
                  where b.beitrag_id::text = e.properties->>'beitrag_id' and b.zugehoerigkeit <> 'sofortsichtbar');
  perform core.linkedin_events();
end $$;

-- ---------------------------------------------------------------------
-- Erfassen: Reaktionen wie bisher, dazu Kommentare
--   p.personen:   [{name, position, art, typ}]
--   p.kommentare: [{name, text, typ}]   mehrere je Person = mehrere Kommentare
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin_erfassen(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_beitrag uuid := nullif(p->>'beitrag_id', '')::uuid;
  v_url     text := nullif(trim(p#>>'{beitrag,url}'), '');
  v_liste   jsonb; v_komm jsonb;
  v_gesamt  integer; v_neu_p integer; v_neu_r integer; v_neu_k integer;
begin
  -- Beitrag ohne Buffer anlegen: nur noch intern (die Cockpit-Bridge lässt es nicht mehr zu)
  if v_beitrag is null and p ? 'beitrag' and jsonb_typeof(p->'beitrag') = 'object' then
    if v_url is not null then select beitrag_id into v_beitrag from core.linkedin_beitraege where url = v_url; end if;
    if v_beitrag is null then
      insert into core.linkedin_beitraege (kanal, titel, url, veroeffentlicht, angelegt_von)
      values (p#>>'{beitrag,kanal}', coalesce(nullif(trim(p#>>'{beitrag,titel}'), ''), 'Beitrag'), v_url,
              nullif(p#>>'{beitrag,veroeffentlicht}', '')::date, p_von)
      returning beitrag_id into v_beitrag;
    end if;
  end if;
  if v_beitrag is null or not exists (select 1 from core.linkedin_beitraege where beitrag_id = v_beitrag) then
    raise exception 'Beitrag nicht gefunden';
  end if;

  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_liste from (
    select distinct on (core.linkedin_schluessel(x->>'name'))
           core.linkedin_schluessel(x->>'name') as schluessel, left(trim(x->>'name'), 200) as name,
           left(nullif(trim(x->>'position'), ''), 300) as position,
           case when x->>'art' in ('like', 'celebrate', 'support', 'love', 'insightful', 'funny') then x->>'art' else 'reaktion' end as art,
           case when x->>'typ' = 'seite' then 'seite' else 'person' end as typ
      from jsonb_array_elements(coalesce(p->'personen', '[]'::jsonb)) x
     where nullif(trim(x->>'name'), '') is not null) z;
  v_gesamt := jsonb_array_length(v_liste);

  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_komm from (
    select core.linkedin_schluessel(x->>'name') as schluessel, left(trim(x->>'name'), 200) as name,
           left(nullif(trim(x->>'text'), ''), 5000) as text,
           case when x->>'typ' = 'seite' then 'seite' else 'person' end as typ,
           row_number() over (partition by core.linkedin_schluessel(x->>'name') order by o)::integer as nr
      from jsonb_array_elements(coalesce(p->'kommentare', '[]'::jsonb)) with ordinality t(x, o)
     where nullif(trim(x->>'name'), '') is not null) z;

  select count(*) filter (where lp.person_id is null), count(*) filter (where r.person_id is null)
    into v_neu_p, v_neu_r
    from jsonb_to_recordset(v_liste) n(schluessel text)
    left join core.linkedin_personen lp on lp.schluessel = n.schluessel
    left join core.linkedin_reaktionen r on r.person_id = lp.person_id and r.beitrag_id = v_beitrag;

  select count(*) filter (where k.person_id is null) into v_neu_k
    from jsonb_to_recordset(v_komm) n(schluessel text, nr integer)
    left join core.linkedin_personen lp on lp.schluessel = n.schluessel
    left join core.linkedin_kommentare k on k.person_id = lp.person_id and k.beitrag_id = v_beitrag and k.nr = n.nr;

  insert into core.linkedin_personen (schluessel, name, position, typ)
  select n.schluessel, n.name, n.position, n.typ from jsonb_to_recordset(v_liste) n(schluessel text, name text, position text, typ text)
  union all
  select distinct on (n.schluessel) n.schluessel, n.name, null, n.typ from jsonb_to_recordset(v_komm) n(schluessel text, name text, typ text)
   where not exists (select 1 from jsonb_to_recordset(v_liste) l(schluessel text) where l.schluessel = n.schluessel)
  on conflict (schluessel) do update
     set position = coalesce(excluded.position, core.linkedin_personen.position), zuletzt = now(),
         typ = case when excluded.typ = 'seite' then 'seite' else core.linkedin_personen.typ end;

  insert into core.linkedin_reaktionen (beitrag_id, person_id, art)
  select v_beitrag, lp.person_id, n.art
    from jsonb_to_recordset(v_liste) n(schluessel text, art text)
    join core.linkedin_personen lp on lp.schluessel = n.schluessel
  on conflict (beitrag_id, person_id) do update set art = excluded.art;

  insert into core.linkedin_kommentare (beitrag_id, person_id, nr, text, erfasst_von)
  select v_beitrag, lp.person_id, least(n.nr, 50), n.text, p_von
    from jsonb_to_recordset(v_komm) n(schluessel text, nr integer, text text)
    join core.linkedin_personen lp on lp.schluessel = n.schluessel
  on conflict (beitrag_id, person_id, nr) do update set text = coalesce(excluded.text, core.linkedin_kommentare.text);

  update core.linkedin_beitraege
     set weitere_reaktionen = greatest(weitere_reaktionen, least(coalesce((p->>'weitere')::integer, 0), 50))
   where beitrag_id = v_beitrag;

  perform core.linkedin_events(p_beitrag_id => v_beitrag);
  return jsonb_build_object('beitrag_id', v_beitrag, 'gesamt', v_gesamt, 'neu_personen', v_neu_p, 'neu_reaktionen', v_neu_r,
                            'kommentare', jsonb_array_length(v_komm), 'neu_kommentare', v_neu_k);
end $$;

-- ---------------------------------------------------------------------
-- Ausschlussliste (Einstellungen)
-- ---------------------------------------------------------------------
create or replace function public.dashboard_ausschluss()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'person_id', p.person_id, 'name', p.name, 'typ', p.typ, 'grund', p.ausschluss_grund,
           'reaktionen', (select count(*) from core.linkedin_reaktionen r where r.person_id = p.person_id),
           'kommentare', (select count(*) from core.linkedin_kommentare k where k.person_id = p.person_id))
         order by p.typ desc, p.name), '[]'::jsonb)
    from core.linkedin_personen p where p.ignoriert
$$;

-- p_aktion: 'hinzufuegen' (per Name, legt die Person an falls nötig) | 'entfernen' (per person_id)
create or replace function public.dashboard_ausschluss_setzen(p_aktion text, p_name text default null, p_person_id uuid default null,
                                                              p_grund text default null, p_typ text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_schl text;
begin
  if p_aktion = 'hinzufuegen' then
    v_schl := core.linkedin_schluessel(p_name);
    if v_schl is null or v_schl = '' then raise exception 'Name fehlt'; end if;
    insert into core.linkedin_personen (schluessel, name, ignoriert, contact_id, ausschluss_grund, typ)
    values (v_schl, left(trim(p_name), 200), true, null, nullif(trim(p_grund), ''), case when p_typ = 'seite' then 'seite' else 'person' end)
    on conflict (schluessel) do update
       set ignoriert = true, contact_id = null,
           ausschluss_grund = coalesce(excluded.ausschluss_grund, core.linkedin_personen.ausschluss_grund),
           typ = case when p_typ = 'seite' then 'seite' else core.linkedin_personen.typ end
    returning person_id into v_id;
    delete from core.events where source = 'linkedin' and properties->>'person_id' = v_id::text;
  elsif p_aktion = 'entfernen' then
    update core.linkedin_personen set ignoriert = false, ausschluss_grund = null where person_id = p_person_id and ignoriert
    returning person_id into v_id;
    if v_id is null then raise exception 'Person nicht auf der Ausschlussliste'; end if;
  else
    raise exception 'Unbekannte Aktion %', p_aktion;
  end if;
  return jsonb_build_object('person_id', v_id);
end $$;

-- „Ignorieren“ im LinkedIn-Bereich setzt jetzt auch die Zuordnung zurück
create or replace function public.dashboard_linkedin_person(p_person_id uuid, p_aktion text, p_contact_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_p core.linkedin_personen;
  v_contact uuid;
  z record;
begin
  select * into v_p from core.linkedin_personen where person_id = p_person_id;
  if not found then raise exception 'Person nicht gefunden'; end if;

  if p_aktion = 'zuordnen' then
    if p_contact_id is null or not exists (select 1 from core.contacts where contact_id = p_contact_id) then
      raise exception 'Kontakt nicht gefunden';
    end if;
    v_contact := p_contact_id;
  elsif p_aktion = 'kontakt_anlegen' then
    select * into z from core.name_zerlegen(v_p.name);
    insert into core.contacts (titel, vorname, nachname, position, herkunft)
    values (z.titel, z.vorname, z.nachname, v_p.position, 'linkedin_reaktion')
    returning contact_id into v_contact;
    if v_p.follower_seit is not null then
      update core.contacts set tags = array['linkedin_follower'] where contact_id = v_contact;
    end if;
  elsif p_aktion in ('loesen', 'ignorieren') then
    delete from core.events where source = 'linkedin' and properties->>'person_id' = p_person_id::text;
    update core.linkedin_personen set contact_id = null, ignoriert = (p_aktion = 'ignorieren')
     where person_id = p_person_id;
    return jsonb_build_object('person_id', p_person_id);
  elsif p_aktion = 'zurueckholen' then
    update core.linkedin_personen set ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
    perform core.linkedin_events(p_person_id => p_person_id);
    return jsonb_build_object('person_id', p_person_id);
  else
    raise exception 'Unbekannte Aktion %', p_aktion;
  end if;

  update core.linkedin_personen set contact_id = v_contact, ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  delete from core.events where source = 'linkedin' and properties->>'person_id' = p_person_id::text and contact_id <> v_contact;
  perform core.linkedin_events(p_person_id => p_person_id);
  if v_p.profil_url is not null then
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_contact, 'linkedin_profile_url', v_p.profil_url, 'linkedin')
    on conflict (identity_type, identity_value) do nothing;
  end if;
  return jsonb_build_object('person_id', p_person_id, 'contact_id', v_contact);
end $$;

-- ---------------------------------------------------------------------
-- LinkedIn-Übersicht: Kommentare je Beitrag und Person
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with zaehl as (
    select x.person_id, count(*) filter (where x.was = 'r') as reaktionen, count(*) filter (where x.was = 'k') as kommentare,
           max(x.erfasst_am) as letzte,
           count(*) filter (where x.was = 'r' and x.kanal = 'firmenseite') as firmenseite,
           count(*) filter (where x.was = 'r' and x.kanal = 'daniel') as daniel
      from (select r.person_id, 'r' as was, r.erfasst_am, b.kanal
              from core.linkedin_reaktionen r join core.linkedin_beitraege b on b.beitrag_id = r.beitrag_id
             where b.zugehoerigkeit = 'sofortsichtbar'
            union all
            select k.person_id, 'k', k.erfasst_am, b.kanal
              from core.linkedin_kommentare k join core.linkedin_beitraege b on b.beitrag_id = k.beitrag_id
             where b.zugehoerigkeit = 'sofortsichtbar') x
     group by x.person_id
  ), kontaktnamen as (
    select lower(concat_ws(' ', c.vorname, c.nachname)) as k, min(c.contact_id::text)::uuid as contact_id, count(*) as n
      from core.contacts c where c.vorname is not null
     group by 1
  ), beitr as (
    select b.*, bb.impressionen, bb.reichweite, bb.engagement_rate,
           (select count(*) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id) as erfasst,
           (select count(*) from core.linkedin_kommentare k where k.beitrag_id = b.beitrag_id) as kommentare_erfasst,
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
               'kommentare_erfasst', b.kommentare_erfasst,
               'laut_buffer', b.reaktionen_laut_buffer, 'kommentare_laut_buffer', b.kommentare_laut_buffer, 'buffer_stand', b.buffer_stand,
               'impressionen', b.impressionen, 'engagement_rate', b.engagement_rate, 'aus_buffer', b.buffer_post_id is not null,
               'fehlen', greatest(coalesce(b.reaktionen_laut_buffer, 0) - b.erfasst - b.weitere_reaktionen, 0),
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
               'person_id', p.person_id, 'name', p.name, 'position', p.position, 'ignoriert', p.ignoriert, 'typ', p.typ,
               'reaktionen', z.reaktionen, 'kommentare', z.kommentare, 'firmenseite', z.firmenseite, 'daniel', z.daniel, 'letzte', z.letzte,
               'kontakt', case when c.contact_id is not null then jsonb_build_object(
                            'contact_id', c.contact_id, 'name', nullif(concat_ws(' ', c.vorname, c.nachname), ''), 'email', c.email,
                            'stufe', c.lifecycle_stage) end,
               'vorschlag', case when c.contact_id is null and not p.ignoriert and p.typ = 'person' and kn.n = 1 then jsonb_build_object(
                            'contact_id', kv.contact_id, 'name', concat_ws(' ', kv.vorname, kv.nachname), 'email', kv.email) end)
             order by z.reaktionen + 2 * z.kommentare desc, z.letzte desc), '[]'::jsonb)
        from core.linkedin_personen p
        join zaehl z on z.person_id = p.person_id
        left join core.contacts c on c.contact_id = p.contact_id
        left join kontaktnamen kn on kn.k = regexp_replace(p.schluessel, ',.*$', '')
        left join core.contacts kv on kv.contact_id = kn.contact_id)
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_linkedin_erfassen(jsonb, text)', 'public.dashboard_ausschluss()',
                           'public.dashboard_ausschluss_setzen(text, text, uuid, text, text)',
                           'public.dashboard_linkedin_person(uuid, text, uuid)', 'public.dashboard_linkedin()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- =====================================================================
-- Newsletter: Zählpixel für alle Empfänger (Entscheidung Noah, 18.11.2026),
-- solange „Öffnungen messen“ im Newsletter an ist – auch Bestandskunden.
-- =====================================================================
create or replace function public.newsletter_versand_holen(p_max integer)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  update core.newsletter_empfaenger e set status = 'uebersprungen', fehler = 'gesperrt'
   where e.status = 'wartet' and core.newsletter_gesperrt(e.email);

  with zug as (
    select e.empfaenger_id
      from core.newsletter_empfaenger e
      join core.newsletter n on n.newsletter_id = e.newsletter_id
     where (e.status = 'wartet' or (e.status = 'in_arbeit' and e.gesperrt_bis < now()))
       and e.versuche < 3
       and (e.test or n.status = 'wird_gesendet')
     order by e.test desc, e.created_at
     limit greatest(least(p_max, 200), 1)
     for update of e skip locked
  ), upd as (
    update core.newsletter_empfaenger e
       set status = 'in_arbeit', gesperrt_bis = now() + interval '5 minutes', versuche = e.versuche + 1,
           pixel = (select n.oeffnungen_messen from core.newsletter n where n.newsletter_id = e.newsletter_id)
      from zug where e.empfaenger_id = zug.empfaenger_id
    returning e.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'empfaenger_id', u.empfaenger_id, 'token', u.token, 'email', u.email, 'test', u.test, 'pixel', u.pixel,
           'kontakt', jsonb_build_object('titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname,
                                         'firma', co.name, 'position', c.position),
           'newsletter', jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff, 'vorschautext', n.vorschautext,
                                            'inhalt', n.inhalt, 'klicks_messen', n.klicks_messen, 'utm', n.utm,
                                            'utm_kampagne', coalesce(nullif(trim(n.utm_kampagne), ''), n.titel)))), '[]'::jsonb)
    into v
    from upd u
    join core.newsletter n on n.newsletter_id = u.newsletter_id
    left join core.contacts c on c.contact_id = u.contact_id
    left join core.companies co on co.company_id = c.company_id;
  return v;
end $$;
revoke all on function public.newsletter_versand_holen(integer) from public, anon, authenticated;
grant execute on function public.newsletter_versand_holen(integer) to service_role;
