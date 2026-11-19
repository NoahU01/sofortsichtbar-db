-- =====================================================================
-- Kontakte: Filter-Baukasten (Cockpit „+ Filter“) und Firmen-Ansicht
--
-- p (jsonb), alle Teile optional und mit UND verknüpft:
--   suche        Freitext über Name, E-Mail, Firma, Position
--   name         Name enthält …           position  Position enthält …
--   firma        Firma enthält …          firma_id  genau diese Firma
--   position_leer true = ohne Position    name_unvollstaendig true
--   herkunft     ["linkedin","instagram","website","termin","postfach","call","manuell","import","facebook"]  (ODER)
--   follower     ["linkedin","instagram","facebook"]                                                  (ODER)
--   newsletter   "ja" | "nein"
--   signale      ["website","preise","termin","call","mail_ein","mail_aus","nl_offen","nl_klick",
--                 "li_reaktion","li_kommentar","ig_like","ig_kommentar"]                              (ODER)
--   signal_tage  nur Signale der letzten n Tage (leer = jemals)
--   liste        Tag/Liste
-- Ein Signal-Score folgt, sobald die Gewichtung steht.
-- =====================================================================

create or replace function core.kontakte_gefiltert(p jsonb)
returns setof uuid
language sql stable set search_path = ''
as $$
  with f as (
    select nullif(trim(p->>'suche'), '') as suche, nullif(trim(p->>'name'), '') as name, nullif(trim(p->>'position'), '') as pos,
           nullif(trim(p->>'firma'), '') as firma, nullif(p->>'firma_id', '')::uuid as firma_id,
           coalesce((p->>'position_leer')::boolean, false) as pos_leer, coalesce((p->>'name_unvollstaendig')::boolean, false) as name_unv,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'herkunft') x), '{}') as herkunft,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'follower') x), '{}') as follower,
           nullif(p->>'newsletter', '') as nl,
           coalesce((select array_agg(x) from jsonb_array_elements_text(p->'signale') x), '{}') as sig,
           nullif(p->>'signal_tage', '')::integer as tage,
           nullif(trim(p->>'liste'), '') as liste
  )
  select c.contact_id
    from core.contacts c
    left join core.companies co on co.company_id = c.company_id
    cross join f
   where (f.suche is null or concat_ws(' ', c.titel, c.vorname, c.nachname, c.email, co.name, c.position) ilike '%' || f.suche || '%')
     and (f.name is null or concat_ws(' ', c.titel, c.vorname, c.nachname) ilike '%' || f.name || '%')
     and (f.pos is null or c.position ilike '%' || f.pos || '%')
     and (not f.pos_leer or c.position is null)
     and (not f.name_unv or c.vorname is null or c.nachname is null or c.nachname ~ '^[A-ZÄÖÜ]\.$')
     and (f.firma is null or co.name ilike '%' || f.firma || '%')
     and (f.firma_id is null or c.company_id = f.firma_id)
     and (cardinality(f.herkunft) = 0 or c.herkunft = any (
            select unnest(case h when 'linkedin' then array['linkedin_follower', 'linkedin_reaktion'] else array[h] end) from unnest(f.herkunft) h))
     and (cardinality(f.follower) = 0 or c.tags && (select array_agg(x || '_follower') from unnest(f.follower) x))
     and (f.nl is null or (f.nl = 'ja') = c.newsletter_erlaubt)
     and (f.liste is null or f.liste = any (c.tags))
     and (cardinality(f.sig) = 0
          or ('call' = any (f.sig) and exists (select 1 from core.calls k where k.contact_id = c.contact_id
                                                  and (f.tage is null or k.stattgefunden_am >= now() - make_interval(days => f.tage))))
          or exists (select 1 from core.events e
                      where e.contact_id = c.contact_id
                        and (f.tage is null or e.occurred_at >= now() - make_interval(days => f.tage))
                        and (   ('website'      = any (f.sig) and e.source = 'website')
                             or ('preise'       = any (f.sig) and e.source = 'website' and (e.page_type = 'preis' or e.event_name = 'pricing_toggle'))
                             or ('termin'       = any (f.sig) and e.event_name in ('meeting_booked', 'calendar_meeting'))
                             or ('mail_ein'     = any (f.sig) and e.event_name = 'mail_received')
                             or ('mail_aus'     = any (f.sig) and e.event_name = 'mail_sent')
                             or ('nl_offen'     = any (f.sig) and e.event_name = 'email_open')
                             or ('nl_klick'     = any (f.sig) and e.event_name = 'email_click')
                             or ('li_reaktion'  = any (f.sig) and e.event_name = 'linkedin_reaction')
                             or ('li_kommentar' = any (f.sig) and e.event_name = 'linkedin_comment')
                             or ('ig_like'      = any (f.sig) and e.event_name = 'instagram_like')
                             or ('ig_kommentar' = any (f.sig) and e.event_name = 'instagram_comment'))))
$$;

create or replace function public.dashboard_kontakte_suche(p jsonb)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(k order by k->>'letzte_aktivitaet' desc nulls last, k->>'created_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'contact_id', c.contact_id, 'vorname', c.vorname, 'nachname', c.nachname, 'email', c.email,
               'lifecycle_stage', c.lifecycle_stage, 'owner', c.owner, 'created_at', c.created_at,
               'herkunft', c.herkunft, 'tags', c.tags, 'position', c.position, 'newsletter_erlaubt', c.newsletter_erlaubt,
               'titel', c.titel, 'telefon', c.telefon, 'company_id', c.company_id,
               'firma', coalesce(co.name, (select e.properties#>>'{antworten,Unternehmen}' from core.events e
                                            where e.contact_id = c.contact_id and e.source = 'cal'
                                              and e.properties#>>'{antworten,Unternehmen}' is not null
                                            order by e.occurred_at desc limit 1)),
               'letzte_aktivitaet', (select max(e.occurred_at) from core.events e where e.contact_id = c.contact_id)) as k
        from core.contacts c
        left join core.companies co on co.company_id = c.company_id
       where c.contact_id in (select core.kontakte_gefiltert(p))
       limit 1000
    ) x
$$;

-- Firmen mit mindestens einem passenden Kontakt (der Name-Filter gilt dort für den Firmennamen)
create or replace function public.dashboard_firmen_liste(p jsonb)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with treffer as (
    select c.* from core.contacts c
     where c.company_id is not null
       and c.contact_id in (select core.kontakte_gefiltert((p - 'name' - 'firma') ||
                                    case when nullif(trim(coalesce(p->>'firma', p->>'name')), '') is not null
                                         then jsonb_build_object('firma', coalesce(p->>'firma', p->>'name')) else '{}'::jsonb end))
  )
  select coalesce(jsonb_agg(z order by z->>'letzte_aktivitaet' desc nulls last, z->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
             'company_id', co.company_id, 'name', co.name, 'domain', co.domain,
             'kontakte', (select count(*) from core.contacts c where c.company_id = co.company_id),
             'treffer', count(t.contact_id),
             'newsletter', count(*) filter (where t.newsletter_erlaubt),
             'follower', (select array_agg(distinct replace(x, '_follower', '')) from core.contacts c, unnest(c.tags) x
                           where c.company_id = co.company_id and x like '%\_follower'),
             'herkunft', (select array_agg(distinct c.herkunft) from core.contacts c where c.company_id = co.company_id and c.herkunft is not null),
             'letzte_aktivitaet', (select max(e.occurred_at) from core.events e join core.contacts c on c.contact_id = e.contact_id
                                    where c.company_id = co.company_id)) as z
      from core.companies co join treffer t on t.company_id = co.company_id
     group by co.company_id
     limit 1000) x
$$;

-- Zahlen fürs Filtermenü (wie viele Kontakte je Herkunft/Follower)
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
    'firmen', (select count(*) from core.companies co where exists (select 1 from core.contacts c where c.company_id = co.company_id))
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_kontakte_suche(jsonb)', 'public.dashboard_firmen_liste(jsonb)', 'public.dashboard_kontakte_facetten()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
