-- =====================================================================
-- Instagram-Follower → Kontakte (Tag instagram_follower)
--
-- dashboard_instagram_follower(p): Liste [{benutzername, name}] (aus der
-- Follower-Liste kopiert). Je Follower:
--   ausgeschlossen        → nur erfasst, nie zugeordnet
--   Kennung bekannt / genau ein Kontakt gleichen Namens → zuordnen
--   p.zuordnung {benutzername: contact_id} → von Hand bestimmte Zuordnung
--   p.offen [benutzername] → bewusst offen lassen (Rückfrage)
--   sonst neuer Kontakt: Unternehmenskonto (Versicherungsbüro, GmbH, SV-Team …)
--   → Firma mit dem Anzeigenamen; Person → Vor-/Nachname; sonst Anzeige- bzw.
--   Benutzername als Vorname. Herkunft instagram, Newsletter: Nein.
-- Alle zugeordneten bekommen den Tag instagram_follower und ein
-- instagram_follow im Verlauf.
-- Likes werden erst ab heute (18.11.2026) nachgehalten – ältere Beiträge
-- melden keine fehlenden Likes mehr.
-- =====================================================================

insert into core.event_types (event_name, quelle, beschreibung) values
  ('instagram_follow', 'instagram', 'Folgt sofort sichtbar auf Instagram (Zeitpunkt = wann die Follower-Liste erfasst wurde)')
on conflict (event_name) do nothing;

alter table core.instagram_personen add column follower_seit date;

-- Unternehmenskonto? (Anzeigename oder Benutzername)
create or replace function core.ig_ist_firma(p_name text, p_benutzer text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_name, '') ~* '(versicher|makler|agentur|b(ü|ue)ro|gmbh|\mkg\M|e\.k\.|\mteam\M|^sv\M|\msv[- ]|\mlvm\M|\maxa|zurich|finanz|lounge|immobilien|direktion|gesch(ä|ae)ftsstelle|steuerberat|rechtsanw|partg|gravur|werbeartikel|direkt|consult|navigator|surance|\mlbs\M|®|&)'
      or (coalesce(p_name, '') = '' and coalesce(p_benutzer, '') ~* '(versicher|makler|agentur|gmbh|zurich|lvm|^sv)')
$$;

create or replace function public.dashboard_instagram_follower(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f jsonb; v_u text; v_name text; v_p core.instagram_personen; v_c uuid; v_n integer; v_firma uuid; z record;
  n_ges integer := 0; n_neu integer := 0; n_zu integer := 0; n_aus integer := 0; n_offen integer := 0;
begin
  for f in select * from jsonb_array_elements(coalesce(p->'follower', '[]'::jsonb)) loop
    v_u := lower(trim(both '@ ' from coalesce(f->>'benutzername', '')));
    if v_u !~ '^[a-z0-9._]{1,30}$' then continue; end if;
    v_name := left(nullif(trim(f->>'name'), ''), 200);
    n_ges := n_ges + 1;
    insert into core.instagram_personen (benutzername, name, follower_seit) values (v_u, v_name, current_date)
    on conflict (benutzername) do update set name = coalesce(excluded.name, core.instagram_personen.name),
                                             follower_seit = coalesce(core.instagram_personen.follower_seit, current_date), zuletzt = now()
    returning * into v_p;
    if v_p.ignoriert then n_aus := n_aus + 1; continue; end if;

    v_c := v_p.contact_id;
    if v_c is null then v_c := nullif(p #>> array['zuordnung', v_u], '')::uuid; end if;
    if v_c is null then
      select i.contact_id into v_c from core.identities i where i.identity_type = 'instagram_username' and i.identity_value = v_u;
    end if;
    if v_c is null and v_name is not null and not core.ig_ist_firma(v_name, v_u) then
      select * into z from core.name_zerlegen(core.linkedin_name_sauber(v_name));
      if z.nachname is not null then
        select count(*), min(c.contact_id::text)::uuid into v_n, v_c
          from core.contacts c where lower(concat_ws(' ', c.vorname, c.nachname)) = lower(concat_ws(' ', z.vorname, z.nachname));
        if v_n <> 1 then v_c := null; end if;
      end if;
    end if;
    if v_c is null and coalesce(p->'offen', '[]'::jsonb) ? v_u then n_offen := n_offen + 1; continue; end if;

    if v_c is null then
      if core.ig_ist_firma(v_name, v_u) then
        select co.company_id into v_firma from core.companies co where lower(co.name) = lower(coalesce(v_name, v_u)) limit 1;
        if v_firma is null then
          insert into core.companies (name) values (coalesce(v_name, v_u)) returning company_id into v_firma;
        end if;
        insert into core.contacts (company_id, herkunft) values (v_firma, 'instagram') returning contact_id into v_c;
      else
        select * into z from core.name_zerlegen(coalesce(core.linkedin_name_sauber(v_name), v_u));
        insert into core.contacts (titel, vorname, nachname, herkunft) values (z.titel, coalesce(z.vorname, v_u), z.nachname, 'instagram')
        returning contact_id into v_c;
      end if;
      n_neu := n_neu + 1;
    else
      n_zu := n_zu + 1;
    end if;

    if v_p.contact_id is distinct from v_c then perform core.instagram_zuordnen(v_p.person_id, v_c); end if;
    update core.contacts set tags = (select array_agg(distinct t) from unnest(tags || array['instagram_follower']) t)
     where contact_id = v_c and not ('instagram_follower' = any(tags));
    insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
    values ('igfollow:' || v_p.person_id, 'instagram_follow', coalesce(v_p.follower_seit, current_date)::timestamptz, v_c, 'instagram',
            jsonb_build_object('person_id', v_p.person_id, 'benutzername', v_u, 'datum_unbekannt', true), 'not_required')
    on conflict (event_id) do update set contact_id = excluded.contact_id;
  end loop;
  return jsonb_build_object('gesamt', n_ges, 'neu', n_neu, 'zugeordnet', n_zu, 'ausgeschlossen', n_aus, 'offen', n_offen);
end $$;

-- Ausschließen / Kontakt anlegen / Zuordnen: Follower-Tag und Follow-Signal mitnehmen
create or replace function core.instagram_follow_nachziehen(p_person_id uuid)
returns void language plpgsql set search_path = '' as $$
declare v_p core.instagram_personen;
begin
  select * into v_p from core.instagram_personen where person_id = p_person_id;
  if v_p.follower_seit is null or v_p.contact_id is null or v_p.ignoriert then return; end if;
  update core.contacts set tags = (select array_agg(distinct t) from unnest(tags || array['instagram_follower']) t)
   where contact_id = v_p.contact_id and not ('instagram_follower' = any(tags));
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  values ('igfollow:' || v_p.person_id, 'instagram_follow', v_p.follower_seit::timestamptz, v_p.contact_id, 'instagram',
          jsonb_build_object('person_id', v_p.person_id, 'benutzername', v_p.benutzername, 'datum_unbekannt', true), 'not_required')
  on conflict (event_id) do update set contact_id = excluded.contact_id;
end $$;

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
  perform core.instagram_follow_nachziehen(p_person_id);
end $$;

-- Ausschlussliste Instagram (für den Import und später Einstellungen)
create or replace function public.dashboard_instagram_ausschluss_setzen(p_benutzername text, p_grund text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_u text := lower(trim(both '@ ' from coalesce(p_benutzername, '')));
begin
  if v_u !~ '^[a-z0-9._]{1,30}$' then raise exception 'Ungültiger Instagram-Name'; end if;
  insert into core.instagram_personen (benutzername, ignoriert, ausschluss_grund) values (v_u, true, nullif(trim(p_grund), ''))
  on conflict (benutzername) do update set ignoriert = true, contact_id = null,
     ausschluss_grund = coalesce(excluded.ausschluss_grund, core.instagram_personen.ausschluss_grund)
  returning person_id into v_id;
  delete from core.events where source = 'instagram' and properties->>'person_id' = v_id::text;
  return v_id;
end $$;

-- Übersicht: fehlende Likes nur noch für Beiträge ab dem 18.11.2026 (oder schon erfasste)
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
            union all select person_id, 'k', erfasst_am from core.instagram_kommentare
            union all select person_id, 'f', follower_seit::timestamptz from core.instagram_personen where follower_seit is not null) x
     group by x.person_id
  )
  select jsonb_build_object(
    'beitraege', (select coalesce(jsonb_agg(jsonb_build_object(
        'post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet,
        'titel', coalesce(nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''), 'Beitrag'),
        'likes', b.reaktionen, 'kommentare', b.kommentare, 'impressionen', b.impressionen, 'reichweite', b.reichweite,
        'erfasst', b.erfasst, 'kommentare_erfasst', b.kommentare_erfasst,
        'fehlen', case when b.erfasst > 0 or b.gesendet >= timestamptz '2026-11-18' then greatest(coalesce(b.reaktionen, 0) - b.erfasst, 0) else 0 end,
        'beobachtet', b.erfasst > 0 or b.gesendet >= timestamptz '2026-11-18')
      order by b.gesendet desc), '[]'::jsonb) from b),
    'personen', (select coalesce(jsonb_agg(jsonb_build_object(
        'person_id', p.person_id, 'benutzername', p.benutzername, 'name', p.name, 'ignoriert', p.ignoriert,
        'follower', p.follower_seit is not null, 'likes', z.likes, 'kommentare', z.kommentare, 'letzte', z.letzte,
        'kontakt', case when c.contact_id is not null then jsonb_build_object('contact_id', c.contact_id,
                     'name', coalesce(nullif(concat_ws(' ', c.vorname, c.nachname), ''), co.name), 'email', c.email, 'stufe', c.lifecycle_stage) end)
      order by z.likes + 2 * z.kommentare desc, z.letzte desc), '[]'::jsonb)
      from core.instagram_personen p join z on z.person_id = p.person_id
      left join core.contacts c on c.contact_id = p.contact_id
      left join core.companies co on co.company_id = c.company_id),
    'follower', (select count(*) from core.instagram_personen where follower_seit is not null and not ignoriert),
    'buffer', (select jsonb_build_object('stand', max(kennzahlen_stand), 'abgerufen', max(abgerufen_am))
                 from analytics.buffer_beitraege where service = 'instagram')
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_instagram_follower(jsonb, text)', 'public.dashboard_instagram_ausschluss_setzen(text, text)',
                           'public.dashboard_instagram()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
