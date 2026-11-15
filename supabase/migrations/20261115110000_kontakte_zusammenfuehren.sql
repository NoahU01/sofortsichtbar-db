-- =====================================================================
-- Zwei Kontakte derselben Person zusammenführen.
--
-- p_behalten bleibt, p_weg wird danach gelöscht. Alles, was an p_weg hängt
-- (Kennungen, Events, Einwilligungen, Calls, LinkedIn-Person), wandert zu
-- p_behalten. Leere Felder von p_behalten werden aus p_weg gefüllt, Tags
-- vereinigt, Notizen angehängt. Herkunft und Status von p_behalten gelten,
-- solange gesetzt. Eine Newsletter-Erlaubnis von p_weg (mit Grundlage)
-- bleibt erhalten – sie gehört der Person, nicht dem Datensatz.
-- =====================================================================
create or replace function core.kontakte_zusammenfuehren(p_behalten uuid, p_weg uuid)
returns uuid
language plpgsql set search_path = ''
as $$
declare
  b core.contacts;
  w core.contacts;
begin
  if p_behalten = p_weg then raise exception 'zweimal derselbe Kontakt'; end if;
  select * into b from core.contacts where contact_id = p_behalten for update;
  if not found then raise exception 'Kontakt % nicht gefunden', p_behalten; end if;
  select * into w from core.contacts where contact_id = p_weg for update;
  if not found then raise exception 'Kontakt % nicht gefunden', p_weg; end if;

  update core.identities        set contact_id = p_behalten where contact_id = p_weg;
  update core.events            set contact_id = p_behalten where contact_id = p_weg;
  update core.consents          set contact_id = p_behalten where contact_id = p_weg;
  update core.calls             set contact_id = p_behalten where contact_id = p_weg;
  update core.linkedin_personen set contact_id = p_behalten where contact_id = p_weg;

  -- E-Mail ist eindeutig: erst beim Wegfallenden leeren
  update core.contacts set email = null where contact_id = p_weg;

  update core.contacts c
     set email           = coalesce(b.email, w.email),
         titel           = coalesce(b.titel, w.titel),
         vorname         = coalesce(b.vorname, w.vorname),
         nachname        = coalesce(b.nachname, w.nachname),
         telefon         = coalesce(b.telefon, w.telefon),
         position        = coalesce(b.position, w.position),
         company_id      = coalesce(b.company_id, w.company_id),
         zielgruppe      = coalesce(b.zielgruppe, w.zielgruppe),
         paketinteresse  = coalesce(b.paketinteresse, w.paketinteresse),
         owner           = coalesce(b.owner, w.owner),
         lost_grund      = coalesce(b.lost_grund, w.lost_grund),
         lifecycle_stage = case when b.lifecycle_stage = 'lead' then w.lifecycle_stage else b.lifecycle_stage end,
         herkunft        = coalesce(b.herkunft, w.herkunft),
         tags            = (select coalesce(array_agg(distinct t), '{}') from unnest(b.tags || w.tags) t),
         notizen         = nullif(concat_ws(E'\n\n', b.notizen, w.notizen), ''),
         newsletter_erlaubt   = b.newsletter_erlaubt or w.newsletter_erlaubt,
         newsletter_grundlage = case when b.newsletter_erlaubt then b.newsletter_grundlage
                                     when w.newsletter_erlaubt then w.newsletter_grundlage end,
         newsletter_seit      = case when b.newsletter_erlaubt then b.newsletter_seit
                                     when w.newsletter_erlaubt then w.newsletter_seit end,
         created_at      = least(b.created_at, w.created_at)
   where c.contact_id = p_behalten;

  delete from core.contacts where contact_id = p_weg;
  return p_behalten;
end $$;
revoke execute on function core.kontakte_zusammenfuehren(uuid, uuid) from public, anon, authenticated;
