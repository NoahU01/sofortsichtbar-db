-- =====================================================================
-- Cockpit: Auswertung Website + Kontakte
--
-- Lesefunktionen für die Bereiche „Website“ und „Kontakte“ im Cockpit, dazu
-- Bearbeiten und Löschen eines Kontakts. Wie alle dashboard_*-Funktionen nur
-- für service_role; aufgerufen über die Edge Function `dashboard`.
-- Tage werden in deutscher Zeit (Europe/Berlin) gezählt.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Website
-- ---------------------------------------------------------------------
create or replace function public.dashboard_website(p_von timestamptz, p_bis timestamptz, p_intern boolean default false)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with e as (
    select ev.*,
           coalesce(nullif(regexp_replace(split_part(ev.page_url, '?', 1), '^https?://[^/]+', ''), ''), '/') as pfad
      from core.events ev
     where ev.source = 'website'
       and ev.occurred_at >= p_von and ev.occurred_at < p_bis
       and (p_intern or not ev.internal)
  ),
  s as (
    select e.session_id,
           case
             when e.properties ?| array['gclid','gbraid','wbraid'] then 'Google Ads'
             when e.properties ? 'li_fat_id' then 'LinkedIn Ads'
             when e.properties ? 'fbclid' then 'Meta'
             when e.properties ? 'ttclid' then 'TikTok'
             when e.properties ? 'utm_source' then lower(e.properties->>'utm_source') || coalesce(' / ' || lower(e.properties->>'utm_medium'), '')
             when e.properties->>'referrer' ~* 'linkedin\.|lnkd\.in' then 'LinkedIn'
             when e.properties->>'referrer' ~* '(^|\.)google\.' then 'Google (organisch)'
             when e.properties->>'referrer' ~* '(^|\.)bing\.' then 'Bing (organisch)'
             when e.properties->>'referrer' ~* 'chatgpt|openai|perplexity|claude\.ai|gemini' then 'KI-Assistenten'
             when e.properties ? 'referrer' then regexp_replace(e.properties->>'referrer', '^https?://(www\.)?', '')
             else 'Direkt / unbekannt'
           end as quelle
      from e
     where e.event_name = 'session_start'
  ),
  pv_typ as (
    select page_type, count(*) as n from e where event_name = 'page_view' group by page_type
  ),
  tage as (
    select d::date as tag
      from generate_series((p_von at time zone 'Europe/Berlin')::date,
                           ((p_bis - interval '1 second') at time zone 'Europe/Berlin')::date,
                           interval '1 day') d
  )
  select jsonb_build_object(
    'kennzahlen', (
      select jsonb_build_object(
        'seitenaufrufe', count(*) filter (where event_name = 'page_view'),
        'besucher',      count(distinct visitor_id),
        'sitzungen',     count(*) filter (where event_name = 'session_start'),
        'einwilligung',  round(100.0 * count(*) filter (where event_name = 'page_view' and consent_state = 'granted')
                               / nullif(count(*) filter (where event_name = 'page_view'), 0)),
        'kalender',      count(*) filter (where event_name = 'booking_widget_view'),
        'buchungen',     count(*) filter (where event_name = 'meeting_booked'),
        'klicks',        count(*) filter (where event_name = 'cta_click'))
      from e),
    'verlauf', (
      select coalesce(jsonb_agg(jsonb_build_object('tag', t.tag, 'seitenaufrufe', coalesce(v.pv, 0), 'sitzungen', coalesce(v.ss, 0)) order by t.tag), '[]'::jsonb)
        from tage t
        left join (
          select (occurred_at at time zone 'Europe/Berlin')::date as tag,
                 count(*) filter (where event_name = 'page_view') as pv,
                 count(*) filter (where event_name = 'session_start') as ss
            from e group by 1
        ) v using (tag)),
    'quellen', (
      select coalesce(jsonb_agg(q order by (q->>'sitzungen')::int desc), '[]'::jsonb) from (
        select jsonb_build_object(
                 'quelle', s.quelle,
                 'sitzungen', count(*),
                 'kalender', count(*) filter (where exists (select 1 from e b where b.session_id = s.session_id and b.event_name = 'booking_widget_view')),
                 'buchungen', count(*) filter (where exists (select 1 from e b where b.session_id = s.session_id and b.event_name = 'meeting_booked'))) as q
          from s group by s.quelle order by count(*) desc limit 15) x),
    'seiten', (
      select coalesce(jsonb_agg(jsonb_build_object('pfad', pfad, 'seitentyp', page_type, 'aufrufe', n, 'sitzungen', ss) order by n desc), '[]'::jsonb) from (
        select pfad, page_type, count(*) as n, count(distinct session_id) as ss
          from e where event_name = 'page_view' group by pfad, page_type order by count(*) desc limit 20) x),
    'abschnitte', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'seitentyp', a.page_type, 'abschnitt', a.sektion, 'gesehen', a.gesehen,
               'reichweite', round(100.0 * a.gesehen / nullif(p.n, 0)),
               'sekunden', a.sekunden) order by a.page_type, a.gesehen desc), '[]'::jsonb)
        from (
          select page_type, properties->>'section' as sektion,
                 count(*) filter (where event_name = 'section_view') as gesehen,
                 round(avg((properties->>'seconds')::numeric) filter (where event_name = 'section_time'
                         and jsonb_typeof(properties->'seconds') = 'number'), 1) as sekunden
            from e
           where event_name in ('section_view', 'section_time') and properties ? 'section'
           group by 1, 2) a
        left join pv_typ p using (page_type)),
    'klicks', (
      select coalesce(jsonb_agg(jsonb_build_object('ziel', ziel, 'anzahl', n) order by n desc), '[]'::jsonb) from (
        select coalesce(properties->>'ziel', 'sonstige') as ziel, count(*) as n
          from e where event_name = 'cta_click' group by 1) x),
    'geraete', (
      select coalesce(jsonb_agg(jsonb_build_object('geraet', g, 'anteil', round(100.0 * n / gesamt)) order by n desc), '[]'::jsonb) from (
        select coalesce(properties->>'geraet', 'unbekannt') as g, count(*) as n, sum(count(*)) over () as gesamt
          from e where event_name = 'page_view' group by 1) x)
  )
$$;

-- ---------------------------------------------------------------------
-- Kontakte
-- ---------------------------------------------------------------------
create or replace function public.dashboard_kontakte_liste(p_suche text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(k order by k->>'letzte_aktivitaet' desc nulls last), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'contact_id', c.contact_id, 'vorname', c.vorname, 'nachname', c.nachname, 'email', c.email,
               'lifecycle_stage', c.lifecycle_stage, 'owner', c.owner, 'created_at', c.created_at,
               'firma', coalesce(co.name, (select e.properties#>>'{antworten,Unternehmen}' from core.events e
                                            where e.contact_id = c.contact_id and e.source = 'cal'
                                              and e.properties#>>'{antworten,Unternehmen}' is not null
                                            order by e.occurred_at desc limit 1)),
               'letzte_aktivitaet', (select max(e.occurred_at) from core.events e where e.contact_id = c.contact_id),
               'besuche', (select count(distinct e.session_id) from core.events e where e.contact_id = c.contact_id and e.source = 'website'),
               'termine', (select count(*) from core.events e where e.contact_id = c.contact_id and e.source = 'cal'
                                                              and e.event_name in ('meeting_booked', 'meeting_rescheduled')),
               'calls', (select count(*) from core.calls k where k.contact_id = c.contact_id)) as k
        from core.contacts c
        left join core.companies co on co.company_id = c.company_id
       where coalesce(trim(p_suche), '') = ''
          or concat_ws(' ', c.vorname, c.nachname, c.email, co.name) ilike '%' || trim(p_suche) || '%'
       limit 500
    ) x
$$;

create or replace function public.dashboard_kontakt(p_contact_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'kontakt', to_jsonb(c) || jsonb_build_object('firma', co.name),
    'identitaeten', (select coalesce(jsonb_agg(jsonb_build_object('typ', i.identity_type, 'wert', i.identity_value,
                                                                  'quelle', i.source, 'seit', i.first_seen) order by i.first_seen), '[]'::jsonb)
                       from core.identities i where i.contact_id = c.contact_id),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                          'event_name', e.event_name, 'zeit', e.occurred_at, 'quelle', e.source, 'sitzung', e.session_id,
                          'seitentyp', e.page_type,
                          'pfad', coalesce(nullif(regexp_replace(split_part(e.page_url, '?', 1), '^https?://[^/]+', ''), ''), case when e.page_url is not null then '/' end),
                          'props', e.properties) order by e.occurred_at desc), '[]'::jsonb)
                   from (select * from core.events where contact_id = c.contact_id order by occurred_at desc limit 1000) e)
  )
    from core.contacts c
    left join core.companies co on co.company_id = c.company_id
   where c.contact_id = p_contact_id
$$;

-- Bearbeiten: nur diese Felder, leere Strings werden zu NULL
create or replace function public.dashboard_kontakt_speichern(p jsonb)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  update core.contacts
     set vorname         = nullif(trim(p->>'vorname'), ''),
         nachname        = nullif(trim(p->>'nachname'), ''),
         telefon         = nullif(trim(p->>'telefon'), ''),
         lifecycle_stage = coalesce(nullif(p->>'lifecycle_stage', ''), lifecycle_stage),
         zielgruppe      = nullif(trim(p->>'zielgruppe'), ''),
         paketinteresse  = nullif(p->>'paketinteresse', ''),
         lost_grund      = nullif(trim(p->>'lost_grund'), ''),
         owner           = nullif(trim(p->>'owner'), ''),
         notizen         = nullif(p->>'notizen', '')
   where contact_id = (p->>'contact_id')::uuid;
  return found;
end $$;

create or replace function public.dashboard_kontakt_loeschen(p_contact_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from core.contacts where contact_id = p_contact_id) then return false; end if;
  perform core.delete_contact(p_contact_id);
  return true;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.dashboard_website(timestamptz, timestamptz, boolean)',
    'public.dashboard_kontakte_liste(text)',
    'public.dashboard_kontakt(uuid)',
    'public.dashboard_kontakt_speichern(jsonb)',
    'public.dashboard_kontakt_loeschen(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
