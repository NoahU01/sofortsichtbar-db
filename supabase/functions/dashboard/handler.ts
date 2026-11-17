/**
 * Zugang zur sofort-sichtbar-Datenbank für zwei Oberflächen:
 *   - das eigene Cockpit (Login über dieses Supabase-Projekt)
 *   - Daniels Dashboard (empiria-dashboard, Login über dessen Supabase-Projekt)
 *
 * Beide schicken das Login-Token ihrer Anmeldung mit.
 * Hier wird geprüft:
 *   1. Ist das Token beim Dashboard gültig? → E-Mail der Person
 *   2. Steht die E-Mail in core.dashboard_zugang?
 * Erst dann wird die gewünschte Aktion ausgeführt. Treffer in Suchausschnitten
 * sind mit ⟦ ⟧ markiert (kein HTML) – das Dashboard escaped alles und setzt
 * die Markierung selbst.
 *
 * Ohne Deno-Abhängigkeiten, damit es sich lokal mit Node testen lässt.
 */

export type Abhaengigkeiten = {
  /** Gibt die E-Mail zum Token zurück, oder null, wenn ungültig. */
  pruefeLogin: (token: string) => Promise<string | null>;
  rpc: (funktion: string, args: Record<string, unknown>) => Promise<unknown>;
};

const MAX_BODY = 1_000_000;
const ORIGIN = /^(https:\/\/(empiria-dashboard|sofortsichtbar-cockpit)(-[a-z0-9-]+)?\.vercel\.app|https:\/\/cockpit\.sofortsichtbar\.de|http:\/\/(localhost|127\.0\.0\.1)(:\d+)?)$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function cors(origin: string | null): Record<string, string> {
  if (!origin || !ORIGIN.test(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

const json = (status: number, daten: unknown, h: Record<string, string>) =>
  new Response(JSON.stringify(daten), { status, headers: { ...h, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });

const uuidOderNull = (v: unknown) => (typeof v === "string" && UUID.test(v) ? v : null);
const datumOderNull = (v: unknown) => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? new Date(v).toISOString() : null);
const textOderLeer = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : "");
const listen = (v: unknown) => (Array.isArray(v) ? v : []).slice(0, 30).map((t) => textOderLeer(t, 60).trim()).filter(Boolean);

/** Aktion → RPC-Aufruf. Wirft bei ungültiger Eingabe einen Error mit .status = 400. */
function aktion(name: string, b: Record<string, unknown>, email: string): [string, Record<string, unknown>] | null {
  const fehler = (m: string) => Object.assign(new Error(m), { status: 400 });
  switch (name) {
    case "termine": {
      const jetzt = Date.now();
      return ["dashboard_termine", {
        p_von: datumOderNull(b.von) ?? new Date(jetzt - 14 * 864e5).toISOString(),
        p_bis: datumOderNull(b.bis) ?? new Date(jetzt + 864e5).toISOString(),
      }];
    }
    case "kontakte":
      return ["dashboard_kontakte", { p_suche: textOderLeer(b.suche, 100) }];
    case "calls":
      return ["dashboard_calls", { p_suche: textOderLeer(b.suche, 200), p_contact_id: uuidOderNull(b.contact_id) }];
    case "call": {
      const id = uuidOderNull(b.call_id);
      if (!id) throw fehler("call_id fehlt");
      return ["dashboard_call", { p_call_id: id }];
    }
    case "loeschen": {
      const id = uuidOderNull(b.call_id);
      if (!id) throw fehler("call_id fehlt");
      return ["dashboard_call_loeschen", { p_call_id: id }];
    }
    case "speichern": {
      const c = (b.call && typeof b.call === "object" ? b.call : {}) as Record<string, unknown>;
      const transkript = textOderLeer(c.transkript, 500_000).trim();
      if (!transkript) throw fehler("Transkript fehlt");
      if (c.aufnahme_zugestimmt !== true) throw fehler("Zustimmung zur Aufnahme fehlt");
      if (!uuidOderNull(c.contact_id) && !textOderLeer(c.email, 200).includes("@") && !textOderLeer(c.booking_uid, 100)) {
        throw fehler("Kontakt fehlt (Termin, bestehender Kontakt oder E-Mail)");
      }
      return ["dashboard_call_speichern", {
        p: {
          call_id: uuidOderNull(c.call_id),
          contact_id: uuidOderNull(c.contact_id),
          email: textOderLeer(c.email, 200),
          vorname: textOderLeer(c.vorname, 100),
          nachname: textOderLeer(c.nachname, 100),
          booking_uid: textOderLeer(c.booking_uid, 100),
          stattgefunden_am: datumOderNull(c.stattgefunden_am),
          titel: textOderLeer(c.titel, 300),
          transkript,
          zusammenfassung: textOderLeer(c.zusammenfassung, 50_000),
          aufnahme_zugestimmt: true,
        },
        p_von: email,
      }];
    }
    case "website": {
      const tage = Math.min(Math.max(Number(b.tage) || 30, 1), 400);
      const bis = Date.now();
      return ["dashboard_website", {
        p_von: datumOderNull(b.von) ?? new Date(bis - tage * 864e5).toISOString(),
        p_bis: datumOderNull(b.bis) ?? new Date(bis).toISOString(),
        p_intern: b.intern === true,
      }];
    }
    case "suche": {
      const tage = Math.min(Math.max(Number(b.tage) || 30, 1), 480);
      const bis = new Date(), von = new Date(bis.getTime() - (tage - 1) * 864e5);
      return ["dashboard_suche", { p_von: von.toISOString().slice(0, 10), p_bis: bis.toISOString().slice(0, 10) }];
    }
    case "postfach":
      return ["dashboard_postfach", { p_tage: Math.min(Math.max(Number(b.tage) || 30, 1), 365) }];
    case "absender_uebernehmen": {
      const mail = textOderLeer(b.email, 200).trim();
      if (!mail.includes("@")) throw fehler("E-Mail fehlt");
      return ["dashboard_absender_uebernehmen", { p_email: mail, p_name: textOderLeer(b.name, 200) }];
    }
    case "absender_ignorieren": {
      const mail = textOderLeer(b.email, 200).trim();
      if (!mail.includes("@")) throw fehler("E-Mail fehlt");
      return ["dashboard_absender_ignorieren", { p_email: mail }];
    }
    case "kontakte_liste": {
      const filter = textOderLeer(b.filter, 60);
      if (filter && !/^(newsletter|ohne_position|name_unvollstaendig|herkunft:[a-z_]+|tag:[^\n]{1,60})$/u.test(filter)) throw fehler("unbekannter Filter");
      return ["dashboard_kontakte_liste", { p_suche: textOderLeer(b.suche, 100), p_filter: filter || null }];
    }
    case "kontakt": {
      const id = uuidOderNull(b.contact_id);
      if (!id) throw fehler("contact_id fehlt");
      return ["dashboard_kontakt", { p_contact_id: id }];
    }
    case "kontakt_speichern": {
      const k = (b.kontakt && typeof b.kontakt === "object" ? b.kontakt : {}) as Record<string, unknown>;
      const id = uuidOderNull(k.contact_id);
      if (!id) throw fehler("contact_id fehlt");
      const p: Record<string, unknown> = { contact_id: id };
      for (const [f, max] of [["titel", 50], ["vorname", 100], ["nachname", 100], ["telefon", 50], ["position", 300], ["lifecycle_stage", 20],
                              ["zielgruppe", 100], ["paketinteresse", 20], ["lost_grund", 300], ["owner", 50], ["notizen", 20_000],
                              ["herkunft", 30], ["newsletter_grundlage", 20]] as const) {
        p[f] = textOderLeer(k[f], max);
      }
      p.tags = (Array.isArray(k.tags) ? k.tags : []).slice(0, 30).map((t) => textOderLeer(t, 40)).filter(Boolean);
      p.newsletter_erlaubt = k.newsletter_erlaubt === true;
      if (p.newsletter_erlaubt && !["einwilligung", "bestandskunde"].includes(String(p.newsletter_grundlage))) {
        throw fehler("Newsletter erlaubt nur mit Grundlage (Einwilligung oder Bestandskunde)");
      }
      return ["dashboard_kontakt_speichern", { p, p_von: email }];
    }
    case "kontakt_loeschen": {
      const id = uuidOderNull(b.contact_id);
      if (!id) throw fehler("contact_id fehlt");
      return ["dashboard_kontakt_loeschen", { p_contact_id: id }];
    }
    case "listen":
      return ["dashboard_listen", {}];
    case "liste_zuordnen": {
      const ids = (Array.isArray(b.contact_ids) ? b.contact_ids : []).map(uuidOderNull).filter((x): x is string => !!x);
      if (!ids.length) throw fehler("keine Kontakte ausgewählt");
      if (ids.length > 5000) throw fehler("zu viele Kontakte auf einmal (max. 5000)");
      const liste = textOderLeer(b.liste, 60).trim();
      if (!liste) throw fehler("Name der Liste fehlt");
      const was = textOderLeer(b.was, 20);
      if (was !== "hinzufuegen" && was !== "entfernen") throw fehler("unbekannte Aktion");
      return ["dashboard_liste_zuordnen", { p_contact_ids: ids, p_liste: liste, p_aktion: was }];
    }
    case "liste_loeschen": {
      const liste = textOderLeer(b.liste, 60).trim();
      if (!liste) throw fehler("Name der Liste fehlt");
      return ["dashboard_liste_loeschen", { p_liste: liste }];
    }
    case "newsletter_uebersicht":
      return ["dashboard_newsletter_uebersicht", {}];
    case "newsletter": {
      const id = uuidOderNull(b.newsletter_id);
      if (!id) throw fehler("newsletter_id fehlt");
      return ["dashboard_newsletter", { p_newsletter_id: id }];
    }
    case "newsletter_zielgruppe":
      return ["dashboard_newsletter_zielgruppe", { p_listen: listen(b.listen) }];
    case "newsletter_speichern": {
      const n = (b.newsletter && typeof b.newsletter === "object" ? b.newsletter : {}) as Record<string, unknown>;
      return ["dashboard_newsletter_speichern", {
        p: {
          newsletter_id: uuidOderNull(n.newsletter_id),
          titel: textOderLeer(n.titel, 200), betreff: textOderLeer(n.betreff, 300), vorschautext: textOderLeer(n.vorschautext, 300),
          inhalt: textOderLeer(n.inhalt, 100_000), listen: listen(n.listen),
          klicks_messen: n.klicks_messen !== false, utm: n.utm !== false, utm_kampagne: textOderLeer(n.utm_kampagne, 100),
        },
        p_von: email,
      }];
    }
    case "newsletter_test": {
      const id = uuidOderNull(b.newsletter_id);
      if (!id) throw fehler("newsletter_id fehlt");
      const mails = (Array.isArray(b.emails) ? b.emails : []).slice(0, 5).map((m) => textOderLeer(m, 200).trim()).filter((m) => m.includes("@"));
      if (!mails.length) throw fehler("Test-Adresse fehlt");
      return ["dashboard_newsletter_test", { p_newsletter_id: id, p_emails: mails, p_von: email }];
    }
    case "newsletter_senden":
    case "newsletter_abbrechen":
    case "newsletter_loeschen": {
      const id = uuidOderNull(b.newsletter_id);
      if (!id) throw fehler("newsletter_id fehlt");
      if (name === "newsletter_senden" && b.bestaetigt !== true) throw fehler("Versand nicht bestätigt");
      return ["dashboard_" + name, name === "newsletter_senden" ? { p_newsletter_id: id, p_von: email } : { p_newsletter_id: id }];
    }
    case "newsletter_liste": {
      if (b.bestaetigt !== true) throw fehler("Bitte bestätigen, dass die Grundlage für alle Personen vorliegt");
      const grundlage = textOderLeer(b.grundlage, 20);
      if (grundlage !== "bestandskunde" && grundlage !== "einwilligung") throw fehler("Grundlage fehlt");
      const liste = textOderLeer(b.liste, 60).trim();
      if (!liste) throw fehler("Name der Liste fehlt");
      const roh = Array.isArray(b.personen) ? b.personen : [];
      if (!roh.length) throw fehler("keine Personen");
      if (roh.length > 10_000) throw fehler("zu viele Personen auf einmal (max. 10.000)");
      const personen = roh.filter((x): x is Record<string, unknown> => !!x && typeof x === "object").map((x) => ({
        email: textOderLeer(x.email, 200).trim(), vorname: textOderLeer(x.vorname, 100), nachname: textOderLeer(x.nachname, 100),
        name: textOderLeer(x.name, 200), firma: textOderLeer(x.firma, 200),
      }));
      return ["dashboard_newsletter_liste", { p: { liste, grundlage, personen }, p_von: email }];
    }
    case "linkedin":
      return ["dashboard_linkedin", {}];
    case "linkedin_follower": {
      const roh = Array.isArray(b.follower) ? b.follower : [];
      if (!roh.length) throw fehler("keine Follower");
      if (roh.length > 5000) throw fehler("zu viele Follower auf einmal (max. 5000)");
      const follower = roh
        .filter((x): x is Record<string, unknown> => !!x && typeof x === "object")
        .map((x) => ({
          name: textOderLeer(x.name, 200).trim(),
          unternehmen: textOderLeer(x.unternehmen, 200).trim(),
          position: textOderLeer(x.position, 300).trim(),
          profil_url: textOderLeer(x.profil_url, 300).trim(),
          folgt_seit: /^\d{4}-\d{2}-\d{2}$/.test(textOderLeer(x.folgt_seit, 10)) ? textOderLeer(x.folgt_seit, 10) : "",
        }))
        .filter((x) => x.name);
      return ["dashboard_linkedin_follower", { p: { follower }, p_von: email }];
    }
    case "linkedin_erfassen": {
      const roh = Array.isArray(b.personen) ? b.personen : [];
      if (roh.length > 5000) throw fehler("zu viele Personen auf einmal (max. 5000)");
      const personen = roh
        .filter((x): x is Record<string, unknown> => !!x && typeof x === "object")
        .map((x) => ({ name: textOderLeer(x.name, 200).trim(), position: textOderLeer(x.position, 300).trim(), art: textOderLeer(x.art, 20) }))
        .filter((x) => x.name);
      const id = uuidOderNull(b.beitrag_id);
      const rb = (b.beitrag && typeof b.beitrag === "object" ? b.beitrag : {}) as Record<string, unknown>;
      let beitrag: Record<string, unknown> | null = null;
      if (!id) {
        const kanal = textOderLeer(rb.kanal, 20);
        if (kanal !== "firmenseite" && kanal !== "daniel") throw fehler("Kanal fehlt (firmenseite oder daniel)");
        const titel = textOderLeer(rb.titel, 300).trim();
        if (!titel) throw fehler("Titel des Beitrags fehlt");
        const url = textOderLeer(rb.url, 500).trim();
        if (url && !/^https:\/\/([a-z]+\.)?linkedin\.com\//i.test(url)) throw fehler("Link muss ein LinkedIn-Link sein");
        const datum = textOderLeer(rb.veroeffentlicht, 10);
        beitrag = { kanal, titel, url, veroeffentlicht: /^\d{4}-\d{2}-\d{2}$/.test(datum) ? datum : "" };
      }
      const weitere = Math.min(Math.max(Math.trunc(Number(b.weitere) || 0), 0), 50);
      return ["dashboard_linkedin_erfassen", { p: { beitrag_id: id, beitrag, personen, weitere }, p_von: email }];
    }
    case "linkedin_person": {
      const id = uuidOderNull(b.person_id);
      if (!id) throw fehler("person_id fehlt");
      const was = textOderLeer(b.was, 20);
      if (!["zuordnen", "loesen", "ignorieren", "zurueckholen", "kontakt_anlegen"].includes(was)) throw fehler("unbekannte Aktion");
      const kontakt = uuidOderNull(b.contact_id);
      if (was === "zuordnen" && !kontakt) throw fehler("contact_id fehlt");
      return ["dashboard_linkedin_person", { p_person_id: id, p_aktion: was, p_contact_id: kontakt }];
    }
    case "linkedin_zuordnen": {
      const id = uuidOderNull(b.beitrag_id);
      if (!id) throw fehler("beitrag_id fehlt");
      const z = textOderLeer(b.zugehoerigkeit, 20);
      if (!["sofortsichtbar", "empiria", "unklar"].includes(z)) throw fehler("unbekannte Zugehörigkeit");
      return ["dashboard_linkedin_zuordnen", { p_beitrag_id: id, p_zugehoerigkeit: z }];
    }
    case "linkedin_beitrag_loeschen": {
      const id = uuidOderNull(b.beitrag_id);
      if (!id) throw fehler("beitrag_id fehlt");
      return ["dashboard_linkedin_beitrag_loeschen", { p_beitrag_id: id }];
    }
    default:
      return null;
  }
}

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const h = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: h });
  if (req.method !== "POST") return json(405, { fehler: "nur POST" }, h);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { fehler: "nicht angemeldet" }, h);

  const text = await req.text();
  if (text.length > MAX_BODY) return json(413, { fehler: "zu groß" }, h);
  let b: Record<string, unknown>;
  try { b = JSON.parse(text); } catch { return json(400, { fehler: "kein JSON" }, h); }
  if (!b || typeof b !== "object") return json(400, { fehler: "kein JSON" }, h);

  let email: string | null;
  try { email = await d.pruefeLogin(token); } catch (e) { console.error("[dashboard] Login-Prüfung", e); return json(502, { fehler: "Login-Prüfung nicht erreichbar" }, h); }
  if (!email) return json(401, { fehler: "nicht angemeldet" }, h);

  try {
    if (!(await d.rpc("dashboard_darf", { p_email: email }))) return json(403, { fehler: "kein Zugang zu sofort sichtbar", email }, h);
    if (b.aktion === "ich") return json(200, { email }, h);
    const a = aktion(String(b.aktion ?? ""), b, email);
    if (!a) return json(400, { fehler: "unbekannte Aktion" }, h);
    return json(200, await d.rpc(a[0], a[1]), h);
  } catch (e) {
    const status = (e as { status?: number }).status;
    if (status === 400) return json(400, { fehler: (e as Error).message }, h);
    console.error("[dashboard]", e);
    return json(500, { fehler: "Datenbankfehler" }, h);
  }
}
