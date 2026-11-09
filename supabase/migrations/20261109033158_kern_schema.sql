-- =====================================================================
-- Kern-Schema der Sofortsichtbar-Datenbank
--
--   core.companies    Firmen / Vermittlerbüros
--   core.contacts     Personen (= das CRM)
--   core.identities   alle bekannten Kennungen je Person (visitor_id, LinkedIn-URN …)
--   core.event_types  fester Event-Katalog
--   core.events       EINE Timeline für alle Quellen
--   core.consents     Einwilligungs-Log (nur anhängen, nie überschreiben)
--
-- Weitere Schemas werden hier nur angelegt und später gefüllt:
--   raw (Roh-Payloads je Quelle), analytics (Aggregate), scoring, agent.
--
-- Zugriff: Nichts davon ist für anon/authenticated sichtbar. Geschrieben und
-- gelesen wird serverseitig (Edge Functions mit Service-Role). RLS ist auf
-- allen Tabellen an, ohne Policies – damit ist ein Frontend-Zugriff zu, bis
-- wir ihn bewusst öffnen.
-- Alle Zeitstempel sind timestamptz (UTC).
-- =====================================================================

create schema if not exists core;
create schema if not exists raw;
create schema if not exists analytics;
create schema if not exists scoring;
create schema if not exists agent;

revoke all on schema core, raw, analytics, scoring, agent from public, anon, authenticated;
grant usage on schema core, raw, analytics, scoring, agent to service_role;

-- Neue Tabellen in diesen Schemas automatisch für service_role freigeben.
alter default privileges in schema core, raw, analytics, scoring, agent
  grant all on tables to service_role;
alter default privileges in schema core, raw, analytics, scoring, agent
  grant all on sequences to service_role;
alter default privileges in schema core, raw, analytics, scoring, agent
  grant execute on functions to service_role;

-- ---------------------------------------------------------------------
-- Hilfsfunktion: updated_at pflegen
-- ---------------------------------------------------------------------
create or replace function core.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Firmen
-- ---------------------------------------------------------------------
create table core.companies (
  company_id      uuid primary key default gen_random_uuid(),
  name            text not null,
  domain          text,                 -- ohne www, klein geschrieben
  buero_groesse   text,                 -- Freitext, bis die Kategorien mit Daniel stehen
  mitarbeiter     integer check (mitarbeiter >= 0),
  bestandsgroesse text,
  ort             text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index companies_domain_key on core.companies (domain) where domain is not null;
create trigger companies_updated_at before update on core.companies
  for each row execute function core.set_updated_at();

-- ---------------------------------------------------------------------
-- Kontakte (das CRM)
-- ---------------------------------------------------------------------
create table core.contacts (
  contact_id      uuid primary key default gen_random_uuid(),
  email           text,                 -- normalisiert per Trigger
  vorname         text,
  nachname        text,
  telefon         text,
  company_id      uuid references core.companies on delete set null,
  lifecycle_stage text not null default 'lead'
                  check (lifecycle_stage in ('lead','mql','sql','kunde','verloren')),
  zielgruppe      text,                 -- Makler, Ausschließlichkeit, Mehrfachagent, Finanzberater …
  paketinteresse  text check (paketinteresse in ('fokus','team','komplett')),
  lost_grund      text,
  owner           text,                 -- wer kümmert sich (noah / daniel)
  notizen         text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index contacts_email_key on core.contacts (email) where email is not null;
create index contacts_company_idx on core.contacts (company_id);

create or replace function core.normalize_contact()
returns trigger language plpgsql as $$
begin
  new.email := nullif(lower(trim(new.email)), '');
  return new;
end $$;
create trigger contacts_normalize before insert or update of email on core.contacts
  for each row execute function core.normalize_contact();
create trigger contacts_updated_at before update on core.contacts
  for each row execute function core.set_updated_at();

-- ---------------------------------------------------------------------
-- Identitäten: ein Kontakt hat viele Kennungen
-- ---------------------------------------------------------------------
create table core.identities (
  identity_id     bigint generated always as identity primary key,
  contact_id      uuid not null references core.contacts on delete cascade,
  identity_type   text not null check (identity_type in (
                    'visitor_id','email','telefon',
                    'linkedin_urn','linkedin_profile_url',
                    'youtube_channel','tiktok_username','instagram_username','facebook_name',
                    'gclid','gbraid','wbraid','fbclid','li_fat_id','ttclid')),
  identity_value  text not null,
  -- unconfirmed = nur per Name zugeordnet (LinkedIn-Mails, Kommentare);
  -- zählt erst, wenn ein Mensch bestätigt.
  confidence      text not null default 'confirmed'
                  check (confidence in ('confirmed','unconfirmed')),
  source          text not null,        -- wo die Verknüpfung entstand (formular, newsletter_klick, cal …)
  first_seen      timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  unique (identity_type, identity_value)
);
create index identities_contact_idx on core.identities (contact_id);

-- ---------------------------------------------------------------------
-- Event-Katalog: nur diese Namen sind erlaubt
-- ---------------------------------------------------------------------
create table core.event_types (
  event_name   text primary key check (event_name ~ '^[a-z][a-z0-9_]*$'),
  quelle       text not null,           -- welche Quelle das Event typischerweise liefert
  beschreibung text not null
);

-- Startkatalog. Erweitern = neue Migration, nie frei erfinden.
insert into core.event_types (event_name, quelle, beschreibung) values
  -- Website / Funnels (eigenes Tracking)
  ('page_view',            'website',     'Seitenaufruf; Seitentyp in page_type'),
  ('session_start',        'website',     'Neue Sitzung; UTMs, Referrer und Click-IDs in properties'),
  ('section_view',         'website',     'Sektion war sichtbar; Sektions-ID in properties.section'),
  ('section_time',         'website',     'Verweildauer je Sektion in Sekunden (properties.seconds)'),
  ('scroll_depth',         'website',     'Scrolltiefe erreicht (properties.percent)'),
  ('cta_click',            'website',     'Klick auf einen Call-to-Action'),
  ('form_start',           'website',     'Formular begonnen'),
  ('form_submit',          'website',     'Formular abgeschickt (Kontakt/Demo = Lead)'),
  ('file_download',        'website',     'Download / Lead-Magnet; Thema in properties'),
  ('funnel_start',         'funnel',      'Funnel begonnen'),
  ('funnel_step',          'funnel',      'Funnel-Schritt erreicht (properties.step)'),
  ('funnel_complete',      'funnel',      'Funnel abgeschlossen; Antworten in properties'),
  -- Newsletter (eigen)
  ('email_sent',           'newsletter',  'Mail an Versand-API übergeben'),
  ('email_delivered',      'newsletter',  'Zustellung bestätigt'),
  ('email_open',           'newsletter',  'Öffnungs-Pixel geladen (schwaches Signal)'),
  ('email_click',          'newsletter',  'Klick über eigenen Redirect; link_type in properties'),
  ('email_bounce',         'newsletter',  'Bounce; properties.hard = true/false'),
  ('email_complaint',      'newsletter',  'Als Spam markiert'),
  ('email_unsubscribe',    'newsletter',  'Abgemeldet'),
  -- Vertriebspostfach
  ('mail_received',        'postfach',    'Eingehende Mail eines Kontakts; Klassifikation in properties'),
  ('mail_sent',            'postfach',    'Ausgehende Vertriebsmail'),
  -- Termine (Cal.com)
  ('meeting_booked',       'cal',         'Termin gebucht'),
  ('meeting_canceled',     'cal',         'Termin abgesagt'),
  ('meeting_no_show',      'cal',         'Nicht erschienen'),
  -- Calls
  ('call_recorded',        'fireflies',   'Call-Transkript liegt vor; Summary/Action Items in properties'),
  -- Produkt
  ('product_login',        'produkt',     'Login ins Steuerungs-Dashboard'),
  ('product_post_planned', 'produkt',     'Posting eingeplant'),
  ('product_post_published','produkt',    'Posting veröffentlicht'),
  ('product_target_group_created','produkt','Neue Zielgruppe / Vertriebsstrecke angelegt'),
  -- Social, personenbezogen
  ('linkedin_message_received','linkedin_dma','Eingehende LinkedIn-DM'),
  ('linkedin_message_sent',    'linkedin_dma','Ausgehende LinkedIn-DM'),
  ('linkedin_connection',      'linkedin_dma','Vernetzung angenommen oder eingegangen'),
  ('linkedin_comment',         'linkedin',    'Kommentar auf einen Post (Company Page oder persönlich)'),
  ('linkedin_reaction',        'linkedin',    'Reaktion auf einen Post'),
  ('youtube_comment',          'youtube',     'Kommentar unter einem Video'),
  ('tiktok_comment',           'tiktok',      'Kommentar unter einem Video');

-- ---------------------------------------------------------------------
-- Events: eine Timeline für alles
-- ---------------------------------------------------------------------
create table core.events (
  -- Eindeutig je Quelle, damit erneutes Abrufen keine Duplikate erzeugt.
  -- Website: UUID aus dem Browser. Andere Quellen: '<quelle>:<quell-id>'.
  event_id      text primary key,
  event_name    text not null references core.event_types,
  occurred_at   timestamptz not null,
  contact_id    uuid references core.contacts on delete cascade,
  visitor_id    text,
  session_id    text,
  source        text not null,
  page_url      text,
  page_type     text,                   -- preis, produkt, referenz, blog, karriere, zielgruppe …
  properties    jsonb not null default '{}'::jsonb,
  consent_state text not null default 'unknown'
                check (consent_state in ('granted','denied','unknown','not_required')),
  ingested_at   timestamptz not null default now()
);
create index events_contact_time_idx on core.events (contact_id, occurred_at desc) where contact_id is not null;
create index events_visitor_idx      on core.events (visitor_id) where visitor_id is not null;
create index events_name_time_idx    on core.events (event_name, occurred_at desc);

-- ---------------------------------------------------------------------
-- Identity-Stitching
--   a) Neues Event mit bekannter visitor_id → sofort dem Kontakt zuordnen.
--   b) Neue bestätigte visitor_id-Identität → alle bisher anonymen Events
--      dieses Besuchers rückwirkend dem Kontakt zuordnen.
-- ---------------------------------------------------------------------
create or replace function core.events_attach_contact()
returns trigger language plpgsql as $$
begin
  if new.contact_id is null and new.visitor_id is not null then
    select i.contact_id into new.contact_id
      from core.identities i
     where i.identity_type = 'visitor_id'
       and i.identity_value = new.visitor_id
       and i.confidence = 'confirmed';
  end if;
  return new;
end $$;
create trigger events_attach_contact before insert on core.events
  for each row execute function core.events_attach_contact();

create or replace function core.identities_backfill_events()
returns trigger language plpgsql as $$
begin
  if new.identity_type = 'visitor_id' and new.confidence = 'confirmed' then
    update core.events
       set contact_id = new.contact_id
     where visitor_id = new.identity_value
       and contact_id is null;
  end if;
  return new;
end $$;
create trigger identities_backfill_events
  after insert or update of confidence, contact_id on core.identities
  for each row execute function core.identities_backfill_events();

-- ---------------------------------------------------------------------
-- Einwilligungen: nur anhängen. Der aktuelle Stand ist der jüngste Eintrag.
-- ---------------------------------------------------------------------
create table core.consents (
  consent_id    bigint generated always as identity primary key,
  contact_id    uuid not null references core.contacts on delete cascade,
  channel       text not null check (channel in ('email_marketing','tracking','telefon')),
  status        text not null check (status in ('granted','revoked')),
  source        text not null,          -- doi, formular, abmeldelink, complaint …
  occurred_at   timestamptz not null default now(),
  ip            inet,
  text_version  text                    -- Version des Einwilligungstexts
);
create index consents_contact_idx on core.consents (contact_id, channel, occurred_at desc);

create view core.consent_status with (security_invoker = true) as
select distinct on (contact_id, channel)
       contact_id, channel, status, source, occurred_at
  from core.consents
 order by contact_id, channel, occurred_at desc;

-- ---------------------------------------------------------------------
-- Löschen auf Knopfdruck: Kontakt samt allem, was an ihm hängt.
-- Events hängen per FK (cascade) am Kontakt; zusätzlich werden anonyme
-- Events seiner visitor_ids entfernt, die (noch) keinen contact_id tragen.
-- ---------------------------------------------------------------------
create or replace function core.delete_contact(p_contact_id uuid)
returns void language plpgsql as $$
begin
  delete from core.events e
   using core.identities i
   where i.contact_id = p_contact_id
     and i.identity_type = 'visitor_id'
     and e.visitor_id = i.identity_value;
  delete from core.contacts where contact_id = p_contact_id;  -- Rest per cascade
end $$;
revoke execute on function core.delete_contact(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Rechte + RLS
-- ---------------------------------------------------------------------
grant all on all tables    in schema core to service_role;
grant all on all sequences in schema core to service_role;

alter table core.companies   enable row level security;
alter table core.contacts    enable row level security;
alter table core.identities  enable row level security;
alter table core.event_types enable row level security;
alter table core.events      enable row level security;
alter table core.consents    enable row level security;
