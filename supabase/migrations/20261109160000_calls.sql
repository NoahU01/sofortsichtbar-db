-- =====================================================================
-- Calls: Gesprächsprotokolle (Transkripte aus ChatGPT) zentral ablegen
--
-- Hochgeladen wird über einen Bereich in Daniels Dashboard (empiria-
-- dashboard). Das Dashboard spricht nie direkt mit dieser Datenbank, sondern
-- mit der Edge Function `dashboard`. Die prüft das Login beim Dashboard und
-- ob die E-Mail in core.dashboard_zugang steht, und ruft dann die
-- public.dashboard_*-Funktionen unten auf (nur service_role darf das).
-- =====================================================================

-- Wer den sofort-sichtbar-Bereich im Dashboard nutzen darf
create table core.dashboard_zugang (
  email      text primary key check (email = lower(trim(email))),
  name       text,
  created_at timestamptz not null default now()
);
alter table core.dashboard_zugang enable row level security;

create table core.calls (
  call_id             uuid primary key default gen_random_uuid(),
  contact_id          uuid references core.contacts on delete cascade,
  booking_uid         text,                 -- zugehöriger Cal.com-Termin, falls bekannt
  stattgefunden_am    timestamptz not null,
  titel               text,
  transkript          text not null check (length(trim(transkript)) > 0),
  zusammenfassung     text,
  quelle              text not null default 'chatgpt',
  -- Aufnahme ohne Einverständnis ist strafbar (§ 201 StGB) – ohne Häkchen kein Upload
  aufnahme_zugestimmt boolean not null check (aufnahme_zugestimmt),
  hochgeladen_von     text not null,
  suchtext            tsvector generated always as (
                        setweight(to_tsvector('german', coalesce(titel, '')), 'A') ||
                        setweight(to_tsvector('german', coalesce(zusammenfassung, '')), 'B') ||
                        setweight(to_tsvector('german', transkript), 'C')) stored,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index calls_contact_idx on core.calls (contact_id, stattgefunden_am desc);
create index calls_booking_idx on core.calls (booking_uid) where booking_uid is not null;
create index calls_suche_idx   on core.calls using gin (suchtext);
create trigger calls_updated_at before update on core.calls
  for each row execute function core.set_updated_at();
alter table core.calls enable row level security;
grant all on core.calls, core.dashboard_zugang to service_role;

-- Jeder Call erscheint in der Timeline des Kontakts
create or replace function core.calls_timeline()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from core.events where event_id = 'call:' || old.call_id;
    return old;
  end if;
  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  values ('call:' || new.call_id, 'call_recorded', new.stattgefunden_am, new.contact_id, 'dashboard',
          jsonb_strip_nulls(jsonb_build_object('call_id', new.call_id, 'titel', new.titel,
                                               'booking_uid', new.booking_uid, 'quelle', new.quelle)),
          'not_required')
  on conflict (event_id) do update
     set occurred_at = excluded.occurred_at, contact_id = excluded.contact_id, properties = excluded.properties;
  return new;
end $$;
create trigger calls_timeline after insert or update or delete on core.calls
  for each row execute function core.calls_timeline();

update core.event_types
   set quelle = 'dashboard', beschreibung = 'Gesprächsprotokoll hochgeladen; call_id in properties, Text in core.calls'
 where event_name = 'call_recorded';

-- ---------------------------------------------------------------------
-- Funktionen für das Dashboard
-- ---------------------------------------------------------------------

create or replace function public.dashboard_darf(p_email text)
returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from core.dashboard_zugang where email = lower(trim(p_email))) $$;

-- Cal.com-Termine in einem Zeitraum – zum Zuordnen eines Calls
create or replace function public.dashboard_termine(p_von timestamptz, p_bis timestamptz)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(t order by t->>'termin_start' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'booking_uid',  e.properties->>'booking_uid',
               'termin_start', e.properties->>'termin_start',
               'titel',        e.properties->>'titel',
               'unternehmen',  e.properties#>>'{antworten,Unternehmen}',
               'contact_id',   c.contact_id,
               'name',         nullif(concat_ws(' ', c.vorname, c.nachname), ''),
               'email',        c.email,
               'abgesagt',     exists (select 1 from core.events x
                                        where x.source = 'cal' and x.event_name = 'meeting_canceled'
                                          and x.properties->>'booking_uid' = e.properties->>'booking_uid'),
               'call_id',      (select k.call_id from core.calls k
                                 where k.booking_uid = e.properties->>'booking_uid' limit 1)
             ) as t
        from core.events e
        join core.contacts c on c.contact_id = e.contact_id
       where e.source = 'cal'
         and e.event_name in ('meeting_booked', 'meeting_rescheduled')
         and (e.properties->>'termin_start')::timestamptz between p_von and p_bis
         -- verlegte Termine nur in ihrer neuen Fassung zeigen
         and not exists (select 1 from core.events r
                          where r.source = 'cal' and r.event_name = 'meeting_rescheduled'
                            and r.properties->>'alte_booking_uid' = e.properties->>'booking_uid')
    ) s
$$;

create or replace function public.dashboard_kontakte(p_suche text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(k), '[]'::jsonb)
    from (
      select contact_id, vorname, nachname, email, lifecycle_stage
        from core.contacts
       where coalesce(trim(p_suche), '') = ''
          or concat_ws(' ', vorname, nachname, email) ilike '%' || trim(p_suche) || '%'
       order by updated_at desc
       limit 20
    ) k
$$;

-- Speichern. p: { call_id?, contact_id? | email (+ vorname, nachname), booking_uid?, stattgefunden_am,
--                 titel?, transkript, zusammenfassung?, aufnahme_zugestimmt }
create or replace function public.dashboard_call_speichern(p jsonb, p_von text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_contact uuid := nullif(p->>'contact_id', '')::uuid;
  v_call    uuid := nullif(p->>'call_id', '')::uuid;
  v_email   text := nullif(lower(trim(p->>'email')), '');
begin
  if v_contact is null and v_email is not null then
    insert into core.contacts (email, vorname, nachname)
    values (v_email, nullif(trim(p->>'vorname'), ''), nullif(trim(p->>'nachname'), ''))
    on conflict (email) where email is not null do update set email = excluded.email
    returning contact_id into v_contact;
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_contact, 'email', v_email, 'dashboard')
    on conflict (identity_type, identity_value) do nothing;
  end if;
  -- Ohne Kontakt, aber mit Termin: Kontakt aus dem Termin übernehmen
  if v_contact is null and nullif(p->>'booking_uid', '') is not null then
    select e.contact_id into v_contact from core.events e
     where e.source = 'cal' and e.properties->>'booking_uid' = p->>'booking_uid' and e.contact_id is not null
     limit 1;
  end if;

  if v_call is null then
    insert into core.calls (contact_id, booking_uid, stattgefunden_am, titel, transkript,
                            zusammenfassung, quelle, aufnahme_zugestimmt, hochgeladen_von)
    values (v_contact, nullif(p->>'booking_uid', ''),
            coalesce(nullif(p->>'stattgefunden_am', '')::timestamptz, now()),
            nullif(trim(p->>'titel'), ''), p->>'transkript', nullif(trim(p->>'zusammenfassung'), ''),
            coalesce(nullif(p->>'quelle', ''), 'chatgpt'),
            coalesce((p->>'aufnahme_zugestimmt')::boolean, false), lower(p_von))
    returning call_id into v_call;
  else
    update core.calls
       set contact_id       = v_contact,
           booking_uid      = nullif(p->>'booking_uid', ''),
           stattgefunden_am = coalesce(nullif(p->>'stattgefunden_am', '')::timestamptz, stattgefunden_am),
           titel            = nullif(trim(p->>'titel'), ''),
           transkript       = p->>'transkript',
           zusammenfassung  = nullif(trim(p->>'zusammenfassung'), '')
     where call_id = v_call;
    if not found then raise exception 'Call % nicht gefunden', v_call; end if;
  end if;
  return v_call;
end $$;

-- Liste / Suche. Mit Suchbegriff nach Relevanz, mit Textausschnitt.
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
       limit 100
    ) s
$$;

create or replace function public.dashboard_call(p_call_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select to_jsonb(k) - 'suchtext'
         || jsonb_build_object('name', nullif(concat_ws(' ', c.vorname, c.nachname), ''), 'email', c.email)
    from core.calls k
    left join core.contacts c on c.contact_id = k.contact_id
   where k.call_id = p_call_id
$$;

create or replace function public.dashboard_call_loeschen(p_call_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  delete from core.calls where call_id = p_call_id;
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.dashboard_darf(text)',
    'public.dashboard_termine(timestamptz, timestamptz)',
    'public.dashboard_kontakte(text)',
    'public.dashboard_call_speichern(jsonb, text)',
    'public.dashboard_calls(text, uuid)',
    'public.dashboard_call(uuid)',
    'public.dashboard_call_loeschen(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
