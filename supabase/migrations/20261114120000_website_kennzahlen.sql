-- =====================================================================
-- Cockpit Website: Kennzahlen um Verweildauer und Leads ergänzt
-- =====================================================================
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
        'klicks',        count(*) filter (where event_name = 'cta_click'),
        -- Ø Dauer einer Sitzung: erstes bis letztes Ereignis (section_time wird beim
        -- Verlassen gesendet und markiert so das Ende). Nur Sitzungen mit Einwilligung.
        'verweildauer',  (select round(avg(d)) from (
                            select extract(epoch from max(x.occurred_at) - min(x.occurred_at)) as d
                              from e x where x.session_id is not null group by x.session_id) s),
        -- Leads = neue Kontakte im Zeitraum (heute: Terminbuchungen, Calls; später weitere Quellen)
        'leads',         (select count(*) from core.contacts c where c.created_at >= p_von and c.created_at < p_bis))
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
