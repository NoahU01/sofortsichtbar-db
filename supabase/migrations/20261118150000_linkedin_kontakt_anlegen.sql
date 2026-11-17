-- „Kontakt anlegen“ im LinkedIn-Bereich: Name ohne Zusätze/Emojis (wie die
-- automatische Zuordnung) und kein Doppel, wenn es den Kontakt schon gibt.
create or replace function public.dashboard_linkedin_person(p_person_id uuid, p_aktion text, p_contact_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_p core.linkedin_personen;
  v_contact uuid;
  v_n integer;
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
    -- Name ohne Zusätze und Emojis; gibt es genau einen gleichnamigen Kontakt, wird der genommen
    select * into z from core.name_zerlegen(coalesce(core.linkedin_name_sauber(v_p.name), v_p.name));
    select count(*), min(c.contact_id::text)::uuid into v_n, v_contact
      from core.contacts c where lower(concat_ws(' ', c.vorname, c.nachname)) = lower(concat_ws(' ', z.vorname, z.nachname));
    if v_n <> 1 then
      insert into core.contacts (titel, vorname, nachname, herkunft)
      values (z.titel, z.vorname, z.nachname, 'linkedin_reaktion')
      returning contact_id into v_contact;
      if v_p.follower_seit is not null then
        update core.contacts set tags = array['linkedin_follower'] where contact_id = v_contact;
      end if;
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

revoke all on function public.dashboard_linkedin_person(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.dashboard_linkedin_person(uuid, text, uuid) to service_role;
