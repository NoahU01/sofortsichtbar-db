/**
 * Brücke zwischen Daniels Dashboard (empiria-dashboard) und der
 * sofort-sichtbar-Datenbank.
 *
 * Das Dashboard schickt das Login-Token seiner eigenen Supabase-Anmeldung mit.
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
const ORIGIN = /^(https:\/\/empiria-dashboard(-[a-z0-9-]+)?\.vercel\.app|http:\/\/(localhost|127\.0\.0\.1)(:\d+)?)$/;
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
