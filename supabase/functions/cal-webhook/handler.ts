/**
 * Cal.com-Webhook: Signatur prüfen, dann an die Datenbank übergeben.
 *
 * Cal.com signiert den rohen Body mit HMAC-SHA256 (Schlüssel = Secret aus
 * den Webhook-Einstellungen) und schickt das Ergebnis im Header
 * x-cal-signature-256. Ohne gültige Signatur wird nichts gespeichert.
 *
 * Ohne Deno-Abhängigkeiten, damit es sich lokal mit Node testen lässt.
 */

export type Abhaengigkeiten = {
  secret: string | undefined;
  speichern: (payload: unknown) => Promise<unknown>;
};

const MAX_BODY = 1_000_000;

async function hmac(secret: string, body: string): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
}

const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const base64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));

/** Vergleich in konstanter Zeit. */
function gleich(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

const text = (status: number, t: string) => new Response(t, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  if (req.method !== "POST") return text(405, "nur POST");
  if (!d.secret) {
    console.error("[cal-webhook] CAL_WEBHOOK_SECRET fehlt");
    return text(500, "nicht konfiguriert");
  }

  const body = await req.text();
  if (body.length > MAX_BODY) return text(413, "zu groß");

  const sig = (req.headers.get("x-cal-signature-256") ?? "").trim().replace(/^sha256=/i, "");
  const mac = await hmac(d.secret, body);
  // Cal.com sendet hex; base64 als Rückfall, falls sich das ändert.
  if (!sig || !(gleich(sig.toLowerCase(), hex(mac)) || gleich(sig, base64(mac)))) {
    return text(401, "Signatur ungültig");
  }

  let payload: unknown;
  try { payload = JSON.parse(body); } catch { return text(400, "kein JSON"); }

  try {
    return Response.json(await d.speichern(payload));
  } catch (err) {
    // 5xx → Cal.com darf es erneut versuchen; die Annahme ist idempotent.
    console.error("[cal-webhook]", err);
    return text(500, "Speichern fehlgeschlagen");
  }
}
