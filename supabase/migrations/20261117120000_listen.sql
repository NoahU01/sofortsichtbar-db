-- =====================================================================
-- Listen (= Tags an Kontakten) im Cockpit bauen und pflegen
--
--   dashboard_listen()                      alle Listen mit Anzahl und Newsletter-Erlaubten
--   dashboard_liste_zuordnen(ids, liste, …) Kontakte einer Liste hinzufügen oder entfernen
--   dashboard_liste_loeschen(liste)         Liste auflösen (Tag bei allen entfernen)
--
-- Einer Liste hinzufügen heißt NICHT, dass jemand den Newsletter bekommen
-- darf – die Erlaubnis bleibt getrennt (newsletter_erlaubt + Grundlage).
-- Die Kontaktliste liefert zusätzlich Titel und Telefon.
-- =====================================================================

create or replace function core.liste_name(p text)
returns text language sql immutable set search_path = '' as $$
  select nullif(left(lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')), 60), '')
$$;

create or replace function public.dashboard_listen()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('liste', t, 'kontakte', n, 'erlaubt', e) order by t), '[]'::jsonb)
    from (select t, count(*) as n,
                 count(*) filter (where c.newsletter_erlaubt and c.email is not null
                                    and not exists (select 1 from core.newsletter_sperre s where s.email = c.email)) as e
            from core.contacts c cross join lateral unnest(c.tags) t group by t) x
$$;

-- p_aktion: 'hinzufuegen' | 'entfernen'. Gibt zurück, wie viele Kontakte sich geändert haben
-- und wie viele der betroffenen Kontakte den Newsletter bekommen dürfen.
create or replace function public.dashboard_liste_zuordnen(p_contact_ids uuid[], p_liste text, p_aktion text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_liste text := core.liste_name(p_liste);
  n integer;
begin
  if v_liste is null then raise exception 'Name der Liste fehlt'; end if;
  if p_aktion = 'hinzufuegen' then
    update core.contacts set tags = array_append(tags, v_liste)
     where contact_id = any (p_contact_ids) and not (v_liste = any (tags));
  elsif p_aktion = 'entfernen' then
    update core.contacts set tags = array_remove(tags, v_liste)
     where contact_id = any (p_contact_ids) and v_liste = any (tags);
  else
    raise exception 'unbekannte Aktion';
  end if;
  get diagnostics n = row_count;
  return jsonb_build_object(
    'liste', v_liste, 'geaendert', n,
    'ausgewaehlt', coalesce(cardinality(p_contact_ids), 0),
    'mit_erlaubnis', (select count(*) from core.contacts c
                       where c.contact_id = any (p_contact_ids) and c.newsletter_erlaubt and c.email is not null
                         and not exists (select 1 from core.newsletter_sperre s where s.email = c.email)));
end $$;

create or replace function public.dashboard_liste_loeschen(p_liste text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  update core.contacts set tags = array_remove(tags, core.liste_name(p_liste)) where core.liste_name(p_liste) = any (tags);
  get diagnostics n = row_count;
  return n;
end $$;

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
               'titel', c.titel, 'telefon', c.telefon,
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
              or (p_filter = 'ohne_position' and c.position is null)
              or (p_filter = 'name_unvollstaendig' and (c.vorname is null or c.nachname is null or c.nachname ~ '^[A-ZÄÖÜ]\.$'))
              or (p_filter like 'herkunft:%' and c.herkunft = substr(p_filter, 10))
              or (p_filter like 'tag:%' and substr(p_filter, 5) = any (c.tags)))
       limit 1000
    ) x
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_listen()', 'public.dashboard_liste_zuordnen(uuid[], text, text)', 'public.dashboard_liste_loeschen(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
