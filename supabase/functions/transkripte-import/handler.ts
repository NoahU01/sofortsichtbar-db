/**
 * Edge Function transkripte-import – holt neue Call-Transkripte aus einem
 * freigegebenen OneDrive-/SharePoint-Ordner (Microsoft Graph, App-only).
 *
 * Berechtigung: Die App (gleiche wie postfach-import) hat
 * Files.SelectedOperations.Selected und Leserecht NUR auf diesen Ordner.
 * Ordner: MS_TRANSKRIPT_DRIVE (driveId) + MS_TRANSKRIPT_ORDNER (itemId).
 *
 * Je neue/geänderte Datei: Text auslesen (.docx, .vtt, .txt, .md) und an
 * public.ingest_transkript geben (ordnet über den Kalender dem Termin und
 * Kontakt zu, legt einen Call an). Andere Formate werden als „nicht lesbar“
 * vermerkt. Läuft alle 15 Minuten per pg_cron.
 */
import { msToken } from "../postfach-import/handler.ts";

type Env = {
  IMPORT_SECRET?: string; MS_TENANT_ID?: string; MS_CLIENT_ID?: string; MS_CLIENT_SECRET?: string;
  MS_TRANSKRIPT_DRIVE?: string; MS_TRANSKRIPT_ORDNER?: string;
};
export type Abhaengigkeiten = {
  env: Env;
  fetch: typeof fetch;
  rpc: (funktion: string, args: Record<string, unknown>) => Promise<any>;
};

const GRAPH = "https://graph.microsoft.com/v1.0";
const MAX_GROESSE = 15 * 1024 * 1024;
const MAX_TEXT = 400_000;

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/* ---------- Text aus Dateien ---------- */

// WebVTT (Teams-Transkript): Zeitstempel weg, <v Name>Text</v> → „Name: Text“, gleiche Sprecher zusammenfassen
export function vttZuText(roh: string): string {
  const zeilen: { wer: string; text: string }[] = [];
  for (const block of roh.replace(/\r/g, "").split(/\n\n+/)) {
    const l = block.split("\n").filter((z) => z.trim() && !/^WEBVTT/.test(z) && !/-->/.test(z) && !/^NOTE\b/.test(z) && !/^[0-9a-f-]{8,}(\/\d+-\d+)?$/i.test(z.trim()) && !/^\d+$/.test(z.trim()));
    if (!l.length) continue;
    let text = l.join(" "), wer = "";
    const m = /^<v\s+([^>]+)>([\s\S]*?)(<\/v>)?$/.exec(text.trim());
    if (m) { wer = m[1].trim(); text = m[2]; }
    else { const m2 = /^([^:]{2,60}):\s+(.+)$/.exec(text.trim()); if (m2) { wer = m2[1]; text = m2[2]; } }
    text = text.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
    if (!text) continue;
    const letzte = zeilen[zeilen.length - 1];
    if (letzte && letzte.wer === wer) letzte.text += " " + text; else zeilen.push({ wer, text });
  }
  return zeilen.map((z) => (z.wer ? z.wer + ": " : "") + z.text).join("\n\n");
}

// .docx: ZIP öffnen, word/document.xml entpacken, Absätze als Text
async function entpacken(daten: Uint8Array, gesucht: string): Promise<Uint8Array | null> {
  const dv = new DataView(daten.buffer, daten.byteOffset, daten.byteLength);
  let ende = -1;
  for (let i = daten.length - 22; i >= Math.max(0, daten.length - 66000); i--) if (dv.getUint32(i, true) === 0x06054b50) { ende = i; break; }
  if (ende < 0) return null;
  const anzahl = dv.getUint16(ende + 10, true);
  let pos = dv.getUint32(ende + 16, true);
  for (let n = 0; n < anzahl; n++) {
    if (dv.getUint32(pos, true) !== 0x02014b50) return null;
    const methode = dv.getUint16(pos + 10, true), gross = dv.getUint32(pos + 20, true);
    const nameLen = dv.getUint16(pos + 28, true), extraLen = dv.getUint16(pos + 30, true), kommLen = dv.getUint16(pos + 32, true);
    const lokal = dv.getUint32(pos + 42, true);
    const name = new TextDecoder().decode(daten.subarray(pos + 46, pos + 46 + nameLen));
    if (name === gesucht) {
      const lNameLen = dv.getUint16(lokal + 26, true), lExtraLen = dv.getUint16(lokal + 28, true);
      const start = lokal + 30 + lNameLen + lExtraLen, inhalt = daten.subarray(start, start + gross);
      if (methode === 0) return inhalt;
      if (methode !== 8) return null;
      const strom = new Blob([inhalt]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return new Uint8Array(await new Response(strom).arrayBuffer());
    }
    pos += 46 + nameLen + extraLen + kommLen;
  }
  return null;
}
export async function docxZuText(daten: Uint8Array): Promise<string> {
  const xml = await entpacken(daten, "word/document.xml");
  if (!xml) return "";
  const s = new TextDecoder().decode(xml);
  const absaetze = s.split(/<\/w:p>/).map((p) =>
    (p.match(/<w:t(?:\s[^>]*)?>[^<]*<\/w:t>|<w:tab\/>|<w:br\/>/g) || [])
      .map((t) => (t.startsWith("<w:tab") ? "\t" : t.startsWith("<w:br") ? "\n" : t.replace(/<[^>]+>/g, ""))).join(""));
  const ent = (t: string) => t.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
  return ent(absaetze.map((a) => a.trim()).filter(Boolean).join("\n\n"));
}

// Zeitpunkt aus dem Dateinamen (Teams: …-20261118_140312UTC-…), sonst null
export function zeitAusName(name: string): string | null {
  const m = /(20\d{2})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})(UTC)?/.exec(name);
  if (!m) return null;
  const iso = `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}` + (m[7] ? "Z" : "");
  const d = new Date(iso);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

export async function dateiZuText(name: string, daten: Uint8Array): Promise<{ text: string; status: "importiert" | "nicht_lesbar" | "leer" }> {
  const endung = (name.split(".").pop() || "").toLowerCase();
  let text = "";
  if (endung === "docx") text = await docxZuText(daten);
  else if (endung === "vtt") text = vttZuText(new TextDecoder().decode(daten));
  else if (endung === "txt" || endung === "md") text = new TextDecoder().decode(daten);
  else return { text: "", status: "nicht_lesbar" };
  text = text.replace(/\u0000/g, "").trim().slice(0, MAX_TEXT);
  return { text, status: text ? "importiert" : "leer" };
}

/* ---------- Ablauf ---------- */
export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const antwort = (status: number, x: unknown) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return antwort(405, { fehler: "nur POST" });
  if (!d.env.IMPORT_SECRET || !gleich(req.headers.get("x-import-secret") ?? "", d.env.IMPORT_SECRET)) return antwort(401, { fehler: "nicht berechtigt" });
  if (!d.env.MS_TENANT_ID || !d.env.MS_CLIENT_ID || !d.env.MS_CLIENT_SECRET || !d.env.MS_TRANSKRIPT_DRIVE || !d.env.MS_TRANSKRIPT_ORDNER) {
    return antwort(200, { transkripte: "nicht eingerichtet" });
  }
  let neu = 0;
  const fehlerListe: string[] = [];
  try {
    const token = await msToken(d.env, d.fetch);
    const h = { Authorization: `Bearer ${token}` };
    const stand: Record<string, string | null> = (await d.rpc("transkripte_stand", {})) ?? {};
    const dateien: any[] = [];
    let url: string | null = `${GRAPH}/drives/${encodeURIComponent(d.env.MS_TRANSKRIPT_DRIVE)}/items/${encodeURIComponent(d.env.MS_TRANSKRIPT_ORDNER)}/children?$top=200&$select=id,name,eTag,size,file,createdDateTime,lastModifiedDateTime`;
    while (url) {
      const r = await d.fetch(url, { headers: h });
      if (!r.ok) throw new Error(`Ordner lesen ${r.status}: ${(await r.text()).slice(0, 200)}`);
      const j = await r.json();
      dateien.push(...(j.value ?? []).filter((x: any) => x.file));
      url = j["@odata.nextLink"] ?? null;
    }
    for (const f of dateien) {
      if (f.id in stand && stand[f.id] === f.eTag) continue;
      const basis = { item_id: f.id, name: f.name, etag: f.eTag, groesse: f.size, geaendert: f.lastModifiedDateTime,
                      beginn: zeitAusName(f.name) ?? f.createdDateTime };
      try {
        if (f.size > MAX_GROESSE) { await d.rpc("ingest_transkript", { p: { ...basis, status: "nicht_lesbar", fehler: "Datei zu groß" } }); continue; }
        const r = await d.fetch(`${GRAPH}/drives/${encodeURIComponent(d.env.MS_TRANSKRIPT_DRIVE)}/items/${encodeURIComponent(f.id)}/content`, { headers: h });
        if (!r.ok) throw new Error(`Datei laden ${r.status}`);
        const inhalt = await dateiZuText(f.name, new Uint8Array(await r.arrayBuffer()));
        await d.rpc("ingest_transkript", { p: { ...basis, ...inhalt } });
        if (inhalt.status === "importiert") neu++;
      } catch (e) {
        fehlerListe.push(`${f.name}: ${(e as Error).message}`);
      }
    }
  } catch (e) {
    fehlerListe.push((e as Error).message);
  }
  await d.rpc("import_protokoll", { p_quelle: "transkripte", p_zeilen: neu, p_fehler: fehlerListe.length ? fehlerListe.join(" | ").slice(0, 1000) : null }).catch(() => {});
  return antwort(200, { neu, fehler: fehlerListe });
}
