/**
 * Holt Mails (Posteingang, Gesendet) und Kalender aller Postfächer der Domain
 * aus Microsoft 365 und übergibt sie an public.ingest_postfach.
 *
 * Zugriff: App-Registrierung mit Client-Secret. Mail.Read und Calendars.Read
 * sind in Exchange (RBAC for Applications) auf @sofortsichtbar.de begrenzt,
 * User.Read.All in Entra listet die Postfächer.
 *
 * Delta-Abfragen: Pro Postfach und Ordner wird der @odata.deltaLink gemerkt;
 * der nächste Lauf holt nur Neues. Erster Lauf: Mails der letzten
 * MS_START_TAGE (Standard 365), Kalender 90 Tage zurück bis 180 voraus.
 * Läuft die Zeit ab, wird der @odata.nextLink gemerkt und beim nächsten Lauf
 * fortgesetzt.
 *
 * Aufruf nur mit Header x-import-secret (alle 15 min per pg_cron).
 * Ohne Deno-Abhängigkeiten, damit es sich lokal mit Node testen lässt.
 */

export type Env = {
  IMPORT_SECRET?: string;
  MS_TENANT_ID?: string;
  MS_CLIENT_ID?: string;
  MS_CLIENT_SECRET?: string;
  MS_DOMAIN?: string;
  MS_START_TAGE?: string;
};
export type Abhaengigkeiten = {
  env: Env;
  fetch: typeof fetch;
  rpc: (funktion: string, args: Record<string, unknown>) => Promise<any>;
  jetzt?: () => number;
  zeitbudgetMs?: number;
};

const GRAPH = "https://graph.microsoft.com/v1.0";
const MAIL_FELDER = "id,internetMessageId,conversationId,subject,bodyPreview,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,hasAttachments,isDraft";
const ORDNER: Record<string, string> = { posteingang: "inbox", gesendet: "sentitems" };
const KALENDER_NEU_NACH_TAGEN = 30;   // Kalenderfenster regelmäßig neu aufsetzen

function gleich(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function msToken(env: Env, f: typeof fetch): Promise<string> {
  const r = await f(`https://login.microsoftonline.com/${encodeURIComponent(env.MS_TENANT_ID!)}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env.MS_CLIENT_ID!, client_secret: env.MS_CLIENT_SECRET!, scope: "https://graph.microsoft.com/.default", grant_type: "client_credentials" }).toString(),
  });
  if (!r.ok) throw new Error(`Microsoft-Anmeldung ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).access_token;
}

type Adresse = { emailAddress?: { address?: string; name?: string } };
const adr = (a?: Adresse) => ({ email: a?.emailAddress?.address ?? null, name: a?.emailAddress?.name ?? null });

export function mailZeile(m: any, ordner: string) {
  return {
    id: m.id, ordner,
    internet_message_id: m.internetMessageId ?? null,
    conversation_id: m.conversationId ?? null,
    zeit: ordner === "gesendet" ? (m.sentDateTime ?? m.receivedDateTime) : (m.receivedDateTime ?? m.sentDateTime),
    von_email: m.from?.emailAddress?.address ?? null,
    von_name: m.from?.emailAddress?.name ?? null,
    an: (m.toRecipients ?? []).map(adr).filter((x: any) => x.email),
    cc: (m.ccRecipients ?? []).map(adr).filter((x: any) => x.email),
    betreff: m.subject ?? null,
    vorschau: (m.bodyPreview ?? "").slice(0, 300),
    anhang: !!m.hasAttachments,
  };
}

/** Graph liefert start/end ohne Offset; ohne Prefer-Zeitzone ist es UTC. */
const utc = (z?: { dateTime?: string }) => (z?.dateTime ? z.dateTime.replace(/(\.\d{3})\d*$/, "$1") + "Z" : null);

export function terminZeile(e: any) {
  return {
    id: e.id, ical_uid: e.iCalUId ?? null, betreff: e.subject ?? null,
    beginn: utc(e.start), ende: utc(e.end), ort: e.location?.displayName || null,
    organisator_email: e.organizer?.emailAddress?.address ?? null,
    teilnehmer: (e.attendees ?? []).map((a: any) => ({ ...adr(a), antwort: a.status?.response ?? null })).filter((x: any) => x.email),
    online: !!e.isOnlineMeeting, abgesagt: !!e.isCancelled,
    vorschau: (e.bodyPreview ?? "").slice(0, 300),
  };
}

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const antwort = (status: number, x: unknown) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return antwort(405, { fehler: "nur POST" });
  if (!d.env.IMPORT_SECRET || !gleich(req.headers.get("x-import-secret") ?? "", d.env.IMPORT_SECRET)) return antwort(401, { fehler: "nicht berechtigt" });
  if (!d.env.MS_TENANT_ID || !d.env.MS_CLIENT_ID || !d.env.MS_CLIENT_SECRET) return antwort(200, { postfach: "nicht eingerichtet" });

  const jetzt = d.jetzt ?? (() => Date.now());
  const ende = jetzt() + (d.zeitbudgetMs ?? 110_000);
  const domain = (d.env.MS_DOMAIN || "sofortsichtbar.de").toLowerCase();
  const startTage = Math.min(Math.max(Number(d.env.MS_START_TAGE) || 365, 1), 3650);
  const bericht: Record<string, unknown> = {};
  let zeilen = 0;
  const fehlerListe: string[] = [];

  let token: string;
  try { token = await msToken(d.env, d.fetch); }
  catch (e) {
    const fehler = (e as Error).message;
    await d.rpc("import_protokoll", { p_quelle: "postfach", p_zeilen: 0, p_fehler: fehler }).catch(() => {});
    return antwort(200, { fehler });
  }
  const graph = async (url: string, prefer?: string) => {
    const r = await d.fetch(url, { headers: { Authorization: `Bearer ${token}`, ...(prefer ? { Prefer: prefer } : {}) } });
    if (!r.ok) throw new Error(`Graph ${r.status}: ${(await r.text()).slice(0, 200)}`);
    return r.json();
  };

  // Postfächer der Domain
  const postfaecher: string[] = [];
  try {
    let url: string | undefined = `${GRAPH}/users?$select=id,mail,userPrincipalName&$top=999`;
    while (url) {
      const r = await graph(url);
      for (const u of r.value ?? []) {
        const m = (u.mail || "").toLowerCase();
        if (m.endsWith("@" + domain)) postfaecher.push(m);
      }
      url = r["@odata.nextLink"];
    }
  } catch (e) {
    const fehler = "Postfächer auflisten: " + (e as Error).message;
    await d.rpc("import_protokoll", { p_quelle: "postfach", p_zeilen: 0, p_fehler: fehler }).catch(() => {});
    return antwort(200, { fehler });
  }

  const stand: Record<string, { link: string | null; gestartet: string }> = await d.rpc("postfach_stand", {});

  // Eine Delta-Kette abarbeiten, Seite für Seite speichern
  async function kette(postfach: string, ordner: string, startUrl: string) {
    const s = stand[`${postfach}|${ordner}`];
    let url = s?.link || startUrl;
    const neu = !s?.link;
    let anzahl = 0, seiten = 0;
    try {
      while (url) {
        if (jetzt() > ende) { bericht[`${postfach}|${ordner}`] = { anzahl, fortsetzung: true }; return; }
        const r = await graph(url, "odata.maxpagesize=50");
        const werte = r.value ?? [];
        const aktiv = werte.filter((x: any) => !x["@removed"]);
        const entfernt = werte.filter((x: any) => x["@removed"]).map((x: any) => x.id);
        const naechster: string | undefined = r["@odata.nextLink"];
        const delta: string | undefined = r["@odata.deltaLink"];
        const p: Record<string, unknown> = { postfach, domain, ordner, delta_link: naechster ?? delta ?? null, neu_gestartet: neu && seiten === 0, entfernt };
        if (ordner === "kalender") p.termine = aktiv.map(terminZeile);
        else p.mails = aktiv.filter((m: any) => !m.isDraft).map((m: any) => mailZeile(m, ordner));
        await d.rpc("ingest_postfach", { p });
        anzahl += aktiv.length; seiten++; zeilen += aktiv.length;
        url = naechster ?? "";
      }
      bericht[`${postfach}|${ordner}`] = { anzahl };
    } catch (e) {
      const fehler = (e as Error).message.slice(0, 300);
      bericht[`${postfach}|${ordner}`] = { fehler };
      fehlerListe.push(`${postfach} ${ordner}: ${fehler}`);
      await d.rpc("ingest_postfach", { p: { postfach, domain, ordner, fehler } }).catch(() => {});
    }
  }

  const ab = new Date(jetzt() - startTage * 864e5).toISOString();
  for (const pf of postfaecher) {
    const user = encodeURIComponent(pf);
    for (const [ordner, ms] of Object.entries(ORDNER)) {
      await kette(pf, ordner, `${GRAPH}/users/${user}/mailFolders/${ms}/messages/delta?$select=${MAIL_FELDER}&$filter=${encodeURIComponent(`receivedDateTime ge ${ab}`)}`);
    }
    // Kalender: Fenster alle 30 Tage neu aufsetzen, damit es mitwandert
    const k = stand[`${pf}|kalender`];
    if (k?.link && jetzt() - Date.parse(k.gestartet) > KALENDER_NEU_NACH_TAGEN * 864e5) stand[`${pf}|kalender`] = { link: null, gestartet: k.gestartet };
    const von = new Date(jetzt() - 90 * 864e5).toISOString(), bis = new Date(jetzt() + 180 * 864e5).toISOString();
    await kette(pf, "kalender", `${GRAPH}/users/${user}/calendarView/delta?startDateTime=${von}&endDateTime=${bis}`);
  }

  await d.rpc("import_protokoll", { p_quelle: "postfach", p_zeilen: zeilen, p_fehler: fehlerListe.join(" | ").slice(0, 1000) }).catch(() => {});
  return antwort(200, { postfaecher: postfaecher.length, zeilen, bericht });
}
