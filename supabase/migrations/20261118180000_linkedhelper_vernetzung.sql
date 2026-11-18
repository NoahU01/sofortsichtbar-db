-- =====================================================================
-- LinkedHelper: Daniels Vernetzungs-Kampagne geht an alle (auch empiria).
-- Sendungen mit art 'vernetzung' oder 'antwort' werden deshalb nur
-- gespeichert, wenn die Person schon Kontakt ist (Abgleich über
-- LinkedIn-Profil-URL oder E-Mail). Alle anderen werden verworfen und nicht
-- gespeichert. Nur 'profil' (die sofort-sichtbar-Sammelkampagnen:
-- Beitrags-Interaktionen, Follower) darf Unbekannte aufnehmen.
-- =====================================================================

alter table core.linkedhelper_eingang drop constraint linkedhelper_eingang_art_check;
alter table core.linkedhelper_eingang add constraint linkedhelper_eingang_art_check check (art in ('profil', 'vernetzung', 'antwort'));
alter table core.linkedhelper_eingang alter column payload drop not null;

create table core.linkedhelper_verworfen (
  tag    date not null default current_date,
  art    text not null,
  anzahl integer not null default 0,
  primary key (tag, art)
);
alter table core.linkedhelper_verworfen enable row level security;
grant all on core.linkedhelper_verworfen to service_role;

create or replace function public.ingest_linkedhelper(p jsonb, p_art text default 'profil')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_url text; v_mail text; v_contact uuid; v_id bigint;
        v_art text := case when p_art in ('vernetzung', 'antwort') then p_art else 'profil' end;
begin
  select core.linkedin_profil_norm(t #>> '{}') into v_url
    from jsonb_path_query(p, 'strict $.**') t
   where jsonb_typeof(t) = 'string' and (t #>> '{}') ~* 'linkedin\.com/in/'
   limit 1;
  select lower(trim(t #>> '{}')) into v_mail
    from jsonb_path_query(p, 'strict $.**') t
   where jsonb_typeof(t) = 'string' and (t #>> '{}') ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'
   limit 1;

  if v_url is not null then
    select i.contact_id into v_contact from core.identities i
     where i.identity_type = 'linkedin_profile_url' and core.linkedin_profil_norm(i.identity_value) = v_url limit 1;
    if v_contact is null then
      select lp.contact_id into v_contact from core.linkedin_personen lp
       where lp.contact_id is not null and not lp.ignoriert and core.linkedin_profil_norm(lp.profil_url) = v_url limit 1;
    end if;
  end if;
  if v_contact is null and v_mail is not null then
    select i.contact_id into v_contact from core.identities i where i.identity_type = 'email' and i.identity_value = v_mail limit 1;
  end if;

  -- Vernetzung/Antwort von Unbekannten: nicht speichern, nur zählen
  if v_art <> 'profil' and v_contact is null then
    insert into core.linkedhelper_verworfen (art, anzahl) values (v_art, 1)
    on conflict (tag, art) do update set anzahl = core.linkedhelper_verworfen.anzahl + 1;
    return jsonb_build_object('verworfen', true);
  end if;

  insert into core.linkedhelper_eingang (art, payload, profil_url, email, contact_id)
  values (v_art, p, v_url, v_mail, v_contact)
  returning eingang_id into v_id;
  return jsonb_build_object('eingang_id', v_id, 'profil_url', v_url, 'contact_id', v_contact);
end $$;

revoke all on function public.ingest_linkedhelper(jsonb, text) from public, anon, authenticated;
grant execute on function public.ingest_linkedhelper(jsonb, text) to service_role;
