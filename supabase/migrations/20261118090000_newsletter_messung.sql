-- =====================================================================
-- Newsletter: mehr Messung
--
-- 1) Öffnungen über ein Zählpixel (/o/<token> auf sofortsichtbar.de).
--    NUR für Empfänger mit Einwilligung (newsletter_grundlage = 'einwilligung')
--    und bei Testmails. Bestandskunden (§ 7 Abs. 3 UWG) bekommen nie ein
--    Pixel – dafür fehlt die Einwilligung nach § 25 TDDDG.
--    Jede Öffnung wird gezählt (mehrfach öffnen sichtbar). Maschinelle
--    Abrufe werden markiert: Apple Mail lädt Bilder vorab über eigene
--    Server (Mail Privacy Protection), Scanner öffnen Sekunden nach Versand.
-- 2) Klick → Website: Der Klick hängt einen einmaligen Schlüssel (nlk) an
--    Links zu sofortsichtbar.de. Hat der Besucher dort der Statistik
--    zugestimmt, verknüpft die Website seine visitor_id mit dem Kontakt
--    (newsletter_besucher). Ab dann stehen seine Besuche im Verlauf.
-- 3) Auswertung: Öffnungsrate, Mehrfachöffnungen, Website-Besuche über den
--    Newsletter (UTM) und Seiten je Empfänger nach dem Versand.
-- =====================================================================

alter table core.newsletter add column oeffnungen_messen boolean not null default true;
alter table core.newsletter_empfaenger add column pixel boolean not null default false;
alter table core.newsletter_klicks add column schluessel uuid not null default gen_random_uuid();
create unique index newsletter_klicks_schluessel on core.newsletter_klicks (schluessel);

create table core.newsletter_oeffnungen (
  oeffnung_id   bigint generated always as identity primary key,
  empfaenger_id bigint not null references core.newsletter_empfaenger on delete cascade,
  zeit          timestamptz not null default now(),
  -- mensch = echte Öffnung, apple = Vorabruf durch Apple Mail (unsicher),
  -- vorab = Sekunden nach Versand (Scanner), scanner = Bot-Kennung
  art           text not null check (art in ('mensch', 'apple', 'vorab', 'scanner'))
);
create index newsletter_oeffnungen_empfaenger on core.newsletter_oeffnungen (empfaenger_id);
alter table core.newsletter_oeffnungen enable row level security;
grant all on core.newsletter_oeffnungen to service_role;

-- Gleiche Regel wie slug() in nl-render.js – für die UTM-Auswertung
create or replace function core.nl_slug(p text)
returns text language sql immutable set search_path = '' as $$
  select coalesce(nullif(left(regexp_replace(regexp_replace(
           replace(replace(replace(replace(lower(coalesce(nullif(p, ''), 'newsletter')), 'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss'),
           '[^a-z0-9]+', '-', 'g'), '^-+|-+$', '', 'g'), 60), ''), 'newsletter')
$$;

-- ---------------------------------------------------------------------
-- Versand: Pixel nur bei Einwilligung (oder Test)
-- ---------------------------------------------------------------------
create or replace function public.newsletter_versand_holen(p_max integer)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  update core.newsletter_empfaenger e set status = 'uebersprungen', fehler = 'gesperrt'
   where e.status = 'wartet' and core.newsletter_gesperrt(e.email);

  with zug as (
    select e.empfaenger_id
      from core.newsletter_empfaenger e
      join core.newsletter n on n.newsletter_id = e.newsletter_id
     where (e.status = 'wartet' or (e.status = 'in_arbeit' and e.gesperrt_bis < now()))
       and e.versuche < 3
       and (e.test or n.status = 'wird_gesendet')
     order by e.test desc, e.created_at
     limit greatest(least(p_max, 200), 1)
     for update of e skip locked
  ), upd as (
    update core.newsletter_empfaenger e
       set status = 'in_arbeit', gesperrt_bis = now() + interval '5 minutes', versuche = e.versuche + 1,
           pixel = (select n.oeffnungen_messen from core.newsletter n where n.newsletter_id = e.newsletter_id)
                   and (e.test or exists (select 1 from core.contacts c where c.contact_id = e.contact_id
                                                                         and c.newsletter_grundlage = 'einwilligung'))
      from zug where e.empfaenger_id = zug.empfaenger_id
    returning e.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'empfaenger_id', u.empfaenger_id, 'token', u.token, 'email', u.email, 'test', u.test, 'pixel', u.pixel,
           'kontakt', jsonb_build_object('titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname,
                                         'firma', co.name, 'position', c.position),
           'newsletter', jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff, 'vorschautext', n.vorschautext,
                                            'inhalt', n.inhalt, 'klicks_messen', n.klicks_messen, 'utm', n.utm,
                                            'utm_kampagne', coalesce(nullif(trim(n.utm_kampagne), ''), n.titel)))), '[]'::jsonb)
    into v
    from upd u
    join core.newsletter n on n.newsletter_id = u.newsletter_id
    left join core.contacts c on c.contact_id = u.contact_id
    left join core.companies co on co.company_id = c.company_id;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Öffnung (vom Pixel-Endpunkt der Website)
-- ---------------------------------------------------------------------
create or replace function public.newsletter_oeffnung(p_token text, p_ua text default null, p_apple boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare e core.newsletter_empfaenger; n core.newsletter; v_art text;
begin
  select * into e from core.newsletter_empfaenger where token = p_token;
  if not found or not e.pixel then return; end if;
  if (select count(*) from core.newsletter_oeffnungen o where o.empfaenger_id = e.empfaenger_id) >= 200 then return; end if;
  v_art := case
    when p_apple then 'apple'
    when p_ua is null or p_ua ~* '(bot|crawl|spider|scan|safelinks|proofpoint|mimecast|barracuda|python|curl|wget|headless)' then 'scanner'
    when e.gesendet_am is not null and now() - e.gesendet_am < interval '30 seconds' then 'vorab'
    else 'mensch' end;
  insert into core.newsletter_oeffnungen (empfaenger_id, art) values (e.empfaenger_id, v_art);
  if v_art = 'mensch' and not e.test and e.contact_id is not null then
    select * into n from core.newsletter where newsletter_id = e.newsletter_id;
    insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
    values ('nl:' || e.empfaenger_id || ':open', 'email_open', now(), e.contact_id, 'newsletter',
            jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff), 'granted')
    on conflict (event_id) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Klick: wie bisher, plus Schlüssel nlk an Links zur eigenen Website
-- ---------------------------------------------------------------------
create or replace function public.newsletter_klick(p_token text, p_nr integer, p_ua text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare e core.newsletter_empfaenger; n core.newsletter; v_url text; v_bot boolean; v_s uuid; v_hash text := ''; v_i integer;
begin
  select * into e from core.newsletter_empfaenger where token = p_token;
  if not found then return null; end if;
  select * into n from core.newsletter where newsletter_id = e.newsletter_id;
  v_url := n.links->>p_nr;
  if v_url is null then return null; end if;
  if not n.klicks_messen then return v_url; end if;
  v_bot := p_ua is null or p_ua ~* '(bot|crawl|spider|preview|scan|safelinks|proofpoint|mimecast|barracuda|python|curl|wget|headless)'
           or (e.gesendet_am is not null and now() - e.gesendet_am < interval '20 seconds');
  insert into core.newsletter_klicks (empfaenger_id, link_nr, url, verdacht_bot) values (e.empfaenger_id, p_nr, v_url, v_bot)
  returning schluessel into v_s;
  if not v_bot and not e.test and e.contact_id is not null then
    insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
    values ('nl:' || e.empfaenger_id || ':click:' || p_nr, 'email_click', now(), e.contact_id, 'newsletter',
            jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff, 'url', v_url, 'link_nr', p_nr), 'not_required')
    on conflict (event_id) do nothing;
  end if;
  -- Schlüssel nur für echte Klicks auf die eigene Website
  if not v_bot and e.contact_id is not null and v_url ~* '^https?://([a-z0-9-]+\.)*sofortsichtbar\.de(/|$|\?|#)' then
    v_i := strpos(v_url, '#');
    if v_i > 0 then v_hash := substr(v_url, v_i); v_url := left(v_url, v_i - 1); end if;
    v_url := v_url || case when strpos(v_url, '?') > 0 then '&' else '?' end || 'nlk=' || v_s || v_hash;
  end if;
  return v_url;
end $$;

-- ---------------------------------------------------------------------
-- Website meldet: Besucher (mit Statistik-Einwilligung) kam über diesen Klick.
-- Schlüssel gilt 2 Stunden. Gehört die visitor_id schon jemandem, bleibt es so.
-- ---------------------------------------------------------------------
create or replace function public.newsletter_besucher(p_schluessel uuid, p_visitor text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_contact uuid; v_neu integer;
begin
  if p_visitor !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  select e.contact_id into v_contact
    from core.newsletter_klicks k join core.newsletter_empfaenger e on e.empfaenger_id = k.empfaenger_id
   where k.schluessel = p_schluessel and not k.verdacht_bot and not e.test and k.zeit > now() - interval '2 hours';
  if v_contact is null then return false; end if;
  insert into core.identities (contact_id, identity_type, identity_value, confidence, source)
  values (v_contact, 'visitor_id', lower(p_visitor), 'confirmed', 'newsletter_klick')
  on conflict (identity_type, identity_value) do nothing;
  get diagnostics v_neu = row_count;
  return v_neu > 0;
end $$;

-- ---------------------------------------------------------------------
-- Speichern: neues Feld oeffnungen_messen
-- ---------------------------------------------------------------------
create or replace function public.dashboard_newsletter_speichern(p jsonb, p_von text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid := nullif(p->>'newsletter_id', '')::uuid;
  v_listen text[] := coalesce((select array_agg(distinct lower(trim(t))) filter (where trim(t) <> '')
                                 from jsonb_array_elements_text(coalesce(p->'listen', '[]'::jsonb)) t), '{}');
begin
  if v_id is null then
    insert into core.newsletter (titel, betreff, vorschautext, inhalt, listen, klicks_messen, oeffnungen_messen, utm, utm_kampagne, erstellt_von, geaendert_von)
    values (coalesce(nullif(trim(p->>'titel'), ''), 'Neuer Newsletter'), coalesce(p->>'betreff', ''), coalesce(p->>'vorschautext', ''),
            coalesce(p->>'inhalt', ''), v_listen, coalesce((p->>'klicks_messen')::boolean, true), coalesce((p->>'oeffnungen_messen')::boolean, true),
            coalesce((p->>'utm')::boolean, true), nullif(trim(p->>'utm_kampagne'), ''), p_von, p_von)
    returning newsletter_id into v_id;
    return v_id;
  end if;
  update core.newsletter
     set titel = coalesce(nullif(trim(p->>'titel'), ''), titel), betreff = coalesce(p->>'betreff', ''),
         vorschautext = coalesce(p->>'vorschautext', ''), inhalt = coalesce(p->>'inhalt', ''), listen = v_listen,
         klicks_messen = coalesce((p->>'klicks_messen')::boolean, true),
         oeffnungen_messen = coalesce((p->>'oeffnungen_messen')::boolean, true),
         utm = coalesce((p->>'utm')::boolean, true),
         utm_kampagne = nullif(trim(p->>'utm_kampagne'), ''), geaendert_von = p_von
   where newsletter_id = v_id and status = 'entwurf';
  if not found then raise exception 'Nur Entwürfe lassen sich bearbeiten'; end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Zielgruppe: zusätzlich, wie viele davon ein Pixel bekämen
-- ---------------------------------------------------------------------
create or replace function public.dashboard_newsletter_zielgruppe(p_listen text[])
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'anzahl', (select count(*) from core.newsletter_zielgruppe(p_listen)),
    'mit_einwilligung', (select count(*) from core.newsletter_zielgruppe(p_listen) z
                           join core.contacts c on c.contact_id = z.contact_id where c.newsletter_grundlage = 'einwilligung'),
    'beispiel', (select jsonb_build_object('titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname, 'email', c.email,
                                           'firma', co.name, 'position', c.position)
                   from core.newsletter_zielgruppe(p_listen) z
                   join core.contacts c on c.contact_id = z.contact_id
                   left join core.companies co on co.company_id = c.company_id
                  order by (c.vorname is null), c.nachname limit 1))
$$;

-- ---------------------------------------------------------------------
-- Auswertung eines Newsletters
-- ---------------------------------------------------------------------
create or replace function public.dashboard_newsletter(p_newsletter_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with n as (select * from core.newsletter where newsletter_id = p_newsletter_id),
  e as (
    select e.*,
           (select count(*) from core.newsletter_klicks k where k.empfaenger_id = e.empfaenger_id and not k.verdacht_bot) as klicks,
           (select count(*) from core.newsletter_oeffnungen o where o.empfaenger_id = e.empfaenger_id and o.art = 'mensch') as oeffnungen,
           (select count(*) from core.newsletter_oeffnungen o where o.empfaenger_id = e.empfaenger_id and o.art = 'apple') as apple,
           (select min(o.zeit) from core.newsletter_oeffnungen o where o.empfaenger_id = e.empfaenger_id and o.art = 'mensch') as erste_oeffnung,
           (select count(*) from core.events ev where ev.contact_id = e.contact_id and ev.source = 'website' and ev.event_name = 'page_view'
                                                  and e.gesendet_am is not null and ev.occurred_at >= e.gesendet_am
                                                  and ev.occurred_at < e.gesendet_am + interval '30 days') as website_seiten
      from core.newsletter_empfaenger e where e.newsletter_id = p_newsletter_id
  ),
  -- Website-Besuche über den Newsletter (UTM, auch ohne Personenbezug)
  web as (
    select ev.* from core.events ev, n
     where ev.source = 'website' and ev.event_name = 'page_view' and n.freigegeben_am is not null
       and ev.occurred_at >= n.freigegeben_am - interval '1 hour'
       and ev.page_url ~ '[?&]utm_source=newsletter(&|$)'
       and ev.page_url ~ ('[?&]utm_campaign=' || core.nl_slug(coalesce(nullif(trim(n.utm_kampagne), ''), n.titel)) || '(&|$)')
  ),
  sitzungen as (
    select ev.session_id, count(*) filter (where ev.event_name = 'page_view') as seiten,
           extract(epoch from max(ev.occurred_at) - min(ev.occurred_at)) as sekunden
      from core.events ev
     where ev.session_id in (select session_id from web where session_id is not null) and ev.source = 'website'
     group by ev.session_id
  )
  select jsonb_build_object(
    'newsletter', (select to_jsonb(n) from n),
    'zahlen', (select jsonb_build_object(
                 'empfaenger', count(*), 'wartet', count(*) filter (where status in ('wartet', 'in_arbeit')),
                 'versendet', count(*) filter (where status in ('gesendet', 'zugestellt', 'bounce', 'beschwerde')),
                 'zugestellt', count(*) filter (where status = 'zugestellt'),
                 'bounces', count(*) filter (where status = 'bounce'), 'beschwerden', count(*) filter (where status = 'beschwerde'),
                 'fehler', count(*) filter (where status = 'fehler'), 'uebersprungen', count(*) filter (where status = 'uebersprungen'),
                 'abmeldungen', count(*) filter (where abgemeldet_am is not null),
                 'klicker', count(*) filter (where klicks > 0), 'klicks', coalesce(sum(klicks), 0),
                 -- Öffnungen: Basis sind nur Empfänger mit Pixel; ein Klick zählt auch als geöffnet
                 'mit_pixel', count(*) filter (where pixel and status in ('gesendet', 'zugestellt')),
                 'geoeffnet', count(*) filter (where pixel and status in ('gesendet', 'zugestellt') and (oeffnungen > 0 or klicks > 0)),
                 'nur_apple', count(*) filter (where pixel and oeffnungen = 0 and klicks = 0 and apple > 0),
                 'oeffnungen', coalesce(sum(oeffnungen), 0),
                 'mehrfach', count(*) filter (where oeffnungen >= 2),
                 'website_personen', count(*) filter (where website_seiten > 0))
                 from e where not e.test),
    'website', (select jsonb_build_object(
                  'besuche', (select count(*) from web),
                  'mit_sitzung', (select count(*) from sitzungen),
                  'seiten', (select coalesce(sum(seiten), 0) from sitzungen),
                  'sekunden_median', (select percentile_cont(0.5) within group (order by sekunden) from sitzungen))),
    'links', (select coalesce(jsonb_agg(jsonb_build_object('nr', l.nr - 1, 'url', l.url,
                        'klicks', (select count(*) from core.newsletter_klicks k join e on e.empfaenger_id = k.empfaenger_id
                                    where k.link_nr = l.nr - 1 and not k.verdacht_bot and not e.test),
                        'personen', (select count(distinct k.empfaenger_id) from core.newsletter_klicks k join e on e.empfaenger_id = k.empfaenger_id
                                      where k.link_nr = l.nr - 1 and not k.verdacht_bot and not e.test)) order by l.nr), '[]'::jsonb)
                from n, jsonb_array_elements_text(n.links) with ordinality l(url, nr)),
    'empfaenger', (select coalesce(jsonb_agg(jsonb_build_object(
                     'contact_id', e.contact_id, 'email', e.email, 'status', e.status, 'klicks', e.klicks,
                     'pixel', e.pixel, 'oeffnungen', e.oeffnungen, 'apple', e.apple > 0, 'erste_oeffnung', e.erste_oeffnung,
                     'website_seiten', e.website_seiten,
                     'gesendet_am', e.gesendet_am, 'abgemeldet', e.abgemeldet_am is not null, 'fehler', e.fehler,
                     'name', nullif(concat_ws(' ', c.titel, c.vorname, c.nachname), ''))
                     order by e.klicks desc, e.oeffnungen desc, e.website_seiten desc, e.email), '[]'::jsonb)
                     from (select * from e where not e.test order by klicks desc, oeffnungen desc, email limit 3000) e
                     left join core.contacts c on c.contact_id = e.contact_id),
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('email', e.email, 'status', e.status, 'zeit', e.created_at, 'fehler', e.fehler,
                                                           'oeffnungen', e.oeffnungen + e.apple, 'klicks', e.klicks)
                                        order by e.created_at desc), '[]'::jsonb)
                from (select * from e where e.test order by created_at desc limit 10) e)
  )
  where exists (select 1 from n)
$$;

-- Übersicht: Öffnungsrate je Newsletter
create or replace function public.dashboard_newsletter_uebersicht()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'newsletter', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'newsletter_id', n.newsletter_id, 'titel', n.titel, 'betreff', n.betreff, 'status', n.status,
               'listen', n.listen, 'gesendet_am', n.gesendet_am, 'freigegeben_am', n.freigegeben_am, 'updated_at', n.updated_at,
               'empfaenger', (select count(*) from core.newsletter_empfaenger e where e.newsletter_id = n.newsletter_id and not e.test),
               'versendet', (select count(*) from core.newsletter_empfaenger e where e.newsletter_id = n.newsletter_id and not e.test
                                                                               and e.status in ('gesendet', 'zugestellt', 'bounce', 'beschwerde')),
               'klicker', (select count(distinct e.empfaenger_id) from core.newsletter_empfaenger e
                             join core.newsletter_klicks k on k.empfaenger_id = e.empfaenger_id and not k.verdacht_bot
                            where e.newsletter_id = n.newsletter_id and not e.test),
               'mit_pixel', (select count(*) from core.newsletter_empfaenger e where e.newsletter_id = n.newsletter_id and not e.test
                                                                               and e.pixel and e.status in ('gesendet', 'zugestellt')),
               'geoeffnet', (select count(*) from core.newsletter_empfaenger e where e.newsletter_id = n.newsletter_id and not e.test
                                and e.pixel and e.status in ('gesendet', 'zugestellt')
                                and (exists (select 1 from core.newsletter_oeffnungen o where o.empfaenger_id = e.empfaenger_id and o.art = 'mensch')
                                     or exists (select 1 from core.newsletter_klicks k where k.empfaenger_id = e.empfaenger_id and not k.verdacht_bot))),
               'abmeldungen', (select count(*) from core.newsletter_empfaenger e where e.newsletter_id = n.newsletter_id and not e.test
                                                                                  and e.abgemeldet_am is not null))
             order by coalesce(n.gesendet_am, n.freigegeben_am, n.updated_at) desc), '[]'::jsonb)
        from core.newsletter n),
    'listen', (
      select coalesce(jsonb_agg(jsonb_build_object('liste', t, 'kontakte', n, 'erlaubt', e) order by e desc, t), '[]'::jsonb)
        from (select t, count(*) as n,
                     count(*) filter (where c.newsletter_erlaubt and c.email is not null
                                        and not exists (select 1 from core.newsletter_sperre s where s.email = c.email)) as e
                from core.contacts c cross join lateral unnest(c.tags) t group by t) x),
    'erlaubt_gesamt', (select count(*) from core.newsletter_zielgruppe('{}')),
    'gesperrt', (select count(*) from core.newsletter_sperre),
    'status', (select to_jsonb(s) - 'id' from analytics.newsletter_status s)
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.newsletter_oeffnung(text, text, boolean)', 'public.newsletter_besucher(uuid, text)',
                           'public.newsletter_klick(text, integer, text)', 'public.newsletter_versand_holen(integer)',
                           'public.dashboard_newsletter_speichern(jsonb, text)', 'public.dashboard_newsletter_zielgruppe(text[])',
                           'public.dashboard_newsletter(uuid)', 'public.dashboard_newsletter_uebersicht()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
