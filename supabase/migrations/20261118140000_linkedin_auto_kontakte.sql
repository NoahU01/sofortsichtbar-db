-- =====================================================================
-- LinkedIn: Personen automatisch Kontakten zuordnen oder als Kontakt anlegen
--
-- Wer auf einen sofort-sichtbar-Beitrag reagiert oder ihn kommentiert und
-- nicht auf der Ausschlussliste steht:
--   - genau ein Kontakt mit gleichem Vor- und Nachnamen → zuordnen
--   - kein Kontakt → neuer Kontakt (Herkunft linkedin_reaktion, Newsletter: Nein,
--     Position leer – die LinkedIn-Headline bleibt in der LinkedIn-Personenliste)
--   - mehrere gleichnamige Kontakte → bleibt zur Entscheidung im Cockpit
-- Unternehmensseiten werden nie Kontakte. Namenszusätze wie „, LL.M.“ oder
-- Emojis werden für den Abgleich entfernt.
-- =====================================================================

create or replace function core.linkedin_name_sauber(p text)
returns text language sql immutable set search_path = '' as $$
  select nullif(trim(regexp_replace(
           regexp_replace(regexp_replace(coalesce(p, ''), ',.*$', ''),
                          '[©®™‍️←-⯿\U0001F000-\U0001FAFF|•]', '', 'g'),
           '\s+', ' ', 'g')), '')
$$;

create or replace function core.linkedin_auto_zuordnen(p_beitrag_id uuid default null)
returns jsonb
language plpgsql set search_path = ''
as $$
declare r record; z record; v_key text; v_n integer; v_c uuid; n_zu integer := 0; n_neu integer := 0; n_mehr integer := 0;
begin
  for r in
    select p.* from core.linkedin_personen p
     where not p.ignoriert and p.typ = 'person' and p.contact_id is null
       and (exists (select 1 from core.linkedin_reaktionen x join core.linkedin_beitraege b on b.beitrag_id = x.beitrag_id
                     where x.person_id = p.person_id and b.zugehoerigkeit = 'sofortsichtbar' and (p_beitrag_id is null or x.beitrag_id = p_beitrag_id))
         or exists (select 1 from core.linkedin_kommentare x join core.linkedin_beitraege b on b.beitrag_id = x.beitrag_id
                     where x.person_id = p.person_id and b.zugehoerigkeit = 'sofortsichtbar' and (p_beitrag_id is null or x.beitrag_id = p_beitrag_id)))
  loop
    select * into z from core.name_zerlegen(core.linkedin_name_sauber(r.name));
    if z.vorname is null or z.nachname is null then continue; end if;
    v_key := lower(concat_ws(' ', z.vorname, z.nachname));
    select count(*), min(c.contact_id::text)::uuid into v_n, v_c
      from core.contacts c where lower(concat_ws(' ', c.vorname, c.nachname)) = v_key;
    if v_n > 1 then n_mehr := n_mehr + 1; continue; end if;
    if v_n = 0 then
      insert into core.contacts (titel, vorname, nachname, herkunft, tags)
      values (z.titel, z.vorname, z.nachname, 'linkedin_reaktion',
              case when r.follower_seit is not null then array['linkedin_follower'] else '{}'::text[] end)
      returning contact_id into v_c;
      n_neu := n_neu + 1;
    else
      n_zu := n_zu + 1;
    end if;
    perform public.dashboard_linkedin_person(r.person_id, 'zuordnen', v_c);
  end loop;
  return jsonb_build_object('zugeordnet', n_zu, 'angelegt', n_neu, 'mehrdeutig', n_mehr);
end $$;

create or replace function public.dashboard_linkedin_erfassen(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_beitrag uuid := nullif(p->>'beitrag_id', '')::uuid;
  v_url     text := nullif(trim(p#>>'{beitrag,url}'), '');
  v_liste   jsonb; v_komm jsonb;
  v_gesamt  integer; v_neu_p integer; v_neu_r integer; v_neu_k integer; v_auto jsonb;
begin
  -- Beitrag ohne Buffer anlegen: nur noch intern (die Cockpit-Bridge lässt es nicht mehr zu)
  if v_beitrag is null and p ? 'beitrag' and jsonb_typeof(p->'beitrag') = 'object' then
    if v_url is not null then select beitrag_id into v_beitrag from core.linkedin_beitraege where url = v_url; end if;
    if v_beitrag is null then
      insert into core.linkedin_beitraege (kanal, titel, url, veroeffentlicht, angelegt_von)
      values (p#>>'{beitrag,kanal}', coalesce(nullif(trim(p#>>'{beitrag,titel}'), ''), 'Beitrag'), v_url,
              nullif(p#>>'{beitrag,veroeffentlicht}', '')::date, p_von)
      returning beitrag_id into v_beitrag;
    end if;
  end if;
  if v_beitrag is null or not exists (select 1 from core.linkedin_beitraege where beitrag_id = v_beitrag) then
    raise exception 'Beitrag nicht gefunden';
  end if;

  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_liste from (
    select distinct on (core.linkedin_schluessel(x->>'name'))
           core.linkedin_schluessel(x->>'name') as schluessel, left(trim(x->>'name'), 200) as name,
           left(nullif(trim(x->>'position'), ''), 300) as position,
           case when x->>'art' in ('like', 'celebrate', 'support', 'love', 'insightful', 'funny') then x->>'art' else 'reaktion' end as art,
           case when x->>'typ' = 'seite' then 'seite' else 'person' end as typ
      from jsonb_array_elements(coalesce(p->'personen', '[]'::jsonb)) x
     where nullif(trim(x->>'name'), '') is not null) z;
  v_gesamt := jsonb_array_length(v_liste);

  select coalesce(jsonb_agg(z), '[]'::jsonb) into v_komm from (
    select core.linkedin_schluessel(x->>'name') as schluessel, left(trim(x->>'name'), 200) as name,
           left(nullif(trim(x->>'text'), ''), 5000) as text,
           case when x->>'typ' = 'seite' then 'seite' else 'person' end as typ,
           row_number() over (partition by core.linkedin_schluessel(x->>'name') order by o)::integer as nr
      from jsonb_array_elements(coalesce(p->'kommentare', '[]'::jsonb)) with ordinality t(x, o)
     where nullif(trim(x->>'name'), '') is not null) z;

  select count(*) filter (where lp.person_id is null), count(*) filter (where r.person_id is null)
    into v_neu_p, v_neu_r
    from jsonb_to_recordset(v_liste) n(schluessel text)
    left join core.linkedin_personen lp on lp.schluessel = n.schluessel
    left join core.linkedin_reaktionen r on r.person_id = lp.person_id and r.beitrag_id = v_beitrag;

  select count(*) filter (where k.person_id is null) into v_neu_k
    from jsonb_to_recordset(v_komm) n(schluessel text, nr integer)
    left join core.linkedin_personen lp on lp.schluessel = n.schluessel
    left join core.linkedin_kommentare k on k.person_id = lp.person_id and k.beitrag_id = v_beitrag and k.nr = n.nr;

  insert into core.linkedin_personen (schluessel, name, position, typ)
  select n.schluessel, n.name, n.position, n.typ from jsonb_to_recordset(v_liste) n(schluessel text, name text, position text, typ text)
  union all
  select distinct on (n.schluessel) n.schluessel, n.name, null, n.typ from jsonb_to_recordset(v_komm) n(schluessel text, name text, typ text)
   where not exists (select 1 from jsonb_to_recordset(v_liste) l(schluessel text) where l.schluessel = n.schluessel)
  on conflict (schluessel) do update
     set position = coalesce(excluded.position, core.linkedin_personen.position), zuletzt = now(),
         typ = case when excluded.typ = 'seite' then 'seite' else core.linkedin_personen.typ end;

  insert into core.linkedin_reaktionen (beitrag_id, person_id, art)
  select v_beitrag, lp.person_id, n.art
    from jsonb_to_recordset(v_liste) n(schluessel text, art text)
    join core.linkedin_personen lp on lp.schluessel = n.schluessel
  on conflict (beitrag_id, person_id) do update set art = excluded.art;

  insert into core.linkedin_kommentare (beitrag_id, person_id, nr, text, erfasst_von)
  select v_beitrag, lp.person_id, least(n.nr, 50), n.text, p_von
    from jsonb_to_recordset(v_komm) n(schluessel text, nr integer, text text)
    join core.linkedin_personen lp on lp.schluessel = n.schluessel
  on conflict (beitrag_id, person_id, nr) do update set text = coalesce(excluded.text, core.linkedin_kommentare.text);

  update core.linkedin_beitraege
     set weitere_reaktionen = greatest(weitere_reaktionen, least(coalesce((p->>'weitere')::integer, 0), 50))
   where beitrag_id = v_beitrag;

  v_auto := core.linkedin_auto_zuordnen(v_beitrag);
  perform core.linkedin_events(p_beitrag_id => v_beitrag);
  return jsonb_build_object('beitrag_id', v_beitrag, 'gesamt', v_gesamt, 'neu_personen', v_neu_p, 'neu_reaktionen', v_neu_r,
                            'kommentare', jsonb_array_length(v_komm), 'neu_kommentare', v_neu_k,
                            'kontakte_zugeordnet', v_auto->'zugeordnet', 'kontakte_angelegt', v_auto->'angelegt', 'mehrdeutig', v_auto->'mehrdeutig');
end $$;

revoke all on function public.dashboard_linkedin_erfassen(jsonb, text) from public, anon, authenticated;
grant execute on function public.dashboard_linkedin_erfassen(jsonb, text) to service_role;

-- Einmal für alle bisher erfassten Personen
select core.linkedin_auto_zuordnen();
