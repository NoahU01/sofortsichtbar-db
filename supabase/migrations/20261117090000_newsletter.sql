-- =====================================================================
-- Newsletter (eigene Lösung, Versand über Amazon SES)
--
--   core.newsletter              ein Newsletter (Entwurf → wird_gesendet → gesendet)
--   core.newsletter_empfaenger   eine Zeile je Empfänger und Versand (auch Testversand),
--                                mit eigenem Token für Klick- und Abmeldelinks
--   core.newsletter_klicks       Klicks über den eigenen Weiterleitungslink
--   core.newsletter_sperre       Adressen, die nie wieder etwas bekommen
--                                (abgemeldet, dauerhaft unzustellbar, Spam-Beschwerde)
--   analytics.newsletter_status  Stand des SES-Kontos (Testmodus, Kontingent)
--
-- Ablauf: Das Cockpit speichert Entwürfe und gibt frei. „Senden“ legt die
-- Empfängerzeilen fest (nur Kontakte mit newsletter_erlaubt, ohne Sperre).
-- Die Edge Function newsletter-versand holt jede Minute einen Schwung ab,
-- rendert, schickt über SES und meldet das Ergebnis zurück.
-- Klick- und Abmeldelinks laufen über sofortsichtbar.de (Website-API), die
-- newsletter_klick / newsletter_abmelden aufruft. SES-Ereignisse (Zustellung,
-- Bounce, Beschwerde) kommen über SNS → newsletter_ses_ereignis.
--
-- Öffnungen werden NICHT gemessen (Pixel bräuchte eine Einwilligung).
-- Klicks werden nur gemessen, wenn klicks_messen an ist.
-- =====================================================================

create table core.newsletter (
  newsletter_id   uuid primary key default gen_random_uuid(),
  titel           text not null,                      -- intern
  betreff         text not null default '',
  vorschautext    text not null default '',           -- Vorschauzeile im Posteingang
  inhalt          text not null default '',           -- vereinfachtes Markdown mit Platzhaltern
  listen          text[] not null default '{}',       -- Tags der Zielgruppe; leer = alle mit Erlaubnis
  klicks_messen   boolean not null default true,
  utm             boolean not null default true,
  utm_kampagne    text,
  links           jsonb not null default '[]'::jsonb, -- Linkziele in Reihenfolge (vom Versand gesetzt)
  status          text not null default 'entwurf'
                  check (status in ('entwurf', 'wird_gesendet', 'gesendet', 'abgebrochen')),
  erstellt_von    text,
  geaendert_von   text,
  freigegeben_von text,
  freigegeben_am  timestamptz,
  gesendet_am     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger newsletter_updated_at before update on core.newsletter
  for each row execute function core.set_updated_at();

create table core.newsletter_empfaenger (
  empfaenger_id  bigint generated always as identity primary key,
  newsletter_id  uuid not null references core.newsletter on delete cascade,
  contact_id     uuid references core.contacts on delete cascade,
  email          text not null check (email = lower(email)),
  test           boolean not null default false,
  token          text not null unique
                 default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  status         text not null default 'wartet'
                 check (status in ('wartet', 'in_arbeit', 'gesendet', 'zugestellt', 'fehler', 'bounce', 'beschwerde', 'uebersprungen')),
  versuche       integer not null default 0,
  gesperrt_bis   timestamptz,
  ses_message_id text,
  fehler         text,
  gesendet_am    timestamptz,
  zugestellt_am  timestamptz,
  abgemeldet_am  timestamptz,
  angelegt_von   text,
  created_at     timestamptz not null default now()
);
create unique index newsletter_empfaenger_einmal on core.newsletter_empfaenger (newsletter_id, contact_id) where not test and contact_id is not null;
create index newsletter_empfaenger_offen on core.newsletter_empfaenger (status, created_at) where status in ('wartet', 'in_arbeit');
create index newsletter_empfaenger_ses on core.newsletter_empfaenger (ses_message_id) where ses_message_id is not null;
create index newsletter_empfaenger_contact on core.newsletter_empfaenger (contact_id);

create table core.newsletter_klicks (
  klick_id      bigint generated always as identity primary key,
  empfaenger_id bigint not null references core.newsletter_empfaenger on delete cascade,
  link_nr       integer not null,
  url           text not null,
  zeit          timestamptz not null default now(),
  verdacht_bot  boolean not null default false     -- Link-Scanner der Mailprogramme
);
create index newsletter_klicks_empfaenger on core.newsletter_klicks (empfaenger_id);

create table core.newsletter_sperre (
  email text primary key check (email = lower(email)),
  grund text not null check (grund in ('abgemeldet', 'bounce', 'beschwerde', 'manuell')),
  seit  timestamptz not null default now()
);

create table analytics.newsletter_status (
  id            integer primary key default 1 check (id = 1),
  produktion    boolean,
  max_24h       numeric,
  max_rate      numeric,
  gesendet_24h  numeric,
  fehler        text,
  geprueft      timestamptz not null default now()
);

alter table core.newsletter            enable row level security;
alter table core.newsletter_empfaenger enable row level security;
alter table core.newsletter_klicks     enable row level security;
alter table core.newsletter_sperre     enable row level security;
alter table analytics.newsletter_status enable row level security;
grant all on core.newsletter, core.newsletter_empfaenger, core.newsletter_klicks, core.newsletter_sperre,
             analytics.newsletter_status to service_role;

update core.event_types set quelle = 'newsletter' where event_name like 'email\_%';

-- ---------------------------------------------------------------------
-- Hilfen
-- ---------------------------------------------------------------------
-- Darf diese Adresse nicht (mehr) angeschrieben werden?
create or replace function core.newsletter_gesperrt(p_email text)
returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from core.newsletter_sperre s where s.email = lower(trim(p_email)))
$$;

-- Zielgruppe eines Newsletters: Kontakte mit Erlaubnis, E-Mail, ohne Sperre,
-- bei gesetzten Listen mit mindestens einem dieser Tags
create or replace function core.newsletter_zielgruppe(p_listen text[])
returns table (contact_id uuid, email text)
language sql stable set search_path = '' as $$
  select c.contact_id, c.email
    from core.contacts c
   where c.newsletter_erlaubt and c.email is not null
     and (coalesce(cardinality(p_listen), 0) = 0 or c.tags && p_listen)
     and not exists (select 1 from core.newsletter_sperre s where s.email = c.email)
$$;

-- Abmelden/Sperren: Erlaubnis entziehen, protokollieren, Sperre setzen
create or replace function core.newsletter_entziehen(p_contact_id uuid, p_email text, p_grund text, p_quelle text)
returns void
language plpgsql set search_path = ''
as $$
begin
  insert into core.newsletter_sperre (email, grund) values (lower(trim(p_email)), p_grund)
  on conflict (email) do nothing;
  if p_contact_id is not null then
    if exists (select 1 from core.contacts where contact_id = p_contact_id and newsletter_erlaubt) then
      insert into core.consents (contact_id, channel, status, source)
      values (p_contact_id, 'email_marketing', 'revoked', p_quelle);
    end if;
    update core.contacts set newsletter_erlaubt = false, newsletter_grundlage = null, newsletter_seit = null
     where contact_id = p_contact_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Cockpit
-- ---------------------------------------------------------------------
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

create or replace function public.dashboard_newsletter(p_newsletter_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with e as (
    select e.*, (select count(*) from core.newsletter_klicks k where k.empfaenger_id = e.empfaenger_id and not k.verdacht_bot) as klicks
      from core.newsletter_empfaenger e where e.newsletter_id = p_newsletter_id
  )
  select jsonb_build_object(
    'newsletter', to_jsonb(n),
    'zahlen', (select jsonb_build_object(
                 'empfaenger', count(*), 'wartet', count(*) filter (where status in ('wartet', 'in_arbeit')),
                 'versendet', count(*) filter (where status in ('gesendet', 'zugestellt', 'bounce', 'beschwerde')),
                 'zugestellt', count(*) filter (where status = 'zugestellt'),
                 'bounces', count(*) filter (where status = 'bounce'), 'beschwerden', count(*) filter (where status = 'beschwerde'),
                 'fehler', count(*) filter (where status = 'fehler'), 'uebersprungen', count(*) filter (where status = 'uebersprungen'),
                 'abmeldungen', count(*) filter (where abgemeldet_am is not null),
                 'klicker', count(*) filter (where klicks > 0), 'klicks', coalesce(sum(klicks), 0))
                 from e where not e.test),
    'links', (select coalesce(jsonb_agg(jsonb_build_object('nr', l.nr - 1, 'url', l.url,
                        'klicks', (select count(*) from core.newsletter_klicks k join e on e.empfaenger_id = k.empfaenger_id
                                    where k.link_nr = l.nr - 1 and not k.verdacht_bot and not e.test),
                        'personen', (select count(distinct k.empfaenger_id) from core.newsletter_klicks k join e on e.empfaenger_id = k.empfaenger_id
                                      where k.link_nr = l.nr - 1 and not k.verdacht_bot and not e.test)) order by l.nr), '[]'::jsonb)
                from jsonb_array_elements_text(n.links) with ordinality l(url, nr)),
    'empfaenger', (select coalesce(jsonb_agg(jsonb_build_object(
                     'contact_id', e.contact_id, 'email', e.email, 'status', e.status, 'klicks', e.klicks,
                     'gesendet_am', e.gesendet_am, 'abgemeldet', e.abgemeldet_am is not null, 'fehler', e.fehler,
                     'name', nullif(concat_ws(' ', c.titel, c.vorname, c.nachname), '')) order by e.klicks desc, e.email), '[]'::jsonb)
                     from (select * from e where not e.test order by klicks desc, email limit 3000) e
                     left join core.contacts c on c.contact_id = e.contact_id),
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('email', e.email, 'status', e.status, 'zeit', e.created_at, 'fehler', e.fehler)
                                        order by e.created_at desc), '[]'::jsonb)
                from (select * from e where e.test order by created_at desc limit 10) e)
  )
    from core.newsletter n where n.newsletter_id = p_newsletter_id
$$;

-- Zielgruppe zählen + Beispielkontakt für die Vorschau
create or replace function public.dashboard_newsletter_zielgruppe(p_listen text[])
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'anzahl', (select count(*) from core.newsletter_zielgruppe(p_listen)),
    'beispiel', (select jsonb_build_object('titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname, 'email', c.email,
                                           'firma', co.name, 'position', c.position)
                   from core.newsletter_zielgruppe(p_listen) z
                   join core.contacts c on c.contact_id = z.contact_id
                   left join core.companies co on co.company_id = c.company_id
                  order by (c.vorname is null), c.nachname limit 1))
$$;

-- Entwurf speichern. p: {newsletter_id?, titel, betreff, vorschautext, inhalt, listen[], klicks_messen, utm, utm_kampagne}
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
    insert into core.newsletter (titel, betreff, vorschautext, inhalt, listen, klicks_messen, utm, utm_kampagne, erstellt_von, geaendert_von)
    values (coalesce(nullif(trim(p->>'titel'), ''), 'Neuer Newsletter'), coalesce(p->>'betreff', ''), coalesce(p->>'vorschautext', ''),
            coalesce(p->>'inhalt', ''), v_listen, coalesce((p->>'klicks_messen')::boolean, true), coalesce((p->>'utm')::boolean, true),
            nullif(trim(p->>'utm_kampagne'), ''), p_von, p_von)
    returning newsletter_id into v_id;
    return v_id;
  end if;
  update core.newsletter
     set titel = coalesce(nullif(trim(p->>'titel'), ''), titel), betreff = coalesce(p->>'betreff', ''),
         vorschautext = coalesce(p->>'vorschautext', ''), inhalt = coalesce(p->>'inhalt', ''), listen = v_listen,
         klicks_messen = coalesce((p->>'klicks_messen')::boolean, true), utm = coalesce((p->>'utm')::boolean, true),
         utm_kampagne = nullif(trim(p->>'utm_kampagne'), ''), geaendert_von = p_von
   where newsletter_id = v_id and status = 'entwurf';
  if not found then raise exception 'Nur Entwürfe lassen sich bearbeiten'; end if;
  return v_id;
end $$;

-- Testversand an bis zu 5 Adressen (auch im SES-Testmodus an bestätigte Adressen)
create or replace function public.dashboard_newsletter_test(p_newsletter_id uuid, p_emails text[], p_von text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  if not exists (select 1 from core.newsletter where newsletter_id = p_newsletter_id) then raise exception 'Newsletter nicht gefunden'; end if;
  insert into core.newsletter_empfaenger (newsletter_id, contact_id, email, test, angelegt_von)
  select p_newsletter_id,
         (select i.contact_id from core.identities i where i.identity_type = 'email' and i.identity_value = m limit 1),
         m, true, p_von
    from (select distinct lower(trim(x)) as m from unnest(p_emails) x) a
   where m ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
   limit 5;
  get diagnostics n = row_count;
  return n;
end $$;

-- Freigeben und senden: Empfänger festlegen, Inhalt einfrieren
create or replace function public.dashboard_newsletter_senden(p_newsletter_id uuid, p_von text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v core.newsletter;
  n integer;
begin
  select * into v from core.newsletter where newsletter_id = p_newsletter_id for update;
  if not found then raise exception 'Newsletter nicht gefunden'; end if;
  if v.status <> 'entwurf' then raise exception 'Dieser Newsletter wurde schon gesendet'; end if;
  if trim(v.betreff) = '' or trim(v.inhalt) = '' then raise exception 'Betreff und Inhalt fehlen'; end if;

  insert into core.newsletter_empfaenger (newsletter_id, contact_id, email, angelegt_von)
  select p_newsletter_id, z.contact_id, z.email, p_von from core.newsletter_zielgruppe(v.listen) z
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Keine Empfänger mit Newsletter-Erlaubnis in dieser Zielgruppe'; end if;

  update core.newsletter set status = 'wird_gesendet', freigegeben_von = p_von, freigegeben_am = now()
   where newsletter_id = p_newsletter_id;
  return n;
end $$;

-- Notbremse: noch nicht verschickte Mails nicht mehr senden
create or replace function public.dashboard_newsletter_abbrechen(p_newsletter_id uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  update core.newsletter_empfaenger set status = 'uebersprungen', fehler = 'abgebrochen'
   where newsletter_id = p_newsletter_id and status in ('wartet', 'in_arbeit') and not test;
  get diagnostics n = row_count;
  update core.newsletter set status = 'abgebrochen' where newsletter_id = p_newsletter_id and status = 'wird_gesendet';
  return n;
end $$;

create or replace function public.dashboard_newsletter_loeschen(p_newsletter_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  delete from core.newsletter where newsletter_id = p_newsletter_id and status = 'entwurf';
  return found;
end $$;

-- Liste hochladen. p: {liste, grundlage ('bestandskunde'|'einwilligung'), personen:[{email, vorname?, nachname?, name?, firma?}]}
create or replace function public.dashboard_newsletter_liste(p jsonb, p_von text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_liste text := lower(trim(coalesce(p->>'liste', '')));
  v_grund text := p->>'grundlage';
  x jsonb; v_mail text; v_vor text; v_nach text; v_firma text; v_contact uuid; v_company uuid; z record;
  n_gesamt integer := 0; n_neu integer := 0; n_erlaubt integer := 0; n_gesperrt integer := 0; n_ungueltig integer := 0;
begin
  if v_liste = '' then raise exception 'Name der Liste fehlt'; end if;
  if v_grund not in ('bestandskunde', 'einwilligung') then raise exception 'Grundlage fehlt'; end if;

  for x in select * from jsonb_array_elements(coalesce(p->'personen', '[]'::jsonb)) loop
    n_gesamt := n_gesamt + 1;
    v_mail := lower(trim(coalesce(x->>'email', '')));
    if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then n_ungueltig := n_ungueltig + 1; continue; end if;
    v_vor := nullif(trim(x->>'vorname'), ''); v_nach := nullif(trim(x->>'nachname'), '');
    if v_vor is null and v_nach is null and nullif(trim(x->>'name'), '') is not null then
      select * into z from core.name_zerlegen(x->>'name');
      v_vor := z.vorname; v_nach := z.nachname;
    end if;
    v_firma := left(nullif(trim(x->>'firma'), ''), 200);

    select i.contact_id into v_contact from core.identities i where i.identity_type = 'email' and i.identity_value = v_mail;
    if v_contact is null then select c.contact_id into v_contact from core.contacts c where c.email = v_mail; end if;
    if v_contact is null then
      insert into core.contacts (email, vorname, nachname, herkunft, tags)
      values (v_mail, left(v_vor, 100), left(v_nach, 100), 'import', array[v_liste])
      returning contact_id into v_contact;
      n_neu := n_neu + 1;
    else
      update core.contacts
         set tags = case when v_liste = any (tags) then tags else array_append(tags, v_liste) end,
             vorname = coalesce(vorname, left(v_vor, 100)), nachname = coalesce(nachname, left(v_nach, 100)),
             email = coalesce(email, v_mail)
       where contact_id = v_contact;
    end if;
    insert into core.identities (contact_id, identity_type, identity_value, source)
    values (v_contact, 'email', v_mail, 'import')
    on conflict (identity_type, identity_value) do nothing;

    if v_firma is not null and (select company_id from core.contacts where contact_id = v_contact) is null then
      select company_id into v_company from core.companies where lower(name) = lower(v_firma) order by created_at limit 1;
      if v_company is null then insert into core.companies (name) values (v_firma) returning company_id into v_company; end if;
      update core.contacts set company_id = v_company where contact_id = v_contact;
      v_company := null;
    end if;

    -- Wer sich abgemeldet hat, unzustellbar ist oder sich beschwert hat, bekommt keine Erlaubnis zurück
    if core.newsletter_gesperrt(v_mail) then
      n_gesperrt := n_gesperrt + 1;
    elsif not (select newsletter_erlaubt from core.contacts where contact_id = v_contact) then
      update core.contacts set newsletter_erlaubt = true, newsletter_grundlage = v_grund, newsletter_seit = now()
       where contact_id = v_contact;
      insert into core.consents (contact_id, channel, status, source)
      values (v_contact, 'email_marketing', 'granted', 'liste:' || v_liste || ':' || v_grund || ':' || coalesce(p_von, 'unbekannt'));
      n_erlaubt := n_erlaubt + 1;
    end if;
    v_contact := null;
  end loop;

  return jsonb_build_object('gesamt', n_gesamt, 'neu', n_neu, 'erlaubt_neu', n_erlaubt, 'gesperrt', n_gesperrt, 'ungueltig', n_ungueltig);
end $$;

-- ---------------------------------------------------------------------
-- Versand (Edge Function newsletter-versand)
-- ---------------------------------------------------------------------
create or replace function public.newsletter_versand_holen(p_max integer)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  -- Gesperrte Adressen gar nicht erst versuchen
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
       set status = 'in_arbeit', gesperrt_bis = now() + interval '5 minutes', versuche = e.versuche + 1
      from zug where e.empfaenger_id = zug.empfaenger_id
    returning e.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'empfaenger_id', u.empfaenger_id, 'token', u.token, 'email', u.email, 'test', u.test,
           'kontakt', jsonb_build_object('titel', c.titel, 'vorname', c.vorname, 'nachname', c.nachname,
                                         'firma', co.name, 'position', c.position),
           'newsletter', jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff, 'vorschautext', n.vorschautext,
                                            'inhalt', n.inhalt, 'klicks_messen', n.klicks_messen, 'utm', n.utm,
                                            'utm_kampagne', coalesce(n.utm_kampagne, n.titel)))), '[]'::jsonb)
    into v
    from upd u
    join core.newsletter n on n.newsletter_id = u.newsletter_id
    left join core.contacts c on c.contact_id = u.contact_id
    left join core.companies co on co.company_id = c.company_id;
  return v;
end $$;

-- p: { links: {newsletter_id: [url, …]}, ergebnisse: [{empfaenger_id, ok, message_id?, fehler?, dauerhaft?}] }
create or replace function public.newsletter_versand_ergebnis(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; n_ok integer := 0; n_fehler integer := 0; k text;
begin
  for k in select jsonb_object_keys(coalesce(p->'links', '{}'::jsonb)) loop
    update core.newsletter set links = p->'links'->k where newsletter_id = k::uuid;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p->'ergebnisse', '[]'::jsonb)) loop
    if coalesce((r->>'freigeben')::boolean, false) then
      -- nicht versucht (Zeitbudget): zurück in die Warteschlange, zählt nicht als Versuch
      update core.newsletter_empfaenger set status = 'wartet', versuche = greatest(versuche - 1, 0), gesperrt_bis = null
       where empfaenger_id = (r->>'empfaenger_id')::bigint and status = 'in_arbeit';
    elsif coalesce((r->>'ok')::boolean, false) then
      update core.newsletter_empfaenger
         set status = 'gesendet', ses_message_id = r->>'message_id', gesendet_am = now(), fehler = null, gesperrt_bis = null
       where empfaenger_id = (r->>'empfaenger_id')::bigint;
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      select 'nl:' || e.empfaenger_id || ':sent', 'email_sent', now(), e.contact_id, 'newsletter',
             jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff), 'not_required'
        from core.newsletter_empfaenger e join core.newsletter n on n.newsletter_id = e.newsletter_id
       where e.empfaenger_id = (r->>'empfaenger_id')::bigint and not e.test and e.contact_id is not null
      on conflict (event_id) do nothing;
      n_ok := n_ok + 1;
    else
      update core.newsletter_empfaenger
         set status = case when coalesce((r->>'dauerhaft')::boolean, false) or versuche >= 3 then 'fehler' else 'wartet' end,
             fehler = left(r->>'fehler', 500), gesperrt_bis = null
       where empfaenger_id = (r->>'empfaenger_id')::bigint;
      n_fehler := n_fehler + 1;
    end if;
  end loop;

  -- Fertig gesendete Newsletter abschließen
  update core.newsletter n set status = 'gesendet', gesendet_am = now()
   where n.status = 'wird_gesendet'
     and not exists (select 1 from core.newsletter_empfaenger e
                      where e.newsletter_id = n.newsletter_id and not e.test and e.status in ('wartet', 'in_arbeit'));
  return jsonb_build_object('ok', n_ok, 'fehler', n_fehler);
end $$;

create or replace function public.newsletter_status_setzen(p jsonb)
returns void
language sql security definer set search_path = ''
as $$
  insert into analytics.newsletter_status (id, produktion, max_24h, max_rate, gesendet_24h, fehler, geprueft)
  values (1, (p->>'produktion')::boolean, (p->>'max_24h')::numeric, (p->>'max_rate')::numeric,
          (p->>'gesendet_24h')::numeric, nullif(p->>'fehler', ''), now())
  on conflict (id) do update set produktion = excluded.produktion, max_24h = excluded.max_24h, max_rate = excluded.max_rate,
                                 gesendet_24h = excluded.gesendet_24h, fehler = excluded.fehler, geprueft = now()
$$;

-- ---------------------------------------------------------------------
-- Öffentliche Links (über die Website-API auf sofortsichtbar.de)
-- ---------------------------------------------------------------------
-- Klick: Ziel zurückgeben und (falls gemessen) protokollieren
create or replace function public.newsletter_klick(p_token text, p_nr integer, p_ua text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare e core.newsletter_empfaenger; n core.newsletter; v_url text; v_bot boolean;
begin
  select * into e from core.newsletter_empfaenger where token = p_token;
  if not found then return null; end if;
  select * into n from core.newsletter where newsletter_id = e.newsletter_id;
  v_url := n.links->>p_nr;
  if v_url is null then return null; end if;
  if n.klicks_messen then
    v_bot := p_ua is null or p_ua ~* '(bot|crawl|spider|preview|scan|safelinks|proofpoint|mimecast|barracuda|python|curl|wget|headless)'
             or (e.gesendet_am is not null and now() - e.gesendet_am < interval '20 seconds');
    insert into core.newsletter_klicks (empfaenger_id, link_nr, url, verdacht_bot) values (e.empfaenger_id, p_nr, v_url, v_bot);
    if not v_bot and not e.test and e.contact_id is not null then
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      values ('nl:' || e.empfaenger_id || ':click:' || p_nr, 'email_click', now(), e.contact_id, 'newsletter',
              jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff, 'url', v_url, 'link_nr', p_nr), 'not_required')
      on conflict (event_id) do nothing;
    end if;
  end if;
  return v_url;
end $$;

-- Abmelden über den Link in der Mail (oder One-Click im Mailprogramm)
create or replace function public.newsletter_abmelden(p_token text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare e core.newsletter_empfaenger; n core.newsletter;
begin
  select * into e from core.newsletter_empfaenger where token = p_token;
  if not found then return false; end if;
  if e.test then return true; end if;
  select * into n from core.newsletter where newsletter_id = e.newsletter_id;
  perform core.newsletter_entziehen(e.contact_id, e.email, 'abgemeldet', 'abmeldelink');
  update core.newsletter_empfaenger set abgemeldet_am = coalesce(abgemeldet_am, now()) where empfaenger_id = e.empfaenger_id;
  if e.contact_id is not null then
    insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
    values ('nl:' || e.empfaenger_id || ':unsubscribe', 'email_unsubscribe', now(), e.contact_id, 'newsletter',
            jsonb_build_object('newsletter_id', n.newsletter_id, 'betreff', n.betreff), 'not_required')
    on conflict (event_id) do nothing;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------
-- SES-Ereignisse (über SNS). p = SES-Event-JSON
-- ---------------------------------------------------------------------
create or replace function public.newsletter_ses_ereignis(p jsonb)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_typ text := coalesce(p->>'eventType', p->>'notificationType');
  e core.newsletter_empfaenger;
  v_hart boolean;
begin
  select * into e from core.newsletter_empfaenger where ses_message_id = p#>>'{mail,messageId}';
  if not found then return 'unbekannt'; end if;

  if v_typ = 'Delivery' then
    update core.newsletter_empfaenger set status = 'zugestellt', zugestellt_am = now()
     where empfaenger_id = e.empfaenger_id and status = 'gesendet';
    if not e.test and e.contact_id is not null then
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      values ('nl:' || e.empfaenger_id || ':delivered', 'email_delivered', now(), e.contact_id, 'newsletter',
              jsonb_build_object('newsletter_id', e.newsletter_id), 'not_required')
      on conflict (event_id) do nothing;
    end if;
  elsif v_typ = 'Bounce' then
    v_hart := p#>>'{bounce,bounceType}' = 'Permanent';
    if v_hart then
      update core.newsletter_empfaenger set status = 'bounce', fehler = left(p#>>'{bounce,bouncedRecipients,0,diagnosticCode}', 500)
       where empfaenger_id = e.empfaenger_id;
      perform core.newsletter_entziehen(e.contact_id, e.email, 'bounce', 'bounce');
    end if;
    if not e.test and e.contact_id is not null then
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      values ('nl:' || e.empfaenger_id || ':bounce', 'email_bounce', now(), e.contact_id, 'newsletter',
              jsonb_build_object('newsletter_id', e.newsletter_id, 'hard', v_hart), 'not_required')
      on conflict (event_id) do nothing;
    end if;
  elsif v_typ = 'Complaint' then
    update core.newsletter_empfaenger set status = 'beschwerde' where empfaenger_id = e.empfaenger_id;
    perform core.newsletter_entziehen(e.contact_id, e.email, 'beschwerde', 'complaint');
    if not e.test and e.contact_id is not null then
      insert into core.events (event_id, event_name, occurred_at, contact_id, source, properties, consent_state)
      values ('nl:' || e.empfaenger_id || ':complaint', 'email_complaint', now(), e.contact_id, 'newsletter',
              jsonb_build_object('newsletter_id', e.newsletter_id), 'not_required')
      on conflict (event_id) do nothing;
    end if;
  end if;
  return coalesce(v_typ, 'ohne Typ');
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.dashboard_newsletter_uebersicht()', 'public.dashboard_newsletter(uuid)', 'public.dashboard_newsletter_zielgruppe(text[])',
    'public.dashboard_newsletter_speichern(jsonb, text)', 'public.dashboard_newsletter_test(uuid, text[], text)',
    'public.dashboard_newsletter_senden(uuid, text)', 'public.dashboard_newsletter_abbrechen(uuid)',
    'public.dashboard_newsletter_loeschen(uuid)', 'public.dashboard_newsletter_liste(jsonb, text)',
    'public.newsletter_versand_holen(integer)', 'public.newsletter_versand_ergebnis(jsonb)', 'public.newsletter_status_setzen(jsonb)',
    'public.newsletter_klick(text, integer, text)', 'public.newsletter_abmelden(text)', 'public.newsletter_ses_ereignis(jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
