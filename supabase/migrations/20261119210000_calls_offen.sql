-- Calls: offene (ohne Kontakt) von vergangenen trennen, Zuordnen per Klick, Quelle mitliefern
create or replace function public.dashboard_calls(p_suche text, p_contact_id uuid default null)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with q as (
    select case when coalesce(trim(p_suche), '') = '' then null
                else websearch_to_tsquery('german', p_suche) end as tsq
  )
  select coalesce(jsonb_agg(z order by (z->>'rang')::float desc, z->>'stattgefunden_am' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'call_id',          k.call_id,
               'stattgefunden_am', k.stattgefunden_am,
               'titel',            k.titel,
               'contact_id',       k.contact_id,
               'name',             nullif(concat_ws(' ', c.vorname, c.nachname), ''),
               'email',            c.email,
               'hochgeladen_von',  k.hochgeladen_von,
               'quelle',           k.quelle,
               'zusammenfassung',  left(k.zusammenfassung, 300),
               'ausschnitt',       case when q.tsq is null then left(k.transkript, 200)
                                        else ts_headline('german', k.transkript, q.tsq,
                                               'StartSel=⟦,StopSel=⟧,MaxWords=30,MinWords=12,MaxFragments=2') end,
               'rang',             case when q.tsq is null then 0 else ts_rank(k.suchtext, q.tsq) end
             ) as z
        from core.calls k
        cross join q
        left join core.contacts c on c.contact_id = k.contact_id
       where (q.tsq is null or k.suchtext @@ q.tsq)
         and (p_contact_id is null or k.contact_id = p_contact_id)
       order by k.stattgefunden_am desc
       limit 500
    ) s
$$;

create or replace function public.dashboard_call_zuordnen(p_call_id uuid, p_contact_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_contact_id is not null and not exists (select 1 from core.contacts where contact_id = p_contact_id) then raise exception 'Kontakt nicht gefunden'; end if;
  update core.calls set contact_id = p_contact_id where call_id = p_call_id;
  return found;
end $$;

revoke all on function public.dashboard_calls(text, uuid) from public, anon, authenticated;
grant execute on function public.dashboard_calls(text, uuid) to service_role;
revoke all on function public.dashboard_call_zuordnen(uuid, uuid) from public, anon, authenticated;
grant execute on function public.dashboard_call_zuordnen(uuid, uuid) to service_role;
