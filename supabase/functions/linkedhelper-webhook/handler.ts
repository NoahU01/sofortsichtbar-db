/**
 * Edge Function linkedhelper-webhook – nimmt Profile aus Daniels
 * LinkedHelper-Kampagnen entgegen („Send person to webhook“ bzw. Plugin
 * „Send replied to Webhook“) und gibt sie an public.ingest_linkedhelper weiter.
 *
 *   POST /functions/v1/linkedhelper-webhook?k=<LINKEDHELPER_KEY>&art=profil|antwort
 *
 * Gespeichert wird zunächst die rohe Sendung (die genauen Feldnamen kennen wir
 * erst nach der ersten Testsendung); bekannte LinkedIn-Profile werden sofort
 * dem Kontakt zugeordnet. Absicherung: geheimer Schlüssel in der URL.
 */
export type Abhaengigkeiten = {
  env: { LINKEDHELPER_KEY?: string };
  rpc: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
};

const MAX = 1_000_000;

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const ok = (x: unknown = { ok: true }, s = 200) => new Response(JSON.stringify(x), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return ok({ fehler: "nur POST" }, 405);
  const u = new URL(req.url);
  const k = u.searchParams.get("k") ?? "";
  if (!d.env.LINKEDHELPER_KEY || !gleich(k, d.env.LINKEDHELPER_KEY)) return ok({ fehler: "nicht berechtigt" }, 401);
  const art = u.searchParams.get("art") === "antwort" ? "antwort" : "profil";

  const text = await req.text();
  if (text.length > MAX) return ok({ fehler: "zu groß" }, 413);
  let daten: unknown;
  const typ = req.headers.get("content-type") ?? "";
  if (typ.includes("application/x-www-form-urlencoded")) {
    daten = Object.fromEntries(new URLSearchParams(text));
  } else {
    try { daten = JSON.parse(text); } catch { daten = { roh: text.slice(0, 50_000) }; }
  }
  if (daten === null || typeof daten !== "object") daten = { wert: daten };
  // Manche Tools schicken mehrere Profile als Liste
  const liste = Array.isArray(daten) ? daten.slice(0, 200) : [daten];
  const ergebnisse = [];
  for (const p of liste) ergebnisse.push(await d.rpc("ingest_linkedhelper", { p: p ?? {}, p_art: art }));
  return ok({ ok: true, anzahl: liste.length, ergebnisse });
}
