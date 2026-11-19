-- Transkripte: ohne passenden Termin den Kontakt über seinen Namen im Dateinamen finden (nur wenn eindeutig)
create or replace function public.ingest_transkript(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_item text := p->>'item_id'; v_alt core.transkript_dateien;
  v_zeit timestamptz := coalesce(nullif(p->>'beginn', '')::timestamptz, nullif(p->>'geaendert', '')::timestamptz, now());
  v_text text := nullif(trim(p->>'text'), '');
  v_status text := coalesce(nullif(p->>'status', ''), case when nullif(trim(p->>'text'), '') is null then 'leer' else 'importiert' end);
  k core.kalender; v_contact uuid; v_call uuid; v_titel text;
begin
  if v_item is null then raise exception 'item_id fehlt'; end if;
  select * into v_alt from core.transkript_dateien where item_id = v_item;

  if v_status = 'importiert' and v_text is not null then
    -- Termin zur Uhrzeit: begonnen höchstens 4 h vor bzw. 30 min nach dem Zeitstempel, der nächstgelegene gewinnt
    select * into k from core.kalender kk
     where not kk.abgesagt and kk.beginn between v_zeit - interval '4 hours' and v_zeit + interval '30 minutes'
     order by abs(extract(epoch from (kk.beginn - v_zeit))) limit 1;
    if k.graph_id is not null then
      select i.contact_id into v_contact
        from jsonb_array_elements(k.teilnehmer) t
        join core.identities i on i.identity_type = 'email' and i.identity_value = lower(t->>'email')
       where split_part(lower(t->>'email'), '@', 2) <> split_part(lower(k.postfach), '@', 2)
       limit 1;
    end if;
    -- Kein Termin/Kontakt: Name eines Kontakts im Dateinamen (genau einer)
    if v_contact is null then
      select min(c.contact_id::text)::uuid into v_contact from core.contacts c
       where c.vorname is not null and c.nachname is not null and length(c.vorname || c.nachname) >= 5
         and lower(p->>'name') like '%' || lower(c.vorname || ' ' || c.nachname) || '%'
      having count(*) = 1;
    end if;
    v_titel := coalesce(nullif(k.betreff, ''), regexp_replace(p->>'name', '\.[A-Za-z0-9]+$', ''));

    if v_alt.call_id is not null and exists (select 1 from core.calls where call_id = v_alt.call_id) then
      update core.calls set transkript = v_text, titel = coalesce(titel, v_titel) where call_id = v_alt.call_id;
      v_call := v_alt.call_id;
    else
      insert into core.calls (contact_id, stattgefunden_am, titel, transkript, quelle, aufnahme_zugestimmt, hochgeladen_von)
      values (v_contact, coalesce(k.beginn, v_zeit), left(v_titel, 300), v_text, 'sharepoint', true, 'transkripte-import')
      returning call_id into v_call;
    end if;
  end if;

  insert into core.transkript_dateien (item_id, name, etag, groesse, geaendert, status, fehler, call_id)
  values (v_item, left(p->>'name', 300), p->>'etag', nullif(p->>'groesse', '')::bigint, nullif(p->>'geaendert', '')::timestamptz,
          v_status, left(p->>'fehler', 500), v_call)
  on conflict (item_id) do update set name = excluded.name, etag = excluded.etag, groesse = excluded.groesse, geaendert = excluded.geaendert,
                                      status = excluded.status, fehler = excluded.fehler, call_id = coalesce(excluded.call_id, core.transkript_dateien.call_id),
                                      verarbeitet = now();
  return jsonb_build_object('call_id', v_call, 'contact_id', v_contact, 'termin', k.betreff, 'status', v_status);
end $$;

revoke all on function public.ingest_transkript(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_transkript(jsonb) to service_role;
