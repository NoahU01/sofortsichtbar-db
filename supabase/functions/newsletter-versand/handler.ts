/**
 * Edge Function newsletter-versand – Logik (testbar ohne Deno).
 *
 * Läuft jede Minute per pg_cron (Header x-import-secret). Holt wartende
 * Empfänger (Testversand zuerst), rendert jede Mail einzeln (Platzhalter,
 * Klick-Links mit Token), schickt sie über SES und meldet das Ergebnis.
 * Höchstens MAX_RATE Mails pro Sekunde und ZEITBUDGET pro Lauf; der Rest
 * kommt im nächsten Lauf. Prüft außerdem den SES-Kontostand fürs Cockpit.
 */
import "../_shared/nl-render.js";
import { konto, sende, type Zugang } from "../_shared/ses.ts";

type Render = { render: (nl: unknown, k: unknown, o: unknown) => { html: string; text: string; links: string[]; betreff: string } };
const R = (globalThis as unknown as { nlRender: Render }).nlRender;

export type Env = {
  IMPORT_SECRET?: string; SES_ACCESS_KEY_ID?: string; SES_SECRET_ACCESS_KEY?: string; SES_REGION?: string;
  SES_CONFIG_SET?: string; NEWSLETTER_VON?: string; NEWSLETTER_VON_NAME?: string; NEWSLETTER_BASIS?: string;
};
export type Abhaengigkeiten = {
  env: Env; fetch: typeof fetch;
  rpc: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
  jetzt?: () => number; schlafen?: (ms: number) => Promise<void>;
  zeitbudgetMs?: number;
};

const MAX_RATE = 8;           // Mails pro Sekunde (SES erlaubt anfangs 1/s im Testmodus, 14/s danach)
const ZEITBUDGET = 45_000;
const SCHWUNG = 100;

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

type Zeile = {
  empfaenger_id: number; token: string; email: string; test: boolean;
  kontakt: Record<string, string | null>;
  newsletter: { newsletter_id: string; betreff: string; vorschautext: string; inhalt: string; klicks_messen: boolean; utm: boolean; utm_kampagne: string };
};

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const antwort = (status: number, x: unknown) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return antwort(405, { fehler: "nur POST" });
  if (!d.env.IMPORT_SECRET || !gleich(req.headers.get("x-import-secret") ?? "", d.env.IMPORT_SECRET)) return antwort(401, { fehler: "nicht berechtigt" });
  if (!d.env.SES_ACCESS_KEY_ID || !d.env.SES_SECRET_ACCESS_KEY) return antwort(200, { versand: "nicht eingerichtet" });

  const z: Zugang = { keyId: d.env.SES_ACCESS_KEY_ID, secret: d.env.SES_SECRET_ACCESS_KEY, region: d.env.SES_REGION || "eu-north-1" };
  const von = d.env.NEWSLETTER_VON || "daniel.stroebel@sofortsichtbar.de";
  const vonName = d.env.NEWSLETTER_VON_NAME || "Daniel Ströbel";
  const basis = (d.env.NEWSLETTER_BASIS || "https://sofortsichtbar.de").replace(/\/+$/, "");
  const jetzt = d.jetzt ?? (() => Date.now());
  const schlafen = d.schlafen ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const start = jetzt(), budget = d.zeitbudgetMs ?? ZEITBUDGET;

  // Kontostand fürs Cockpit (Testmodus? Kontingent?)
  let rate = MAX_RATE;
  try {
    const k = await konto(z, d.fetch);
    const q = k.SendQuota ?? {};
    rate = Math.max(1, Math.min(MAX_RATE, Math.floor(q.MaxSendRate ?? 1)));
    await d.rpc("newsletter_status_setzen", { p: { produktion: !!k.ProductionAccessEnabled, max_24h: q.Max24HourSend, max_rate: q.MaxSendRate, gesendet_24h: q.SentLast24Hours } });
  } catch (e) {
    await d.rpc("newsletter_status_setzen", { p: { fehler: (e as Error).message.slice(0, 300) } }).catch(() => {});
    return antwort(200, { fehler: (e as Error).message });
  }

  let gesendet = 0, fehler = 0;
  while (jetzt() - start < budget) {
    const zeilen = (await d.rpc("newsletter_versand_holen", { p_max: SCHWUNG })) as Zeile[];
    if (!zeilen?.length) break;
    const links: Record<string, string[]> = {};
    const ergebnisse: Record<string, unknown>[] = [];
    for (const zl of zeilen) {
      if (jetzt() - start >= budget) {         // Rest freigeben, nächster Lauf
        ergebnisse.push({ empfaenger_id: zl.empfaenger_id, ok: false, freigeben: true });
        continue;
      }
      const r = R.render(zl.newsletter, { ...zl.kontakt, email: zl.email }, { token: zl.token, basis });
      links[zl.newsletter.newsletter_id] = r.links;
      const t0 = jetzt();
      try {
        const id = await sende(z, {
          von, vonName, an: zl.email, antwortAn: von,
          betreff: (zl.test ? "[TEST] " : "") + r.betreff, text: r.text, html: r.html,
          abmeldenUrl: `${basis}/api/nl?abmelden=${encodeURIComponent(zl.token)}`, abmeldenMail: von,
          kennung: zl.newsletter.newsletter_id,
        }, d.fetch, d.env.SES_CONFIG_SET || undefined);
        ergebnisse.push({ empfaenger_id: zl.empfaenger_id, ok: true, message_id: id });
        gesendet++;
      } catch (e) {
        ergebnisse.push({ empfaenger_id: zl.empfaenger_id, ok: false, fehler: (e as Error).message, dauerhaft: (e as { dauerhaft?: boolean }).dauerhaft === true });
        fehler++;
      }
      const warte = 1000 / rate - (jetzt() - t0);
      if (warte > 0) await schlafen(warte);
    }
    await d.rpc("newsletter_versand_ergebnis", { p: { links, ergebnisse } });
  }
  return antwort(200, { gesendet, fehler });
}
