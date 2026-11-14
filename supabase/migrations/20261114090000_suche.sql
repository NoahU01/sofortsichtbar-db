-- =====================================================================
-- Suche: Google Search Console, Bing Webmaster Tools, GA4-Abgleich
--
-- Die Edge Function `suche-import` holt die Zahlen (täglich per pg_cron,
-- siehe 20261114090100_suche_zeitplan.sql) und schreibt sie über
-- public.ingest_suche. Aggregate, keine Personendaten.
--
-- Bing liefert Suchbegriffe nur wochenweise (tag = Wochenbeginn laut Bing),
-- Google tageweise. Tagessummen stehen getrennt in analytics.suche_tage,
-- weil Google anonymisierte Suchanfragen nur in den Summen zählt.
-- =====================================================================

create table analytics.suchbegriffe (
  quelle       text not null check (quelle in ('google', 'bing')),
  tag          date not null,
  suchbegriff  text not null,
  seite        text not null default '',   -- Google: URL; Bing: leer
  geraet       text not null default '',   -- Google: DESKTOP/MOBILE/TABLET; Bing: leer
  klicks       integer not null default 0,
  impressionen integer not null default 0,
  position     numeric(6,2),
  abgerufen_am timestamptz not null default now(),
  primary key (quelle, tag, suchbegriff, seite, geraet)
);
create index suchbegriffe_tag_idx on analytics.suchbegriffe (quelle, tag);

create table analytics.suche_tage (
  quelle       text not null check (quelle in ('google', 'bing')),
  tag          date not null,
  klicks       integer not null default 0,
  impressionen integer not null default 0,
  position     numeric(6,2),
  abgerufen_am timestamptz not null default now(),
  primary key (quelle, tag)
);

-- Zum Abgleich mit dem eigenen Tracking
create table analytics.ga4_tage (
  tag           date primary key,
  nutzer        integer not null default 0,
  sitzungen     integer not null default 0,
  seitenaufrufe integer not null default 0,
  abgerufen_am  timestamptz not null default now()
);

-- Jeder Abruf wird protokolliert – so sieht man im Cockpit, ob es läuft.
create table analytics.import_laeufe (
  lauf_id    bigint generated always as identity primary key,
  quelle     text not null,
  gestartet  timestamptz not null default now(),
  zeilen     integer,
  fehler     text
);
create index import_laeufe_idx on analytics.import_laeufe (quelle, gestartet desc);

alter table analytics.suchbegriffe  enable row level security;
alter table analytics.suche_tage    enable row level security;
alter table analytics.ga4_tage      enable row level security;
alter table analytics.import_laeufe enable row level security;
grant all on analytics.suchbegriffe, analytics.suche_tage, analytics.ga4_tage, analytics.import_laeufe to service_role;

-- ---------------------------------------------------------------------
-- Annahme. p: { quelle, suchbegriffe: [...], tage: [...], ga4: [...], fehler }
-- Gleiche Schlüssel werden überschrieben (Google korrigiert frische Tage noch).
-- ---------------------------------------------------------------------
create or replace function public.ingest_suche(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  n_sb integer := 0; n_t integer := 0; n_g integer := 0;
  v_quelle text := p->>'quelle';
begin
  if v_quelle in ('google', 'bing') then
    insert into analytics.suchbegriffe (quelle, tag, suchbegriff, seite, geraet, klicks, impressionen, position, abgerufen_am)
    select v_quelle, (r->>'tag')::date, left(r->>'suchbegriff', 500), coalesce(left(r->>'seite', 1000), ''), coalesce(r->>'geraet', ''),
           coalesce((r->>'klicks')::integer, 0), coalesce((r->>'impressionen')::integer, 0), (r->>'position')::numeric, now()
      from jsonb_array_elements(coalesce(p->'suchbegriffe', '[]'::jsonb)) r
     where r->>'suchbegriff' is not null and r->>'tag' is not null
    on conflict (quelle, tag, suchbegriff, seite, geraet) do update
       set klicks = excluded.klicks, impressionen = excluded.impressionen, position = excluded.position, abgerufen_am = now();
    get diagnostics n_sb = row_count;

    insert into analytics.suche_tage (quelle, tag, klicks, impressionen, position, abgerufen_am)
    select v_quelle, (r->>'tag')::date, coalesce((r->>'klicks')::integer, 0), coalesce((r->>'impressionen')::integer, 0), (r->>'position')::numeric, now()
      from jsonb_array_elements(coalesce(p->'tage', '[]'::jsonb)) r
     where r->>'tag' is not null
    on conflict (quelle, tag) do update
       set klicks = excluded.klicks, impressionen = excluded.impressionen, position = excluded.position, abgerufen_am = now();
    get diagnostics n_t = row_count;
  elsif v_quelle = 'ga4' then
    insert into analytics.ga4_tage (tag, nutzer, sitzungen, seitenaufrufe, abgerufen_am)
    select (r->>'tag')::date, coalesce((r->>'nutzer')::integer, 0), coalesce((r->>'sitzungen')::integer, 0), coalesce((r->>'seitenaufrufe')::integer, 0), now()
      from jsonb_array_elements(coalesce(p->'ga4', '[]'::jsonb)) r
     where r->>'tag' is not null
    on conflict (tag) do update
       set nutzer = excluded.nutzer, sitzungen = excluded.sitzungen, seitenaufrufe = excluded.seitenaufrufe, abgerufen_am = now();
    get diagnostics n_g = row_count;
  else
    raise exception 'unbekannte Quelle %', v_quelle;
  end if;

  insert into analytics.import_laeufe (quelle, zeilen, fehler)
  values (v_quelle, n_sb + n_t + n_g, nullif(p->>'fehler', ''));
  return jsonb_build_object('suchbegriffe', n_sb, 'tage', n_t, 'ga4', n_g);
end $$;

-- Auswertung für das Cockpit
create or replace function public.dashboard_suche(p_von date, p_bis date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'kennzahlen', (
      select coalesce(jsonb_object_agg(quelle, k), '{}'::jsonb) from (
        select quelle, jsonb_build_object(
                 'klicks', sum(klicks), 'impressionen', sum(impressionen),
                 'ctr', round(100.0 * sum(klicks) / nullif(sum(impressionen), 0), 1),
                 'position', round(sum(position * impressionen) / nullif(sum(impressionen) filter (where position is not null), 0), 1)) as k
          from analytics.suche_tage where tag between p_von and p_bis group by quelle) x),
    'verlauf', (
      select coalesce(jsonb_agg(jsonb_build_object('tag', t.tag::date, 'google', coalesce(g.klicks, 0), 'google_impr', coalesce(g.impressionen, 0),
                                                   'bing', coalesce(b.klicks, 0)) order by t.tag), '[]'::jsonb)
        from generate_series(p_von, p_bis, interval '1 day') as t(tag)
        left join analytics.suche_tage g on g.quelle = 'google' and g.tag = t.tag::date
        left join analytics.suche_tage b on b.quelle = 'bing' and b.tag = t.tag::date),
    'suchbegriffe', (
      select coalesce(jsonb_agg(z order by (z->>'impressionen')::int desc), '[]'::jsonb) from (
        select jsonb_build_object(
                 'quelle', quelle, 'suchbegriff', suchbegriff, 'klicks', sum(klicks), 'impressionen', sum(impressionen),
                 'ctr', round(100.0 * sum(klicks) / nullif(sum(impressionen), 0), 1),
                 'position', round(sum(position * impressionen) / nullif(sum(impressionen), 0), 1)) as z
          from analytics.suchbegriffe where tag between p_von and p_bis
         group by quelle, suchbegriff order by sum(impressionen) desc limit 200) x),
    'seiten', (
      select coalesce(jsonb_agg(z order by (z->>'impressionen')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('seite', regexp_replace(seite, '^https?://[^/]+', ''), 'klicks', sum(klicks), 'impressionen', sum(impressionen),
                                  'position', round(sum(position * impressionen) / nullif(sum(impressionen), 0), 1)) as z
          from analytics.suchbegriffe where quelle = 'google' and seite <> '' and tag between p_von and p_bis
         group by seite order by sum(impressionen) desc limit 30) x),
    'importe', (
      select coalesce(jsonb_agg(jsonb_build_object('quelle', quelle, 'gestartet', gestartet, 'zeilen', zeilen, 'fehler', fehler)), '[]'::jsonb) from (
        select distinct on (quelle) quelle, gestartet, zeilen, fehler
          from analytics.import_laeufe order by quelle, gestartet desc) x),
    'ga4', (
      select jsonb_build_object('nutzer', sum(nutzer), 'sitzungen', sum(sitzungen), 'seitenaufrufe', sum(seitenaufrufe), 'tage', count(*))
        from analytics.ga4_tage where tag between p_von and p_bis)
  )
$$;

revoke all on function public.ingest_suche(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_suche(jsonb) to service_role;
revoke all on function public.dashboard_suche(date, date) from public, anon, authenticated;
grant execute on function public.dashboard_suche(date, date) to service_role;
