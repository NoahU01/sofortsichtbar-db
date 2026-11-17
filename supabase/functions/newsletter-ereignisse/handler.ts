/**
 * Edge Function newsletter-ereignisse – nimmt SES-Ereignisse über Amazon SNS
 * entgegen (Zustellung, Bounce, Spam-Beschwerde) und gibt sie an
 * public.newsletter_ses_ereignis weiter.
 *
 * Absicherung: Die SNS-Abo-URL enthält einen geheimen Schlüssel (?k=…, Secret
 * NEWSLETTER_EREIGNIS_KEY). Abo-Bestätigungen werden nur für SNS-Adressen
 * von amazonaws.com aufgerufen.
 */
export type Abhaengigkeiten = {
  env: { NEWSLETTER_EREIGNIS_KEY?: string };
  fetch: typeof fetch;
  rpc: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
};

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const ok = (x: unknown = { ok: true }, s = 200) => new Response(JSON.stringify(x), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return ok({ fehler: "nur POST" }, 405);
  const k = new URL(req.url).searchParams.get("k") ?? "";
  if (!d.env.NEWSLETTER_EREIGNIS_KEY || !gleich(k, d.env.NEWSLETTER_EREIGNIS_KEY)) return ok({ fehler: "nicht berechtigt" }, 401);

  let b: Record<string, string>;
  try { b = JSON.parse(await req.text()); } catch { return ok({ fehler: "kein JSON" }, 400); }

  if (b.Type === "SubscriptionConfirmation") {
    const u = new URL(b.SubscribeURL ?? "");
    if (u.protocol !== "https:" || !/^sns\.[a-z0-9-]+\.amazonaws\.com$/.test(u.hostname)) return ok({ fehler: "ungültige Bestätigungsadresse" }, 400);
    const r = await d.fetch(u.toString());
    return ok({ bestaetigt: r.ok });
  }
  if (b.Type !== "Notification") return ok({ ignoriert: b.Type ?? "unbekannt" });

  let ereignis: unknown;
  try { ereignis = JSON.parse(b.Message); } catch { return ok({ fehler: "Message kein JSON" }, 400); }
  const typ = await d.rpc("newsletter_ses_ereignis", { p: ereignis });
  return ok({ typ });
}
