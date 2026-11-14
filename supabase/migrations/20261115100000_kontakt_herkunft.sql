-- =====================================================================
-- Kontakte: Herkunft, Tags, Position, Titel, Newsletter-Erlaubnis
-- LinkedIn-Follower der Firmenseite als Kontakte
--
--   herkunft            Erstkontakt: woher kam die Person zuerst
--                       (wird beim Anlegen gesetzt, sonst aus der ersten
--                       Kennung abgeleitet; ändert sich danach nicht von selbst)
--   tags                freie Markierungen, z. B. linkedin_follower
--   newsletter_erlaubt  Standard NEIN. Ja nur mit Grundlage (Einwilligung
--                       oder Bestandskunde); jede Änderung wird zusätzlich in
--                       core.consents protokolliert (Nachweis).
--
-- Follower-Import: Cockpit „Follower einfügen“ → public.dashboard_linkedin_follower.
-- Personendaten kommen NICHT ins Repo (öffentlich), nur über das Cockpit.
-- =====================================================================

alter table core.contacts
  add column herkunft text check (herkunft in ('termin', 'postfach', 'call', 'website', 'linkedin_follower',
                                               'linkedin_reaktion', 'manuell', 'import')),
  add column tags text[] not null default '{}',
  add column titel text,
  add column position text,
  add column newsletter_erlaubt boolean not null default false,
  add column newsletter_grundlage text check (newsletter_grundlage in ('einwilligung', 'bestandskunde')),
  add column newsletter_seit timestamptz,
  add constraint contacts_newsletter_grundlage check (not newsletter_erlaubt or newsletter_grundlage is not null);
create index contacts_tags_idx on core.contacts using gin (tags);
create index contacts_herkunft_idx on core.contacts (herkunft);

alter table core.linkedin_personen
  add column profil_url text,
  add column follower_seit date;
create unique index linkedin_personen_url_key on core.linkedin_personen (profil_url) where profil_url is not null;

insert into core.event_types (event_name, quelle, beschreibung) values
  ('linkedin_follow', 'linkedin', 'Folgt der Firmenseite sofort sichtbar (Monat laut Follower-Liste)');

-- ---------------------------------------------------------------------
-- Herkunft aus der ersten Kennung, wenn beim Anlegen keine gesetzt wurde
-- ---------------------------------------------------------------------
create or replace function core.herkunft_aus_quelle(p_quelle text)
returns text language sql immutable set search_path = '' as $$
  select case p_quelle when 'cal' then 'termin' when 'postfach' then 'postfach' when 'dashboard' then 'call'
                       when 'formular' then 'website' when 'linkedin_follower' then 'linkedin_follower' end
$$;

create or replace function core.identities_herkunft()
returns trigger language plpgsql set search_path = '' as $$
begin
  update core.contacts set herkunft = core.herkunft_aus_quelle(new.source)
   where contact_id = new.contact_id and herkunft is null and core.herkunft_aus_quelle(new.source) is not null;
  return null;
end $$;
create trigger identities_herkunft
  after insert on core.identities
  for each row execute function core.identities_herkunft();

-- Bestehende Kontakte nachtragen
update core.contacts c
   set herkunft = (select core.herkunft_aus_quelle(i.source) from core.identities i
                    where i.contact_id = c.contact_id and core.herkunft_aus_quelle(i.source) is not null
                    order by i.first_seen limit 1)
 where c.herkunft is null;

-- ---------------------------------------------------------------------
-- Name zerlegen: „Dr. Anne-Kathrin Krone“ → Titel Dr., Vorname Anne-Kathrin,
-- Nachname Krone; „Holger Diefenbach, LL.M., CGA“ → Zusätze hinter dem Komma
-- fallen weg (stehen weiter im LinkedIn-Namen).
-- ---------------------------------------------------------------------
create or replace function core.name_zerlegen(p_name text, out titel text, out vorname text, out nachname text)
language plpgsql immutable set search_path = '' as $$
declare
  v text := trim(regexp_replace(regexp_replace(coalesce(p_name, ''), ',.*$', ''), '\s+', ' ', 'g'));
  m text[];
begin
  m := regexp_match(v, '^((?:(?:Prof|Dr|Dipl\.-[A-Za-zäöü]+)\.?(?: (?:med|rer\. nat|h\.c|jur|phil|oec)\.)?\s+)+)(.*)$');
  if m is not null then titel := trim(m[1]); v := trim(m[2]); end if;
  vorname := nullif(split_part(v, ' ', 1), '');
  nachname := nullif(trim(substr(v, length(split_part(v, ' ', 1)) + 1)), '');
end $$;

-- ---------------------------------------------------------------------
-- Cockpit: Follower einfügen.
-- p: { follower: [{name, unternehmen?, position?, profil_url?, folgt_seit? (YYYY-MM-DD)}] }
-- Bekannte Personen (gleiche Profil-URL oder gleicher Name) werden ergänzt,
-- nicht doppelt angelegt. Bestehende Kontakte behalten ihre Herkunft und
-- bekommen den Tag linkedin_follower.
-- ---------------------------------------------------------------------
create or replace function public.dashboard_linkedin_follower(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f jsonb;
  v_name text; v_schl text; v_url text; v_pos text; v_firma text; v_seit date;
  v_person core.linkedin_personen;
  v_contact uuid; v_company uuid; z record;
  n_gesamt integer := 0; n_neu integer := 0; n_verknuepft integer := 0; n_team integer := 0; n_urls integer := 0;
begin
  for f in select * from jsonb_array_elements(coalesce(p->'follower', '[]'::jsonb)) loop
    v_name := left(trim(regexp_replace(coalesce(f->>'name', ''), '\s+', ' ', 'g')), 200);
    continue when v_name = '';
    n_gesamt := n_gesamt + 1;
    v_schl  := core.linkedin_schluessel(v_name);
    v_url   := nullif(lower(regexp_replace(regexp_replace(trim(coalesce(f->>'profil_url', '')), '[?#].*$', ''), '/+$', '')), '');
    if v_url is not null and v_url !~ '^https://([a-z]+\.)?linkedin\.com/in/' then v_url := null; end if;
    v_pos   := left(nullif(trim(f->>'position'), ''), 300);
    v_firma := left(nullif(trim(f->>'unternehmen'), ''), 200);
    v_seit  := case when f->>'folgt_seit' ~ '^\d{4}-\d{2}-\d{2}$' then (f->>'folgt_seit')::date end;

    -- LinkedIn-Person: zuerst über die Profil-URL, sonst über den Namen
    select * into v_person from core.linkedin_personen where v_url is not null and profil_url = v_url;
    if not found then select * into v_person from core.linkedin_personen where schluessel = v_schl; end if;
    if found then
      update core.linkedin_personen
         set position = coalesce(v_pos, position),
             profil_url = coalesce(profil_url, v_url),
             follower_seit = least(coalesce(follower_seit, v_seit), coalesce(v_seit, follower_seit)),
             zuletzt = now()
       where person_id = v_person.person_id
      returning * into v_person;
    else
      insert into core.linkedin_personen (schluessel, name, position, profil_url, follower_seit)
      values (v_schl, v_name, v_pos, v_url, v_seit)
      returning * into v_person;
    end if;
    if v_url is not null then n_urls := n_urls + 1; end if;

    if v_person.ignoriert then n_team := n_team + 1; continue; end if;   -- Team

    -- Kontakt: schon verknüpft, sonst genau ein Kontakt gleichen Namens, sonst neu
    v_contact := v_person.contact_id;
    select * into z from core.name_zerlegen(v_name);
    if v_contact is null then
      select min(c.contact_id::text)::uuid into v_contact from core.contacts c
       where lower(concat_ws(' ', c.vorname, c.nachname)) = lower(concat_ws(' ', z.vorname, z.nachname))
      having count(*) = 1;
      if v_contact is not null then n_verknuepft := n_verknuepft + 1; end if;
    end if;
    if v_contact is null then
      insert into core.contacts (titel, vorname, nachname, position, herkunft, tags)
      values (z.titel, z.vorname, z.nachname, v_pos, 'linkedin_follower', array['linkedin_follower'])
      returning contact_id into v_contact;
      n_neu := n_neu + 1;
    else
      update core.contacts
         set tags = case when 'linkedin_follower' = any (tags) then tags else array_append(tags, 'linkedin_follower') end,
             position = coalesce(position, v_pos),
             titel = coalesce(titel, z.titel),
             herkunft = coalesce(herkunft, 'linkedin_follower')
       where contact_id = v_contact;
    end if;

    -- Firma (ohne Domain: über den Namen)
    if v_firma is not null and (select company_id from core.contacts where contact_id = v_contact) is null then
      select company_id into v_company from core.companies where lower(name) = lower(v_firma) order by created_at limit 1;
      if v_company is null then
        insert into core.companies (name) values (v_firma) returning company_id into v_company;
      end if;
      update core.contacts set company_id = v_company where contact_id = v_contact;
      v_company := null;
    end if;

    update core.linkedin_personen set contact_id = v_contact where person_id = v_person.person_id and contact_id is null;

    if v_url is not null then
      insert into core.identities (contact_id, identity_type, identity_value, source)
      values (v_contact, 'linkedin_profile_url', v_url, 'linkedin_follower')
      on conflict (identity_type, identity_value) do update set last_seen = now();
    end if;

    if coalesce(v_seit, v_person.follower_seit) is not null then
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      values ('lifollow:' || v_person.person_id, 'linkedin_follow', coalesce(v_seit, v_person.follower_seit)::timestamptz, v_contact, 'linkedin',
              jsonb_build_object('person_id', v_person.person_id, 'nur_monat', true), 'not_required')
      on conflict (event_id) do update set occurred_at = least(core.events.occurred_at, excluded.occurred_at), contact_id = excluded.contact_id;
    end if;

    perform core.linkedin_events(p_person_id => v_person.person_id);   -- frühere Reaktionen in die Timeline
  end loop;

  return jsonb_build_object('gesamt', n_gesamt, 'neue_kontakte', n_neu, 'verknuepft', n_verknuepft,
                            'team', n_team, 'mit_link', n_urls);
end $$;

-- ---------------------------------------------------------------------
-- Kontakt aus einer LinkedIn-Reaktion anlegen: Herkunft, Titel, Position
-- ---------------------------------------------------------------------
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
  if v_p.profil_url is not null then
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_contact, 'linkedin_profile_url', v_p.profil_url, 'linkedin')
    on conflict (identity_type, identity_value) do nothing;
  end if;
  return jsonb_build_object('person_id', p_person_id, 'contact_id', v_contact);
end $$;

-- ---------------------------------------------------------------------
-- Kontakte-Liste: Herkunft, Tags, Newsletter; Filter nach Herkunft/Tag
-- ---------------------------------------------------------------------
drop function if exists public.dashboard_kontakte_liste(text);
create or replace function public.dashboard_kontakte_liste(p_suche text, p_filter text default null)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(k order by k->>'letzte_aktivitaet' desc nulls last, k->>'created_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'contact_id', c.contact_id, 'vorname', c.vorname, 'nachname', c.nachname, 'email', c.email,
               'lifecycle_stage', c.lifecycle_stage, 'owner', c.owner, 'created_at', c.created_at,
               'herkunft', c.herkunft, 'tags', c.tags, 'position', c.position, 'newsletter_erlaubt', c.newsletter_erlaubt,
               'firma', coalesce(co.name, (select e.properties#>>'{antworten,Unternehmen}' from core.events e
                                            where e.contact_id = c.contact_id and e.source = 'cal'
                                              and e.properties#>>'{antworten,Unternehmen}' is not null
                                            order by e.occurred_at desc limit 1)),
               'letzte_aktivitaet', (select max(e.occurred_at) from core.events e where e.contact_id = c.contact_id),
               'besuche', (select count(distinct e.session_id) from core.events e where e.contact_id = c.contact_id and e.source = 'website'),
               'termine', (select count(*) from core.events e where e.contact_id = c.contact_id and e.source = 'cal'
                                                              and e.event_name in ('meeting_booked', 'meeting_rescheduled')),
               'calls', (select count(*) from core.calls k where k.contact_id = c.contact_id),
               'linkedin', (select count(*) from core.events e where e.contact_id = c.contact_id and e.event_name = 'linkedin_reaction')) as k
        from core.contacts c
        left join core.companies co on co.company_id = c.company_id
       where (coalesce(trim(p_suche), '') = ''
              or concat_ws(' ', c.titel, c.vorname, c.nachname, c.email, co.name, c.position) ilike '%' || trim(p_suche) || '%')
         and (p_filter is null or p_filter = ''
              or (p_filter = 'newsletter' and c.newsletter_erlaubt)
              or (p_filter like 'herkunft:%' and c.herkunft = substr(p_filter, 10))
              or (p_filter like 'tag:%' and substr(p_filter, 5) = any (c.tags)))
       limit 1000
    ) x
$$;

-- ---------------------------------------------------------------------
-- Kontakt speichern: neue Felder; Newsletter-Änderung → core.consents
-- ---------------------------------------------------------------------
drop function if exists public.dashboard_kontakt_speichern(jsonb);
create or replace function public.dashboard_kontakt_speichern(p jsonb, p_von text default null)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_id      uuid := (p->>'contact_id')::uuid;
  v_alt     boolean;
  v_neu     boolean := coalesce((p->>'newsletter_erlaubt')::boolean, false);
  v_grund   text := nullif(p->>'newsletter_grundlage', '');
begin
  select newsletter_erlaubt into v_alt from core.contacts where contact_id = v_id;
  if not found then return false; end if;
  if v_neu and v_grund is null then raise exception 'Newsletter erlaubt nur mit Grundlage (Einwilligung oder Bestandskunde)'; end if;

  update core.contacts
     set titel           = nullif(trim(p->>'titel'), ''),
         vorname         = nullif(trim(p->>'vorname'), ''),
         nachname        = nullif(trim(p->>'nachname'), ''),
         telefon         = nullif(trim(p->>'telefon'), ''),
         position        = nullif(trim(p->>'position'), ''),
         lifecycle_stage = coalesce(nullif(p->>'lifecycle_stage', ''), lifecycle_stage),
         zielgruppe      = nullif(trim(p->>'zielgruppe'), ''),
         paketinteresse  = nullif(p->>'paketinteresse', ''),
         lost_grund      = nullif(trim(p->>'lost_grund'), ''),
         owner           = nullif(trim(p->>'owner'), ''),
         notizen         = nullif(p->>'notizen', ''),
         herkunft        = coalesce(nullif(p->>'herkunft', ''), herkunft),
         tags            = coalesce((select array_agg(distinct lower(trim(t))) filter (where trim(t) <> '')
                                       from jsonb_array_elements_text(coalesce(p->'tags', '[]'::jsonb)) t), '{}'),
         newsletter_erlaubt   = v_neu,
         newsletter_grundlage = case when v_neu then v_grund end,
         newsletter_seit      = case when v_neu and not v_alt then now() when v_neu then newsletter_seit end
   where contact_id = v_id;

  if v_neu is distinct from v_alt then
    insert into core.consents (contact_id, channel, status, source)
    values (v_id, 'email_marketing', case when v_neu then 'granted' else 'revoked' end,
            'cockpit:' || coalesce(v_grund, 'zurückgenommen') || ':' || coalesce(p_von, 'unbekannt'));
  end if;
  return true;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.dashboard_linkedin_follower(jsonb, text)', 'public.dashboard_linkedin_person(uuid, text, uuid)',
    'public.dashboard_kontakte_liste(text, text)', 'public.dashboard_kontakt_speichern(jsonb, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
