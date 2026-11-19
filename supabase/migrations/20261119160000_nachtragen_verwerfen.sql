-- =====================================================================
-- Nachtrag-Vorschläge verwerfen (LinkedIn und Instagram)
-- Merkt sich die Zahl laut Buffer beim Verwerfen; kommen danach neue
-- Reaktionen dazu, erscheint der Vorschlag wieder.
-- =====================================================================

alter table core.linkedin_beitraege add column verworfen_bei integer;
create table core.instagram_verworfen (
  post_id text primary key references analytics.buffer_beitraege on delete cascade,
  bei     integer not null,
  am      timestamptz not null default now()
);
alter table core.instagram_verworfen enable row level security;
grant all on core.instagram_verworfen to service_role;

create or replace function public.dashboard_linkedin_verwerfen(p_beitrag_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update core.linkedin_beitraege set verworfen_bei = coalesce(reaktionen_laut_buffer, 0) where beitrag_id = p_beitrag_id;
  return found;
end $$;

create or replace function public.dashboard_instagram_verwerfen(p_post_id text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  insert into core.instagram_verworfen (post_id, bei)
  select b.post_id, coalesce(b.reaktionen, 0) from analytics.buffer_beitraege b where b.post_id = p_post_id and b.service = 'instagram'
  on conflict (post_id) do update set bei = excluded.bei, am = now();
  return found;
end $$;

create or replace function public.dashboard_linkedin()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with zaehl as (
    select x.person_id, count(*) filter (where x.was = 'r') as reaktionen, count(*) filter (where x.was = 'k') as kommentare,
           max(x.erfasst_am) as letzte,
           count(*) filter (where x.was = 'r' and x.kanal = 'firmenseite') as firmenseite,
           count(*) filter (where x.was = 'r' and x.kanal = 'daniel') as daniel
      from (select r.person_id, 'r' as was, r.erfasst_am, b.kanal
              from core.linkedin_reaktionen r join core.linkedin_beitraege b on b.beitrag_id = r.beitrag_id
             where b.zugehoerigkeit = 'sofortsichtbar'
            union all
            select k.person_id, 'k', k.erfasst_am, b.kanal
              from core.linkedin_kommentare k join core.linkedin_beitraege b on b.beitrag_id = k.beitrag_id
             where b.zugehoerigkeit = 'sofortsichtbar') x
     group by x.person_id
  ), kontaktnamen as (
    select lower(concat_ws(' ', c.vorname, c.nachname)) as k, min(c.contact_id::text)::uuid as contact_id, count(*) as n
      from core.contacts c where c.vorname is not null
     group by 1
  ), beitr as (
    select b.*, bb.impressionen, bb.reichweite, bb.engagement_rate,
           (select count(*) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id) as erfasst,
           (select count(*) from core.linkedin_kommentare k where k.beitrag_id = b.beitrag_id) as kommentare_erfasst,
           (select max(r.erfasst_am) from core.linkedin_reaktionen r where r.beitrag_id = b.beitrag_id) as zuletzt_erfasst
      from core.linkedin_beitraege b
      left join analytics.buffer_beitraege bb on bb.post_id = b.buffer_post_id
     where b.zugehoerigkeit = 'sofortsichtbar'
  )
  select jsonb_build_object(
    'beitraege', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'beitrag_id', b.beitrag_id, 'kanal', b.kanal, 'titel', b.titel, 'url', b.url, 'veroeffentlicht', b.veroeffentlicht,
               'erfasst', b.erfasst, 'weitere', b.weitere_reaktionen, 'zuletzt_erfasst', b.zuletzt_erfasst,
               'kommentare_erfasst', b.kommentare_erfasst,
               'laut_buffer', b.reaktionen_laut_buffer, 'kommentare_laut_buffer', b.kommentare_laut_buffer, 'buffer_stand', b.buffer_stand,
               'impressionen', b.impressionen, 'engagement_rate', b.engagement_rate, 'aus_buffer', b.buffer_post_id is not null,
               'fehlen', greatest(coalesce(b.reaktionen_laut_buffer, 0) - b.erfasst - b.weitere_reaktionen, 0),
               'verworfen', b.verworfen_bei is not null and coalesce(b.reaktionen_laut_buffer, 0) <= b.verworfen_bei,
               'beobachtet', b.erfasst > 0 or b.weitere_reaktionen > 0 or b.veroeffentlicht >= current_date - 30 or b.buffer_post_id is null)
             order by coalesce(b.veroeffentlicht, b.created_at::date) desc, b.created_at desc), '[]'::jsonb)
        from beitr b),
    'ausgeblendet', (
      select jsonb_build_object(
        'unklar', count(*) filter (where b.zugehoerigkeit = 'unklar'),
        'empiria', count(*) filter (where b.zugehoerigkeit = 'empiria'),
        'beitraege', coalesce(jsonb_agg(jsonb_build_object(
                       'beitrag_id', b.beitrag_id, 'titel', b.titel, 'url', b.url, 'veroeffentlicht', b.veroeffentlicht,
                       'zugehoerigkeit', b.zugehoerigkeit, 'laut_buffer', b.reaktionen_laut_buffer)
                     order by b.veroeffentlicht desc nulls last) filter (where b.zugehoerigkeit = 'unklar'), '[]'::jsonb))
        from core.linkedin_beitraege b where b.zugehoerigkeit <> 'sofortsichtbar'),
    'buffer', (
      select jsonb_build_object('stand', max(kennzahlen_stand), 'abgerufen', max(abgerufen_am), 'beitraege', count(*))
        from analytics.buffer_beitraege),
    'import', (
      select jsonb_build_object('gestartet', gestartet, 'zeilen', zeilen, 'fehler', fehler)
        from analytics.import_laeufe where quelle = 'buffer' order by gestartet desc limit 1),
    'personen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'person_id', p.person_id, 'name', p.name, 'position', p.position, 'ignoriert', p.ignoriert, 'typ', p.typ,
               'reaktionen', z.reaktionen, 'kommentare', z.kommentare, 'firmenseite', z.firmenseite, 'daniel', z.daniel, 'letzte', z.letzte,
               'kontakt', case when c.contact_id is not null then jsonb_build_object(
                            'contact_id', c.contact_id, 'name', nullif(concat_ws(' ', c.vorname, c.nachname), ''), 'email', c.email,
                            'stufe', c.lifecycle_stage) end,
               'vorschlag', case when c.contact_id is null and not p.ignoriert and p.typ = 'person' and kn.n = 1 then jsonb_build_object(
                            'contact_id', kv.contact_id, 'name', concat_ws(' ', kv.vorname, kv.nachname), 'email', kv.email) end)
             order by z.reaktionen + 2 * z.kommentare desc, z.letzte desc), '[]'::jsonb)
        from core.linkedin_personen p
        join zaehl z on z.person_id = p.person_id
        left join core.contacts c on c.contact_id = p.contact_id
        left join kontaktnamen kn on kn.k = regexp_replace(p.schluessel, ',.*$', '')
        left join core.contacts kv on kv.contact_id = kn.contact_id)
  )
$$;

create or replace function public.dashboard_instagram()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with b as (
    select b.*,
           (select count(*) from core.instagram_likes l where l.post_id = b.post_id) as erfasst,
           (select count(*) from core.instagram_kommentare k where k.post_id = b.post_id) as kommentare_erfasst
      from analytics.buffer_beitraege b where b.service = 'instagram'
  ), z as (
    select x.person_id, count(*) filter (where x.was = 'l') as likes, count(*) filter (where x.was = 'k') as kommentare, max(x.zeit) as letzte
      from (select person_id, 'l' as was, erfasst_am as zeit from core.instagram_likes
            union all select person_id, 'k', erfasst_am from core.instagram_kommentare
            union all select person_id, 'f', follower_seit::timestamptz from core.instagram_personen where follower_seit is not null) x
     group by x.person_id
  )
  select jsonb_build_object(
    'beitraege', (select coalesce(jsonb_agg(jsonb_build_object(
        'post_id', b.post_id, 'url', b.link, 'veroeffentlicht', b.gesendet,
        'titel', coalesce(nullif(left(regexp_replace(split_part(trim(coalesce(b.text, '')), E'\n', 1), '\s+', ' ', 'g'), 90), ''), 'Beitrag'),
        'likes', b.reaktionen, 'kommentare', b.kommentare, 'impressionen', b.impressionen, 'reichweite', b.reichweite,
        'erfasst', b.erfasst, 'kommentare_erfasst', b.kommentare_erfasst,
        'fehlen', case when b.erfasst > 0 or b.gesendet >= timestamptz '2026-11-18' then greatest(coalesce(b.reaktionen, 0) - b.erfasst, 0) else 0 end,
        'verworfen', exists (select 1 from core.instagram_verworfen v where v.post_id = b.post_id and coalesce(b.reaktionen, 0) <= v.bei),
        'beobachtet', b.erfasst > 0 or b.gesendet >= timestamptz '2026-11-18')
      order by b.gesendet desc), '[]'::jsonb) from b),
    'personen', (select coalesce(jsonb_agg(jsonb_build_object(
        'person_id', p.person_id, 'benutzername', p.benutzername, 'name', p.name, 'ignoriert', p.ignoriert,
        'follower', p.follower_seit is not null, 'likes', z.likes, 'kommentare', z.kommentare, 'letzte', z.letzte,
        'kontakt', case when c.contact_id is not null then jsonb_build_object('contact_id', c.contact_id,
                     'name', coalesce(nullif(concat_ws(' ', c.vorname, c.nachname), ''), co.name), 'email', c.email, 'stufe', c.lifecycle_stage) end)
      order by z.likes + 2 * z.kommentare desc, z.letzte desc), '[]'::jsonb)
      from core.instagram_personen p join z on z.person_id = p.person_id
      left join core.contacts c on c.contact_id = p.contact_id
      left join core.companies co on co.company_id = c.company_id),
    'follower', (select count(*) from core.instagram_personen where follower_seit is not null and not ignoriert),
    'buffer', (select jsonb_build_object('stand', max(kennzahlen_stand), 'abgerufen', max(abgerufen_am))
                 from analytics.buffer_beitraege where service = 'instagram')
  )
$$;

do $$
declare f text;
begin
  foreach f in array array['public.dashboard_linkedin_verwerfen(uuid)', 'public.dashboard_instagram_verwerfen(text)',
                           'public.dashboard_linkedin()', 'public.dashboard_instagram()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
