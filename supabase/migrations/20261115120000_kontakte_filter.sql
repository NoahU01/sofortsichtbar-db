-- =====================================================================
-- Kontakte-Liste: Filter für Lücken, die von Hand nachgezogen werden
--   ohne_position        Position leer (z. B. LinkedIn-Slogan entfernt)
--   name_unvollstaendig  Vor- oder Nachname fehlt oder nur Initial („F.“)
-- =====================================================================
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
              or (p_filter = 'ohne_position' and c.position is null)
              or (p_filter = 'name_unvollstaendig' and (c.vorname is null or c.nachname is null or c.nachname ~ '^[A-ZÄÖÜ]\.$'))
              or (p_filter like 'herkunft:%' and c.herkunft = substr(p_filter, 10))
              or (p_filter like 'tag:%' and substr(p_filter, 5) = any (c.tags)))
       limit 1000
    ) x
$$;
