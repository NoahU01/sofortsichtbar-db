/**
 * Edge Function buffer-import – Logik (ohne Deno-Abhängigkeiten, testbar).
 *
 * Holt alle gesendeten Beiträge aller Buffer-Kanäle samt Kennzahlen über die
 * Buffer-GraphQL-API (persönlicher Schlüssel, nur lesend) und übergibt sie an
 * public.ingest_buffer. Buffer aktualisiert die Kennzahlen einmal täglich;
 * aufgerufen wird zweimal täglich per pg_cron mit Header x-import-secret.
 */

export type Env = { IMPORT_SECRET?: string; BUFFER_API_KEY?: string };
export type Abhaengigkeiten = {
  env: Env;
  fetch: typeof fetch;
  rpc: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
};

const API = "https://api.buffer.com";
const SEITE = 100;
const MAX_SEITEN = 50;

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

export async function gql(d: Abhaengigkeiten, query: string, variables: Record<string, unknown> = {}) {
  const r = await d.fetch(API, {
    method: "POST",
    headers: { Authorization: `Bearer ${d.env.BUFFER_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Buffer ${r.status}: ${text.slice(0, 200)}`);
  let j: { data?: Record<string, any>; errors?: { message?: string }[] };
  try { j = JSON.parse(text); } catch { throw new Error("Buffer: keine JSON-Antwort"); }
  if (j.errors?.length) throw new Error("Buffer: " + j.errors.map((e) => e.message).join("; ").slice(0, 300));
  return j.data ?? {};
}

const Q_ORGS = `{ account { organizations { id name } } }`;
const Q_KANAELE = `query($org: OrganizationId!) { channels(input: { organizationId: $org }) { id name service type externalLink } }`;
const Q_POSTS = `query($org: OrganizationId!, $nach: String) {
  posts(first: ${SEITE}, after: $nach, input: { organizationId: $org, filter: { status: [sent] } }) {
    edges { node { id channelId channelService sentAt externalLink text metricsUpdatedAt metrics { type value } } }
    pageInfo { hasNextPage endCursor }
  }
}`;

export async function abrufen(d: Abhaengigkeiten) {
  const orgs: { id: string }[] = (await gql(d, Q_ORGS)).account?.organizations ?? [];
  const kanaele: Record<string, unknown>[] = [];
  const beitraege: Record<string, unknown>[] = [];
  for (const o of orgs) {
    for (const c of (await gql(d, Q_KANAELE, { org: o.id })).channels ?? []) {
      kanaele.push({ id: c.id, name: c.name, service: c.service, typ: c.type, link: c.externalLink ?? null });
    }
    let nach: string | null = null;
    for (let s = 0; s < MAX_SEITEN; s++) {
      const p = (await gql(d, Q_POSTS, { org: o.id, nach })).posts;
      for (const e of p?.edges ?? []) {
        const n = e.node;
        const kennzahlen: Record<string, number> = {};
        for (const m of n.metrics ?? []) if (m && typeof m.value === "number") kennzahlen[m.type] = m.value;
        beitraege.push({
          id: n.id, channel_id: n.channelId, service: n.channelService, gesendet: n.sentAt ?? null,
          link: n.externalLink ?? null, text: typeof n.text === "string" ? n.text.slice(0, 1000) : null,
          kennzahlen, kennzahlen_stand: n.metricsUpdatedAt ?? null,
        });
      }
      if (!p?.pageInfo?.hasNextPage) break;
      nach = p.pageInfo.endCursor;
    }
  }
  return { kanaele, beitraege };
}

export async function verarbeite(req: Request, d: Abhaengigkeiten): Promise<Response> {
  const antwort = (status: number, x: unknown) => new Response(JSON.stringify(x), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return antwort(405, { fehler: "nur POST" });
  const geheim = req.headers.get("x-import-secret") ?? "";
  if (!d.env.IMPORT_SECRET || !gleich(geheim, d.env.IMPORT_SECRET)) return antwort(401, { fehler: "nicht berechtigt" });
  if (!d.env.BUFFER_API_KEY) return antwort(200, { buffer: "nicht eingerichtet" });

  try {
    const daten = await abrufen(d);
    const r = await d.rpc("ingest_buffer", { p: daten });
    await d.rpc("import_protokoll", { p_quelle: "buffer", p_zeilen: daten.beitraege.length, p_fehler: null });
    return antwort(200, { kanaele: daten.kanaele.length, beitraege: daten.beitraege.length, ergebnis: r });
  } catch (e) {
    const fehler = (e as Error).message.slice(0, 500);
    try { await d.rpc("import_protokoll", { p_quelle: "buffer", p_zeilen: 0, p_fehler: fehler }); } catch { /* Protokoll nicht erreichbar */ }
    return antwort(200, { fehler });
  }
}
