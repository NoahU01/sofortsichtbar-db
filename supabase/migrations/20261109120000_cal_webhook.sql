-- =====================================================================
-- Quelle Cal.com: Terminbuchungen per Webhook
--
-- Ablauf: Cal.com → Edge Function cal-webhook (prüft die Signatur) →
-- public.ingest_cal_webhook(payload). Die Funktion
--   1. legt den Webhook unverändert in raw.cal_webhooks ab,
--   2. legt den Kontakt an bzw. ergänzt ihn (Schlüssel: E-Mail),
--   3. schreibt das Termin-Event in die Timeline,
--   4. verknüpft den Website-Besucher: Der Browser meldet beim Buchen
--      meeting_booked mit properties.booking_uid und seiner visitor_id.
--      Gleiche booking_uid ⇒ visitor_id gehört zum Kontakt ⇒ alle früheren
--      Besuche hängen rückwirkend an ihm (Trigger identities_backfill_events).
--
-- Webhook und Browser-Event kommen in beliebiger Reihenfolge an, deshalb
-- wird in beide Richtungen verknüpft (hier und im Trigger auf core.events).
-- =====================================================================

create table raw.cal_webhooks (
  webhook_id    bigint generated always as identity primary key,
  received_at   timestamptz not null default now(),
  trigger_event text not null,
  booking_uid   text,
  payload       jsonb not null,
  verarbeitet   boolean not null default false
);
create index cal_webhooks_booking_idx on raw.cal_webhooks (booking_uid);
alter table raw.cal_webhooks enable row level security;
grant all on raw.cal_webhooks to service_role;

insert into core.event_types (event_name, quelle, beschreibung) values
  ('meeting_rescheduled', 'cal', 'Termin verschoben; vorherige Buchung in properties.alte_booking_uid');

create index events_booking_uid_idx on core.events ((properties->>'booking_uid'))
  where properties ? 'booking_uid';

-- ---------------------------------------------------------------------
-- Annahme
-- ---------------------------------------------------------------------
create or replace function public.ingest_cal_webhook(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trigger   text := p->>'triggerEvent';
  -- MEETING_STARTED/ENDED kommen ohne payload-Hülle
  v_b         jsonb := case when jsonb_typeof(p->'payload') = 'object' then p->'payload' else p end;
  v_uid       text;
  v_alt_uid   text;
  v_raw       bigint;
  v_email     text;
  v_vorname   text;
  v_nachname  text;
  v_name      jsonb;
  v_telefon   text;
  v_contact   uuid;
  v_event     text;
  v_event_id  text;
  v_props     jsonb;
  v_antworten jsonb;
  v_no_show   boolean;
  v_besucher  integer := 0;
begin
  v_uid := coalesce(v_b->>'uid', v_b->>'bookingUid');
  v_alt_uid := v_b->>'rescheduleUid';

  insert into raw.cal_webhooks (trigger_event, booking_uid, payload)
  values (coalesce(v_trigger, 'UNBEKANNT'), v_uid, p)
  returning webhook_id into v_raw;

  v_event := case v_trigger
    when 'BOOKING_CREATED'         then 'meeting_booked'
    when 'BOOKING_RESCHEDULED'     then 'meeting_rescheduled'
    when 'BOOKING_CANCELLED'       then 'meeting_canceled'
    when 'BOOKING_NO_SHOW_UPDATED' then 'meeting_no_show'
  end;
  -- Andere Trigger (Ping, MEETING_ENDED …) nur roh speichern.
  if v_event is null or v_uid is null then
    return jsonb_build_object('gespeichert', v_raw, 'verarbeitet', false);
  end if;

  -- Person: Buchungsformular vor Teilnehmerliste
  v_email := nullif(lower(trim(coalesce(v_b#>>'{responses,email,value}', v_b#>>'{attendees,0,email}'))), '');
  if v_email is null then
    return jsonb_build_object('gespeichert', v_raw, 'verarbeitet', false, 'grund', 'keine E-Mail');
  end if;

  v_name := v_b#>'{responses,name,value}';
  if jsonb_typeof(v_name) = 'object' then            -- Namensfeld in Vor-/Nachname geteilt
    v_vorname  := v_name->>'firstName';
    v_nachname := v_name->>'lastName';
  else
    v_vorname  := v_b#>>'{attendees,0,firstName}';
    v_nachname := v_b#>>'{attendees,0,lastName}';
    if v_vorname is null and coalesce(v_name #>> '{}', v_b#>>'{attendees,0,name}') is not null then
      v_vorname  := split_part(trim(coalesce(v_name #>> '{}', v_b#>>'{attendees,0,name}')), ' ', 1);
      v_nachname := nullif(trim(substr(trim(coalesce(v_name #>> '{}', v_b#>>'{attendees,0,name}')), length(v_vorname) + 1)), '');
    end if;
  end if;
  v_vorname  := nullif(trim(v_vorname), '');
  v_nachname := nullif(trim(v_nachname), '');
  v_telefon  := nullif(trim(coalesce(v_b#>>'{responses,attendeePhoneNumber,value}', v_b#>>'{attendees,0,phoneNumber}')), '');

  -- Kontakt anlegen oder Lücken füllen (vorhandene Angaben nie überschreiben)
  insert into core.contacts (email, vorname, nachname, telefon)
  values (v_email, v_vorname, v_nachname, v_telefon)
  on conflict (email) where email is not null do update
     set vorname  = coalesce(core.contacts.vorname,  excluded.vorname),
         nachname = coalesce(core.contacts.nachname, excluded.nachname),
         telefon  = coalesce(core.contacts.telefon,  excluded.telefon)
  returning contact_id into v_contact;

  insert into core.identities (contact_id, identity_type, identity_value, source)
  values (v_contact, 'email', v_email, 'cal')
  on conflict (identity_type, identity_value) do update set last_seen = now();

  -- Antworten aus dem Buchungsformular ohne die Felder, die schon im Kontakt stehen
  select coalesce(jsonb_object_agg(k, v->'value'), '{}'::jsonb) into v_antworten
    from jsonb_each(coalesce(v_b->'responses', '{}'::jsonb)) as r(k, v)
   where k not in ('name', 'email', 'attendeePhoneNumber', 'location', 'guests')
     and jsonb_typeof(v) = 'object'
     and v->'value' is not null and v->'value' <> 'null'::jsonb and v->>'value' <> '';

  v_props := jsonb_strip_nulls(jsonb_build_object(
    'booking_uid',      v_uid,
    'alte_booking_uid', v_alt_uid,
    'titel',            v_b->>'title',
    'termin_start',     v_b->>'startTime',
    'termin_ende',      v_b->>'endTime',
    'event_type_id',    v_b->'eventTypeId',
    'status',           v_b->>'status',
    'absage_grund',     v_b->>'cancellationReason',
    'antworten',        nullif(v_antworten, '{}'::jsonb)
  ));

  if v_event = 'meeting_no_show' then
    select (a->>'noShow')::boolean into v_no_show
      from jsonb_array_elements(coalesce(v_b->'attendees', '[]'::jsonb)) a
     where lower(a->>'email') = v_email
     limit 1;
    v_props := v_props || jsonb_build_object('no_show', coalesce(v_no_show, true));
    -- Markieren und wieder Entmarkieren sind zwei Ereignisse
    v_event_id := 'cal:no_show:' || v_uid || ':' || coalesce(p->>'createdAt', now()::text);
  else
    v_event_id := 'cal:' || v_event || ':' || v_uid;
  end if;

  insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
  values (v_event_id, v_event,
          coalesce((p->>'createdAt')::timestamptz, now()),
          v_contact, 'cal', v_props, 'not_required')
  on conflict (event_id) do nothing;

  -- Website-Besucher verknüpfen, falls das Browser-Event schon da ist
  if v_event in ('meeting_booked', 'meeting_rescheduled') then
    insert into core.identities (contact_id, identity_type, identity_value, source)
    select distinct v_contact, 'visitor_id', e.visitor_id, 'cal'
      from core.events e
     where e.properties ? 'booking_uid'
       and e.properties->>'booking_uid' in (v_uid, v_alt_uid)
       and e.source = 'website'
       and e.visitor_id is not null
    on conflict (identity_type, identity_value) do nothing;
    get diagnostics v_besucher = row_count;
  end if;

  update raw.cal_webhooks set verarbeitet = true where webhook_id = v_raw;

  return jsonb_build_object('gespeichert', v_raw, 'verarbeitet', true,
                            'contact_id', v_contact, 'event', v_event,
                            'besucher_verknuepft', v_besucher);
end $$;

revoke all on function public.ingest_cal_webhook(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_cal_webhook(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- Gegenrichtung: Browser meldet die Buchung NACH dem Webhook
-- ---------------------------------------------------------------------
create or replace function core.events_link_booking()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_contact uuid;
begin
  select e.contact_id into v_contact
    from core.events e
   where e.properties ? 'booking_uid'
     and e.properties->>'booking_uid' = new.properties->>'booking_uid'
     and e.source = 'cal'
     and e.contact_id is not null
   limit 1;
  if v_contact is not null then
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_contact, 'visitor_id', new.visitor_id, 'cal')
    on conflict (identity_type, identity_value) do nothing;
  end if;
  return null;
end $$;

create trigger events_link_booking
  after insert on core.events
  for each row
  when (new.source = 'website' and new.event_name = 'meeting_booked'
        and new.visitor_id is not null and new.contact_id is null
        and new.properties ? 'booking_uid')
  execute function core.events_link_booking();

-- ---------------------------------------------------------------------
-- Löschen: rohe Webhooks des Kontakts gehören dazu
-- ---------------------------------------------------------------------
create or replace function core.delete_contact(p_contact_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_email text;
begin
  select email into v_email from core.contacts where contact_id = p_contact_id;
  delete from raw.cal_webhooks w
   where w.booking_uid in (select e.properties->>'booking_uid' from core.events e
                            where e.contact_id = p_contact_id and e.source = 'cal')
      or (v_email is not null and (lower(w.payload#>>'{payload,responses,email,value}') = v_email
                                   or lower(w.payload#>>'{payload,attendees,0,email}') = v_email));
  delete from core.events e
   using core.identities i
   where i.contact_id = p_contact_id
     and i.identity_type = 'visitor_id'
     and e.visitor_id = i.identity_value;
  delete from core.contacts where contact_id = p_contact_id;  -- Rest per cascade
end $$;
revoke execute on function core.delete_contact(uuid) from public, anon, authenticated;
