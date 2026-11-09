-- =====================================================================
-- Annahme für das First-Party-Tracking der Website
--
-- Der Endpunkt /api/track auf sofortsichtbar.de (Vercel-Funktion) ruft
-- public.ingest_events per RPC mit dem Secret Key auf. Nur service_role darf
-- die Funktion ausführen – anon/authenticated nicht, auch wenn sie in public
-- liegt (public ist das einzige Schema, das die Data API ohne Zusatz-
-- einstellung freigibt).
-- =====================================================================

-- Eigene Zugriffe (?internal=1, Vorschau-Umgebungen) werden gespeichert,
-- aber markiert: So lässt sich das Tracking testen, ohne die Auswertung zu
-- verfälschen. Auswertungen filtern auf internal = false.
alter table core.events add column internal boolean not null default false;

insert into core.event_types (event_name, quelle, beschreibung) values
  ('booking_widget_view', 'website', 'Cal.com-Kalender wurde geladen und angezeigt'),
  ('pricing_toggle',      'website', 'Preis-Umschalter monatlich/jährlich bedient');

create or replace function public.ingest_events(p_events jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  if jsonb_typeof(p_events) <> 'array' then
    raise exception 'p_events muss ein JSON-Array sein';
  end if;

  insert into core.events (
    event_id, event_name, occurred_at, visitor_id, session_id, source,
    page_url, page_type, properties, consent_state, internal
  )
  select e->>'event_id',
         e->>'event_name',
         coalesce((e->>'occurred_at')::timestamptz, now()),
         e->>'visitor_id',
         e->>'session_id',
         coalesce(e->>'source', 'website'),
         e->>'page_url',
         e->>'page_type',
         coalesce(e->'properties', '{}'::jsonb),
         coalesce(e->>'consent_state', 'unknown'),
         coalesce((e->>'internal')::boolean, false)
    from jsonb_array_elements(p_events) as e
  on conflict (event_id) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.ingest_events(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_events(jsonb) to service_role;
