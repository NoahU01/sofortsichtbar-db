-- =====================================================================
-- Tag-Katalog und E-Mail in der Kontaktkarte
--
--   core.tags   definierte Tags (= Listen). In der Kontaktkarte werden Tags
--               per „+“ aus diesem Katalog gewählt, nicht frei getippt.
--               Neue Tags entstehen über „Tags verwalten“ oder eine neue
--               Liste im Cockpit; Tags, die Importe setzen, kommen per
--               Trigger automatisch in den Katalog.
--   Kontakt speichern: E-Mail änderbar (neue Adresse wird zusätzlich als
--               Kennung gespeichert, darf keinem anderen Kontakt gehören).
-- =====================================================================

create table core.tags (
  name       text primary key check (name = core.liste_name(name)),
  created_at timestamptz not null default now()
);
alter table core.tags enable row level security;
grant all on core.tags to service_role;

insert into core.tags (name)
select distinct core.liste_name(t) from core.contacts c cross join lateral unnest(c.tags) t
 where core.liste_name(t) is not null
on conflict do nothing;

create or replace function core.tags_katalog()
returns trigger language plpgsql set search_path = '' as $$
begin
  insert into core.tags (name)
  select distinct core.liste_name(t) from unnest(new.tags) t where core.liste_name(t) is not null
  on conflict do nothing;
  return null;
end $$;
create trigger contacts_tags_katalog
  after insert or update of tags on core.contacts
  for each row when (cardinality(new.tags) > 0)
  execute function core.tags_katalog();

-- Listen/Tags mit Anzahl (auch Tags ohne Kontakte)
create or replace function public.dashboard_listen()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('liste', x.name, 'kontakte', x.n, 'erlaubt', x.e) order by x.name), '[]'::jsonb)
    from (select t.name, count(c.contact_id) as n,
                 count(c.contact_id) filter (where c.newsletter_erlaubt and c.email is not null
                                               and not exists (select 1 from core.newsletter_sperre s where s.email = c.email)) as e
            from core.tags t left join core.contacts c on t.name = any (c.tags)
           group by t.name) x
$$;

create or replace function public.dashboard_tag_anlegen(p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v text := core.liste_name(p_name);
begin
  if v is null then raise exception 'Name fehlt'; end if;
  insert into core.tags (name) values (v) on conflict do nothing;
  return v;
end $$;

-- Liste auflösen = Tag bei allen entfernen und aus dem Katalog löschen
create or replace function public.dashboard_liste_loeschen(p_liste text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  update core.contacts set tags = array_remove(tags, core.liste_name(p_liste)) where core.liste_name(p_liste) = any (tags);
  get diagnostics n = row_count;
  delete from core.tags where name = core.liste_name(p_liste);
  return n;
end $$;

create or replace function public.dashboard_kontakt_speichern(p jsonb, p_von text default null)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_id      uuid := (p->>'contact_id')::uuid;
  v_alt     boolean;
  v_neu     boolean := coalesce((p->>'newsletter_erlaubt')::boolean, false);
  v_grund   text := nullif(p->>'newsletter_grundlage', '');
  v_mail    text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
begin
  select newsletter_erlaubt into v_alt from core.contacts where contact_id = v_id;
  if not found then return false; end if;
  -- E-Mail: leer = unverändert; neue Adresse darf keinem anderen Kontakt gehören
  if v_mail is not null and v_mail is distinct from (select email from core.contacts where contact_id = v_id) then
    if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Ungültige E-Mail-Adresse'; end if;
    if exists (select 1 from core.contacts where email = v_mail and contact_id <> v_id)
       or exists (select 1 from core.identities where identity_type = 'email' and identity_value = v_mail and contact_id <> v_id) then
      raise exception 'Diese E-Mail-Adresse gehört schon zu einem anderen Kontakt';
    end if;
    update core.contacts set email = v_mail where contact_id = v_id;
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_id, 'email', v_mail, 'manuell') on conflict (identity_type, identity_value) do nothing;
  end if;
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
         tags            = coalesce((select array_agg(distinct core.liste_name(t)) filter (where core.liste_name(t) is not null)
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
  foreach f in array array['public.dashboard_listen()', 'public.dashboard_tag_anlegen(text)', 'public.dashboard_liste_loeschen(text)',
                           'public.dashboard_kontakt_speichern(jsonb, text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
