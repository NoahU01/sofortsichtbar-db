-- =====================================================================
-- Firmen als eigene Einheit
--
-- Regel (Noah, 19.11.2026): Wo wir nur eine Firma kennen, gibt es keinen
-- Kontakt. Firmen-Konten (z. B. Instagram-Konto eines Versicherungsbüros)
-- hängen direkt an der Firma – mit Follower-Status (companies.tags) und
-- eigenen Signalen (core.events.company_id).
--
-- Firmengruppe: die großen Player (SV SparkassenVersicherung, LVM, Allianz …)
-- als erste Ebene, die Büros darunter. Erkannt am Namen (und am Instagram-
-- Namen), von Hand änderbar (gruppe_manuell). Ohne Gruppe = „Sonstige“
-- (freie Makler, Berater, andere Branchen).
-- =====================================================================

alter table core.companies
  add column gruppe         text,
  add column gruppe_manuell boolean not null default false,
  add column telefon        text,
  add column notizen        text,
  add column herkunft       text,
  add column tags           text[] not null default '{}';

alter table core.events add column company_id uuid references core.companies on delete cascade;
create index events_company_time_idx on core.events (company_id, occurred_at desc) where company_id is not null;

alter table core.instagram_personen add column company_id uuid references core.companies on delete set null;

-- ---------------------------------------------------------------------
-- Gruppe erkennen
-- ---------------------------------------------------------------------
create or replace function core.firmengruppe_erkennen(p_name text, p_hinweis text default null)
returns text language sql immutable set search_path = '' as $$
  select case
    when x ~* '(sparkassenversicherung|(^|[^a-z])sv([^a-z]|$)|sv-team|svteam)' then 'SV SparkassenVersicherung'
    when x ~* '(^|[^a-z])lvm' then 'LVM'
    when x ~* 'allianz' then 'Allianz'
    when x ~* '(^|[^a-z])axa' then 'AXA'
    when x ~* 'zurich' then 'Zurich'
    when x ~* '((^|[^a-z])vkb([^a-z]|$)|versicherungskammer)' then 'Versicherungskammer Bayern'
    when x ~* '(^|[^a-z])lbs([^a-z]|$)' then 'LBS'
    when x ~* '(^|[^a-z])ergo([^a-z]|$)' then 'ERGO'
    when x ~* '(^|[^a-z])huk' then 'HUK-Coburg'
    when x ~* '(r\+v|(^|[^a-z])ruv([^a-z]|$))' then 'R+V'
    when x ~* 'signal.?iduna' then 'Signal Iduna'
    when x ~* 'generali' then 'Generali'
    when x ~* 'debeka' then 'Debeka'
    when x ~* 'provinzial' then 'Provinzial'
    when x ~* 'gothaer' then 'Gothaer'
    when x ~* 'devk' then 'DEVK'
    when x ~* '(württembergische|wuerttembergische|wüstenrot|wuestenrot)' then 'W&W'
    when x ~* 'continentale' then 'Continentale'
    when x ~* 'barmenia' then 'Barmenia'
    when x ~* 'nürnberger|nuernberger' then 'Nürnberger'
    else null end
    from (select lower(coalesce(p_name, '') || ' ' || coalesce(p_hinweis, '')) as x) s
$$;

create or replace function core.companies_gruppe()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not new.gruppe_manuell then new.gruppe := core.firmengruppe_erkennen(new.name, null); end if;
  return new;
end $$;
create trigger companies_gruppe before insert or update of name, gruppe_manuell on core.companies
  for each row execute function core.companies_gruppe();

-- ---------------------------------------------------------------------
-- Bestand umziehen: Kontakte, die nur aus einer Firma bestehen, werden zur Firma
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select c.* from core.contacts c
            where c.vorname is null and c.nachname is null and c.email is null and c.telefon is null and c.company_id is not null
  loop
    update core.companies set tags = (select coalesce(array_agg(distinct t), '{}') from unnest(tags || r.tags) t),
                              herkunft = coalesce(herkunft, r.herkunft)
     where company_id = r.company_id;
    update core.instagram_personen set company_id = r.company_id, contact_id = null where contact_id = r.contact_id;
    update core.events set company_id = r.company_id, contact_id = null where contact_id = r.contact_id;
    delete from core.contacts where contact_id = r.contact_id;
  end loop;
end $$;

update core.companies co set gruppe = core.firmengruppe_erkennen(co.name,
         (select string_agg(p.benutzername, ' ') from core.instagram_personen p where p.company_id = co.company_id))
 where not co.gruppe_manuell;

-- ---------------------------------------------------------------------
-- Instagram: Personen können einer Firma statt einem Kontakt gehören
-- ---------------------------------------------------------------------
create or replace function core.instagram_events(p_person_id uuid default null, p_post_id text default null)
returns integer
language plpgsql set search_path = ''
as $$
declare n integer; m integer;
begin
  insert into core.events (event_id, event_name, occurred_at, contact_id, company_id, source, properties, consent_state)
  select 'ig:' || l.post_id || ':' || l.person_id, 'instagram_like', l.erfasst_am, p.contact_id, case when p.contact_id is null then p.company_id end, 'instagram',
         jsonb_strip_nulls(jsonb_build_object('post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet::date,
           'beitrag', nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''),
           'person_id', p.person_id, 'benutzername', p.benutzername)), 'not_required'
    from core.instagram_likes l
    join core.instagram_personen p on p.person_id = l.person_id
    join analytics.buffer_beitraege b on b.post_id = l.post_id
   where (p.contact_id is not null or p.company_id is not null) and not p.ignoriert
     and (p_person_id is null or l.person_id = p_person_id) and (p_post_id is null or l.post_id = p_post_id)
  on conflict (event_id) do update set contact_id = excluded.contact_id, company_id = excluded.company_id, properties = excluded.properties;
  get diagnostics n = row_count;

  insert into core.events (event_id, event_name, occurred_at, contact_id, company_id, source, properties, consent_state)
  select 'igk:' || k.post_id || ':' || k.person_id || ':' || k.nr, 'instagram_comment', k.erfasst_am, p.contact_id, case when p.contact_id is null then p.company_id end, 'instagram',
         jsonb_strip_nulls(jsonb_build_object('text', left(k.text, 1000), 'post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet::date,
           'beitrag', nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''),
           'person_id', p.person_id, 'benutzername', p.benutzername)), 'not_required'
    from core.instagram_kommentare k
    join core.instagram_personen p on p.person_id = k.person_id
    join analytics.buffer_beitraege b on b.post_id = k.post_id
   where (p.contact_id is not null or p.company_id is not null) and not p.ignoriert
     and (p_person_id is null or k.person_id = p_person_id) and (p_post_id is null or k.post_id = p_post_id)
  on conflict (event_id) do update set contact_id = excluded.contact_id, company_id = excluded.company_id, properties = excluded.properties;
  get diagnostics m = row_count;
  return n + m;
end $$;

create or replace function core.instagram_follow_nachziehen(p_person_id uuid)
returns void language plpgsql set search_path = '' as $$
declare v_p core.instagram_personen;
begin
  select * into v_p from core.instagram_personen where person_id = p_person_id;
  if v_p.follower_seit is null or v_p.ignoriert or (v_p.contact_id is null and v_p.company_id is null) then return; end if;
  if v_p.contact_id is not null then
    update core.contacts set tags = (select array_agg(distinct t) from unnest(tags || array['instagram_follower']) t)
     where contact_id = v_p.contact_id and not ('instagram_follower' = any(tags));
  else
    update core.companies set tags = (select array_agg(distinct t) from unnest(tags || array['instagram_follower']) t)
     where company_id = v_p.company_id and not ('instagram_follower' = any(tags));
  end if;
  insert into core.events (event_id, event_name, occurred_at, contact_id, company_id, source, properties, consent_state)
  values ('igfollow:' || v_p.person_id, 'instagram_follow', v_p.follower_seit::timestamptz, v_p.contact_id,
          case when v_p.contact_id is null then v_p.company_id end, 'instagram',
          jsonb_build_object('person_id', v_p.person_id, 'benutzername', v_p.benutzername, 'datum_unbekannt', true), 'not_required')
  on conflict (event_id) do update set contact_id = excluded.contact_id, company_id = excluded.company_id;
end $$;

create or replace function core.instagram_firma_zuordnen(p_person_id uuid, p_company_id uuid)
returns void language plpgsql set search_path = '' as $$
begin
  update core.instagram_personen set company_id = p_company_id, contact_id = null, ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  delete from core.events where source = 'instagram' and properties->>'person_id' = p_person_id::text
                            and (contact_id is not null or company_id is distinct from p_company_id);
  perform core.instagram_events(p_person_id => p_person_id);
  perform core.instagram_follow_nachziehen(p_person_id);
end $$;

create or replace function core.instagram_zuordnen(p_person_id uuid, p_contact_id uuid)
returns void
language plpgsql set search_path = ''
as $$
declare v_p core.instagram_personen;
begin
  select * into v_p from core.instagram_personen where person_id = p_person_id;
  update core.instagram_personen set contact_id = p_contact_id, company_id = null, ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  delete from core.events where source = 'instagram' and properties->>'person_id' = p_person_id::text
                            and (company_id is not null or contact_id is distinct from p_contact_id);
  insert into core.identities (contact_id, identity_type, identity_value, source)
  values (p_contact_id, 'instagram_username', v_p.benutzername, 'instagram')
  on conflict (identity_type, identity_value) do nothing;
  perform core.instagram_events(p_person_id => p_person_id);
  perform core.instagram_follow_nachziehen(p_person_id);
end $$;

-- Follower-Import: Firmen-Konten werden Firmen (ohne Kontakt)
create or replace function public.dashboard_instagram_follower(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f jsonb; v_u text; v_name text; v_p core.instagram_personen; v_c uuid; v_n integer; v_firma uuid; z record;
  n_ges integer := 0; n_neu integer := 0; n_zu integer := 0; n_aus integer := 0; n_offen integer := 0; n_firmen integer := 0;
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
    if v_p.contact_id is not null or v_p.company_id is not null then
      perform core.instagram_follow_nachziehen(v_p.person_id); n_zu := n_zu + 1; continue;
    end if;

    v_c := nullif(p #>> array['zuordnung', v_u], '')::uuid;
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

    if v_c is null and core.ig_ist_firma(v_name, v_u) then
      select co.company_id into v_firma from core.companies co where lower(co.name) = lower(coalesce(v_name, v_u)) limit 1;
      if v_firma is null then
        insert into core.companies (name, herkunft) values (coalesce(v_name, v_u), 'instagram') returning company_id into v_firma;
        update core.companies set gruppe = core.firmengruppe_erkennen(name, v_u) where company_id = v_firma and gruppe is null and not gruppe_manuell;
      end if;
      perform core.instagram_firma_zuordnen(v_p.person_id, v_firma);
      n_firmen := n_firmen + 1;
      continue;
    end if;
    if v_c is null then
      select * into z from core.name_zerlegen(coalesce(core.linkedin_name_sauber(v_name), v_u));
      insert into core.contacts (titel, vorname, nachname, herkunft) values (z.titel, coalesce(z.vorname, v_u), z.nachname, 'instagram')
      returning contact_id into v_c;
      n_neu := n_neu + 1;
    else
      n_zu := n_zu + 1;
    end if;
    perform core.instagram_zuordnen(v_p.person_id, v_c);
  end loop;
  return jsonb_build_object('gesamt', n_ges, 'neu', n_neu, 'firmen', n_firmen, 'zugeordnet', n_zu, 'ausgeschlossen', n_aus, 'offen', n_offen);
end $$;

-- Instagram-Personen: lösen/ausschließen nimmt auch die Firma weg; neue Aktion firma_anlegen
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
      insert into core.contacts (titel, vorname, nachname, herkunft) values (z.titel, z.vorname, z.nachname, 'instagram') returning contact_id into v_c;
    end if;
    perform core.instagram_zuordnen(p_person_id, v_c);
    return jsonb_build_object('person_id', p_person_id, 'contact_id', v_c);
  elsif p_aktion = 'firma_anlegen' then
    select co.company_id into v_c from core.companies co where lower(co.name) = lower(coalesce(v_p.name, v_p.benutzername)) limit 1;
    if v_c is null then
      insert into core.companies (name, herkunft) values (coalesce(v_p.name, v_p.benutzername), 'instagram') returning company_id into v_c;
      update core.companies set gruppe = core.firmengruppe_erkennen(name, v_p.benutzername) where company_id = v_c and gruppe is null and not gruppe_manuell;
    end if;
    perform core.instagram_firma_zuordnen(p_person_id, v_c);
    return jsonb_build_object('person_id', p_person_id, 'company_id', v_c);
  elsif p_aktion in ('loesen', 'ignorieren') then
    delete from core.events where source = 'instagram' and properties->>'person_id' = p_person_id::text;
    update core.instagram_personen set contact_id = null, company_id = null, ignoriert = (p_aktion = 'ignorieren') where person_id = p_person_id;
  elsif p_aktion = 'zurueckholen' then
    update core.instagram_personen set ignoriert = false, ausschluss_grund = null where person_id = p_person_id;
  else
    raise exception 'Unbekannte Aktion %', p_aktion;
  end if;
  return jsonb_build_object('person_id', p_person_id);
end $$;

-- ---------------------------------------------------------------------
-- Firmen-Liste (Cockpit, gruppiert im Browser)
-- Firma passt, wenn ein Kontakt passt – oder die Firma selbst
-- (Name, Follower, Herkunft, Signale der Firma), sofern kein reiner
-- Personenfilter (Position, Newsletter, Name unvollständig) gesetzt ist.
-- ---------------------------------------------------------------------
create or replace function public.dashboard_firmen_liste(p jsonb)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with f as (
    select nullif(trim(coalesce(p->>'firma', p->>'name')), '') as name, nullif(trim(p->>'suche'), '') as suche,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'herkunft') x), '{}') as herkunft,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'follower') x), '{}') as follower,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'signale') x), '{}') as sig,
           nullif(p->>'signal_tage', '')::integer as tage,
           (nullif(trim(p->>'position'), '') is not null or coalesce((p->>'position_leer')::boolean, false)
             or coalesce((p->>'name_unvollstaendig')::boolean, false) or nullif(p->>'newsletter', '') is not null
             or nullif(p->>'liste', '') is not null) as nur_personen
  ), kp as (
    select c.company_id, count(*) as treffer
      from core.contacts c
     where c.company_id is not null
       and c.contact_id in (select core.kontakte_gefiltert((p - 'name' - 'firma' - 'suche')))
     group by c.company_id
  ), passend as (
    select co.company_id, coalesce(kp.treffer, 0) as treffer
      from core.companies co cross join f
      left join kp on kp.company_id = co.company_id
     where (f.name is null or co.name ilike '%' || f.name || '%')
       and (f.suche is null or concat_ws(' ', co.name, co.domain, co.ort) ilike '%' || f.suche || '%'
            or exists (select 1 from core.contacts c where c.company_id = co.company_id
                         and concat_ws(' ', c.vorname, c.nachname, c.email, c.position) ilike '%' || f.suche || '%'))
       and (kp.company_id is not null
            or (not f.nur_personen
                and (cardinality(f.follower) = 0 or co.tags && (select array_agg(x || '_follower') from unnest(f.follower) x))
                and (cardinality(f.herkunft) = 0 or co.herkunft = any (f.herkunft))
                and (cardinality(f.sig) = 0 or exists (
                       select 1 from core.events e where e.company_id = co.company_id
                          and (f.tage is null or e.occurred_at >= now() - make_interval(days => f.tage))
                          and (('ig_like' = any (f.sig) and e.event_name = 'instagram_like') or ('ig_kommentar' = any (f.sig) and e.event_name = 'instagram_comment')
                               or ('li_reaktion' = any (f.sig) and e.event_name = 'linkedin_reaction') or ('li_kommentar' = any (f.sig) and e.event_name = 'linkedin_comment'))))))
  )
  select coalesce(jsonb_agg(z order by z->>'gruppe' nulls last, z->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
             'company_id', co.company_id, 'name', co.name, 'domain', co.domain, 'telefon', co.telefon, 'ort', co.ort,
             'gruppe', co.gruppe, 'herkunft', co.herkunft,
             'kontakte', (select count(*) from core.contacts c where c.company_id = co.company_id),
             'treffer', pa.treffer,
             'follower', (select array_agg(distinct replace(x, '_follower', '')) from (
                            select unnest(co.tags) x union all select unnest(c.tags) from core.contacts c where c.company_id = co.company_id) t
                           where x like '%\_follower'),
             'letzte_aktivitaet', greatest(
               (select max(e.occurred_at) from core.events e where e.company_id = co.company_id),
               (select max(e.occurred_at) from core.events e join core.contacts c on c.contact_id = e.contact_id where c.company_id = co.company_id))) as z
      from passend pa join core.companies co on co.company_id = pa.company_id
     limit 2000) x
$$;

-- Firma öffnen
create or replace function public.dashboard_firma(p_company_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'firma', to_jsonb(co),
    'follower', (select coalesce(jsonb_agg(distinct replace(x, '_follower', '')), '[]'::jsonb) from (
                   select unnest(co.tags) x union all select unnest(c.tags) from core.contacts c where c.company_id = co.company_id) t
                  where x like '%\_follower'),
    'konten', (select coalesce(jsonb_agg(jsonb_build_object('kanal', 'instagram', 'name', '@' || p.benutzername, 'anzeigename', p.name,
                                                            'url', 'https://www.instagram.com/' || p.benutzername || '/')), '[]'::jsonb)
                 from core.instagram_personen p where p.company_id = co.company_id),
    'kontakte', (select coalesce(jsonb_agg(jsonb_build_object('contact_id', c.contact_id, 'titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname,
                                  'email', c.email, 'telefon', c.telefon, 'position', c.position, 'lifecycle_stage', c.lifecycle_stage, 'tags', c.tags)
                                  order by c.nachname, c.vorname), '[]'::jsonb)
                   from core.contacts c where c.company_id = co.company_id),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                          'event_name', e.event_name, 'zeit', e.occurred_at, 'quelle', e.source, 'sitzung', e.session_id, 'seitentyp', e.page_type,
                          'pfad', coalesce(nullif(regexp_replace(split_part(e.page_url, '?', 1), '^https?://[^/]+', ''), ''), case when e.page_url is not null then '/' end),
                          'props', e.properties, 'kontakt', nullif(concat_ws(' ', c.vorname, c.nachname), '')) order by e.occurred_at desc), '[]'::jsonb)
                   from (select * from core.events ev
                          where ev.company_id = co.company_id
                             or ev.contact_id in (select c2.contact_id from core.contacts c2 where c2.company_id = co.company_id)
                          order by ev.occurred_at desc limit 500) e
                   left join core.contacts c on c.contact_id = e.contact_id),
    'gruppen', (select coalesce(jsonb_agg(distinct g), '[]'::jsonb) from (
                  select gruppe g from core.companies where gruppe is not null
                  union select unnest(array['SV SparkassenVersicherung', 'LVM', 'Allianz', 'AXA', 'Zurich', 'Versicherungskammer Bayern', 'LBS', 'ERGO',
                                            'HUK-Coburg', 'R+V', 'Signal Iduna', 'Generali', 'Debeka', 'Provinzial', 'Gothaer', 'DEVK', 'W&W'])) x)
  )
    from core.companies co where co.company_id = p_company_id
$$;

create or replace function public.dashboard_firma_speichern(p jsonb, p_von text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := nullif(p->>'company_id', '')::uuid; v_gruppe text := nullif(trim(p->>'gruppe'), '');
begin
  update core.companies
     set name = coalesce(nullif(trim(p->>'name'), ''), name),
         domain = nullif(lower(regexp_replace(regexp_replace(trim(coalesce(p->>'domain', '')), '^https?://(www\.)?', '', 'i'), '/.*$', '')), ''),
         telefon = nullif(trim(p->>'telefon'), ''), ort = nullif(trim(p->>'ort'), ''), notizen = nullif(trim(p->>'notizen'), ''),
         gruppe_manuell = true,
         gruppe = case when v_gruppe = 'Sonstige' then null else v_gruppe end,
         updated_at = now()
   where company_id = v_id;
  if not found then raise exception 'Firma nicht gefunden'; end if;
  return v_id;
end $$;

-- Firma löschen: Kontakte bleiben (ohne Firma), Firmen-Signale gehen mit
create or replace function public.dashboard_firma_loeschen(p_company_id uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  select count(*) into n from core.contacts where company_id = p_company_id;
  delete from core.events where company_id = p_company_id;
  update core.instagram_personen set company_id = null where company_id = p_company_id;
  delete from core.companies where company_id = p_company_id;
  return n;
end $$;

-- Mehrere Kontakte löschen
create or replace function public.dashboard_kontakte_loeschen(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v uuid; n integer := 0;
begin
  foreach v in array coalesce(p_ids, '{}') loop
    perform public.dashboard_kontakt_loeschen(v);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Facetten: Firmen zählen alle Firmen
create or replace function public.dashboard_kontakte_facetten()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'herkunft', (select coalesce(jsonb_object_agg(h, n), '{}'::jsonb) from (
                   select case when herkunft like 'linkedin%' then 'linkedin' else coalesce(herkunft, 'unbekannt') end as h, count(*) as n
                     from core.contacts group by 1) x),
    'follower', (select coalesce(jsonb_object_agg(replace(t, '_follower', ''), n), '{}'::jsonb) from (
                   select t, count(*) as n from core.contacts, unnest(tags) t where t like '%\_follower' group by t) x),
    'newsletter', (select jsonb_build_object('ja', count(*) filter (where newsletter_erlaubt), 'nein', count(*) filter (where not newsletter_erlaubt)) from core.contacts),
    'gesamt', (select count(*) from core.contacts),
    'firmen', (select count(*) from core.companies)
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_instagram_follower(jsonb, text)', 'public.dashboard_instagram_person(uuid, text, uuid)',
                           'public.dashboard_firmen_liste(jsonb)', 'public.dashboard_firma(uuid)', 'public.dashboard_firma_speichern(jsonb, text)',
                           'public.dashboard_firma_loeschen(uuid)', 'public.dashboard_kontakte_loeschen(uuid[])', 'public.dashboard_kontakte_facetten()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
