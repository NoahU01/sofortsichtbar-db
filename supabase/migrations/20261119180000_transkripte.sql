-- =====================================================================
-- Call-Transkripte aus einem OneDrive-/SharePoint-Ordner
--
-- Die Edge Function transkripte-import liest den freigegebenen Ordner
-- (Microsoft Graph, App-Berechtigung Files.SelectedOperations.Selected, nur
-- dieser Ordner), wandelt .docx/.vtt/.txt/.md in Text und ruft je Datei
-- ingest_transkript auf. Zuordnung: Termin aus den Kalendern (core.kalender)
-- zur Uhrzeit des Transkripts → externe Teilnehmer → Kontakt. Ergebnis ist
-- ein Call (core.calls, quelle 'sharepoint') – erscheint im Calls-Bereich und
-- im Verlauf. Ohne passenden Termin bleibt der Call ohne Kontakt und kann im
-- Cockpit zugeordnet werden.
--
-- Einverständnis zur Aufnahme (§ 201 StGB): aufnahme_zugestimmt = true beim
-- automatischen Import setzt voraus, dass vor jeder Aufnahme das
-- Einverständnis eingeholt wird (Regel von sofort sichtbar).
-- =====================================================================

create table core.transkript_dateien (
  item_id     text primary key,
  name        text not null,
  etag        text,
  groesse     bigint,
  geaendert   timestamptz,
  status      text not null check (status in ('importiert', 'nicht_lesbar', 'leer')),
  fehler      text,
  call_id     uuid references core.calls on delete set null,
  verarbeitet timestamptz not null default now()
);
alter table core.transkript_dateien enable row level security;
grant all on core.transkript_dateien to service_role;

-- Was ist schon da? (item_id → etag), damit nur Neues geladen wird
create or replace function public.transkripte_stand()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(item_id, etag), '{}'::jsonb) from core.transkript_dateien
$$;

-- p: { item_id, name, etag, groesse, geaendert, beginn, text, status, fehler }
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

do $$
declare f text;
begin
  foreach f in array array['public.transkripte_stand()', 'public.ingest_transkript(jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
