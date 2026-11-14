/**
 * Holt Suchdaten und GA4-Tageswerte und übergibt sie an public.ingest_suche.
 *
 *   Google Search Console  – Dienstkonto (eingeschränkter Nutzer der Property)
 *   GA4 Data API           – dasselbe Dienstkonto (Rolle Betrachter)
 *   Bing Webmaster Tools   – API-Schlüssel
 *
 * Jede Quelle läuft für sich: Fehlt ein Zugang, wird sie übersprungen; schlägt
 * sie fehl, landet der Fehler im Protokoll (analytics.import_laeufe), die
 * anderen laufen weiter.
 *
 * Aufruf nur mit Header x-import-secret (täglich per pg_cron).
 * Body: { "tage": 10 }  – erster Lauf gern { "tage": 480 } (Google hält 16 Monate).
 *
 * Ohne Deno-Abhängigkeiten, damit es sich lokal mit Node testen lässt.
 */

export type Env = {
  IMPORT_SECRET?: string;
  GOOGLE_DIENSTKONTO_B64?: string; // JSON-Schlüssel des Dienstkontos, base64
  GSC_SITE?: string;               // optional, sonst automatisch (sc-domain:… bevorzugt)
  GA4_PROPERTY?: string;           // Property-Nummer, z. B. 123456789
  BING_API_KEY?: string;
  BING_SITE?: string;              // Standard https://www.sofortsichtbar.de/
};
export type Abhaengigkeiten = {
  env: Env;
  fetch: typeof fetch;
  speichern: (p: Record<string, unknown>) => Promise<unknown>;
  jetzt?: () => Date;
};

type Zeile = Record<string, string | number | null>;

const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const tag = (d: Date) => d.toISOString().slice(0, 10);

function gleich(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/* ---------------- Google ---------------- */
type Dienstkonto = { client_email: string; private_key: string };

function dienstkonto(env: Env): Dienstkonto | null {
  if (!env.GOOGLE_DIENSTKONTO_B64) return null;
  const j = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(env.GOOGLE_DIENSTKONTO_B64.trim()), (c) => c.charCodeAt(0))));
  if (!j.client_email || !j.private_key) throw new Error("Dienstkonto-JSON ohne client_email/private_key");
  return j;
}

export async function googleToken(sa: Dienstkonto, scopes: string[], f: typeof fetch, jetzt = new Date()): Promise<string> {
  const iat = Math.floor(jetzt.getTime() / 1000);
  const kopf = b64url(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const inhalt = b64url(enc.encode(JSON.stringify({ iss: sa.client_email, scope: scopes.join(" "), aud: "https://oauth2.googleapis.com/token", iat, exp: iat + 3600 })));
  const der = Uint8Array.from(atob(sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(kopf + "." + inhalt)));
  const r = await f("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${kopf}.${inhalt}.${b64url(sig)}` }).toString(),
  });
  if (!r.ok) throw new Error(`Google-Anmeldung ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).access_token;
}

async function json(f: typeof fetch, url: string, token: string, body?: unknown) {
  const r = await f(url, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`${new URL(url).host} ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

const GSC = "https://www.googleapis.com/webmasters/v3/sites";

export async function searchConsole(d: Abhaengigkeiten, sa: Dienstkonto, von: string, bis: string) {
  const token = await googleToken(sa, ["https://www.googleapis.com/auth/webmasters.readonly"], d.fetch);
  let site = d.env.GSC_SITE;
  if (!site) {
    const liste: string[] = ((await json(d.fetch, GSC, token)).siteEntry || []).map((s: { siteUrl: string }) => s.siteUrl);
    site = liste.find((s) => s === "sc-domain:sofortsichtbar.de") || liste.find((s) => s.includes("sofortsichtbar.de"));
    if (!site) throw new Error("Dienstkonto hat keinen Zugriff auf sofortsichtbar.de in der Search Console" + (liste.length ? ` (sieht: ${liste.join(", ")})` : ""));
  }
  const url = `${GSC}/${encodeURIComponent(site)}/searchAnalytics/query`;
  const basis = { startDate: von, endDate: bis, type: "web", dataState: "all", rowLimit: 25000 };

  const t = await json(d.fetch, url, token, { ...basis, dimensions: ["date"] });
  const tage: Zeile[] = (t.rows || []).map((r: { keys: string[]; clicks: number; impressions: number; position: number }) =>
    ({ tag: r.keys[0], klicks: r.clicks, impressionen: r.impressions, position: r.position }));

  const suchbegriffe: Zeile[] = [];
  for (let start = 0, seite = 0; seite < 20; seite++, start += 25000) {
    const s = await json(d.fetch, url, token, { ...basis, dimensions: ["date", "query", "page", "device"], startRow: start });
    const rows = s.rows || [];
    for (const r of rows) {
      suchbegriffe.push({ tag: r.keys[0], suchbegriff: r.keys[1], seite: r.keys[2], geraet: r.keys[3], klicks: r.clicks, impressionen: r.impressions, position: r.position });
    }
    if (rows.length < 25000) break;
  }
  return { site, tage, suchbegriffe };
}

export async function ga4(d: Abhaengigkeiten, sa: Dienstkonto, von: string, bis: string) {
  const token = await googleToken(sa, ["https://www.googleapis.com/auth/analytics.readonly"], d.fetch);
  const r = await json(d.fetch, `https://analyticsdata.googleapis.com/v1beta/properties/${encodeURIComponent(d.env.GA4_PROPERTY!)}:runReport`, token, {
    dateRanges: [{ startDate: von, endDate: bis }],
    dimensions: [{ name: "date" }],
    metrics: [{ name: "totalUsers" }, { name: "sessions" }, { name: "screenPageViews" }],
    limit: 1000,
  });
  return (r.rows || []).map((x: { dimensionValues: { value: string }[]; metricValues: { value: string }[] }) => {
    const v = x.dimensionValues[0].value;
    return { tag: `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)}`, nutzer: +x.metricValues[0].value, sitzungen: +x.metricValues[1].value, seitenaufrufe: +x.metricValues[2].value };
  });
}

/* ---------------- Bing ---------------- */
/** "/Date(1316156400000-0700)/" → "2011-09-16" (Datum in der angegebenen Zone) */
export function bingDatum(s: string): string | null {
  const m = /\/Date\((-?\d+)([+-]\d{4})?\)\//.exec(s || "");
  if (!m) return null;
  let ms = Number(m[1]);
  if (m[2]) ms += (m[2][0] === "-" ? -1 : 1) * (Number(m[2].slice(1, 3)) * 60 + Number(m[2].slice(3, 5))) * 60000;
  return tag(new Date(ms));
}

export async function bing(d: Abhaengigkeiten) {
  const site = d.env.BING_SITE || "https://www.sofortsichtbar.de/";
  const holen = async (methode: string) => {
    const r = await d.fetch(`https://ssl.bing.com/webmaster/api.svc/json/${methode}?siteUrl=${encodeURIComponent(site)}&apikey=${encodeURIComponent(d.env.BING_API_KEY!)}`,
      { headers: { "Content-Type": "application/json; charset=utf-8" } });
    if (!r.ok) throw new Error(`Bing ${methode} ${r.status}: ${(await r.text()).slice(0, 200)}`);
    return ((await r.json()).d || []) as Record<string, unknown>[];
  };
  const suchbegriffe: Zeile[] = (await holen("GetQueryStats")).map((r) => ({
    tag: bingDatum(r.Date as string), suchbegriff: r.Query as string, klicks: r.Clicks as number, impressionen: r.Impressions as number,
    position: (r.AvgImpressionPosition as number) > 0 ? r.AvgImpressionPosition as number : null,
  })).filter((r) => r.tag && r.suchbegriff);
  const tage: Zeile[] = (await holen("GetRankAndTrafficStats")).map((r) => ({
    tag: bingDatum(r.Date as string), klicks: r.Clicks as number, impressionen: r.Impressions as number, position: null,
  })).filter((r) => r.tag);
  return { site, suchbegriffe, tage };
}

/* ---------------- Ablauf ---------------- */
export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const antwort = (status: number, x: unknown) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return antwort(405, { fehler: "nur POST" });
  const geheim = req.headers.get("x-import-secret") ?? "";
  if (!d.env.IMPORT_SECRET || !gleich(geheim, d.env.IMPORT_SECRET)) return antwort(401, { fehler: "nicht berechtigt" });

  let b: { tage?: number } = {};
  try { b = JSON.parse((await req.text()) || "{}"); } catch { /* Standardwerte */ }
  const tage = Math.min(Math.max(Number(b.tage) || 10, 1), 480);
  const jetzt = (d.jetzt ?? (() => new Date()))();
  const bis = tag(jetzt), von = tag(new Date(jetzt.getTime() - tage * 864e5));
  const ergebnis: Record<string, unknown> = { von, bis };

  async function quelle(name: string, eingerichtet: boolean, lauf: () => Promise<Record<string, unknown>>) {
    if (!eingerichtet) { ergebnis[name] = "nicht eingerichtet"; return; }
    try {
      ergebnis[name] = await d.speichern({ quelle: name, ...(await lauf()) });
    } catch (e) {
      const fehler = (e as Error).message.slice(0, 500);
      ergebnis[name] = { fehler };
      try { await d.speichern({ quelle: name, fehler }); } catch { /* Protokoll nicht erreichbar */ }
    }
  }

  let sa: Dienstkonto | null = null;
  try { sa = dienstkonto(d.env); } catch (e) { ergebnis.dienstkonto = (e as Error).message; }

  await quelle("google", !!sa, async () => { const r = await searchConsole(d, sa!, von, bis); return { tage: r.tage, suchbegriffe: r.suchbegriffe }; });
  await quelle("ga4", !!sa && !!d.env.GA4_PROPERTY, async () => ({ ga4: await ga4(d, sa!, von, bis) }));
  await quelle("bing", !!d.env.BING_API_KEY, async () => { const r = await bing(d); return { tage: r.tage, suchbegriffe: r.suchbegriffe }; });

  return antwort(200, ergebnis);
}
