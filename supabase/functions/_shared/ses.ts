/**
 * Amazon SES (API v2) ohne SDK: AWS-Signatur Version 4 über WebCrypto,
 * MIME-Nachricht selbst gebaut (Text + HTML, Abmelde-Header nach RFC 8058).
 * Ohne Deno-Abhängigkeiten, damit in Node testbar.
 */

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function sha256(data: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(data)));
}
async function hmac(key: ArrayBuffer | Uint8Array, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(data));
}
function rfc3986(s: string): string {
  return encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

export type Zugang = { keyId: string; secret: string; region: string };

/** Signiert eine Anfrage (SigV4) und gibt die nötigen Header zurück. */
export async function signiere(
  z: Zugang, service: string, method: string, url: string,
  headers: Record<string, string>, body: string, jetzt = new Date(),
): Promise<Record<string, string>> {
  const u = new URL(url);
  const amzDate = jetzt.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const datum = amzDate.slice(0, 8);
  const h: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) h[k.toLowerCase()] = String(v).trim().replace(/\s+/g, " ");
  h["host"] = u.host;
  h["x-amz-date"] = amzDate;
  const namen = Object.keys(h).sort();
  const query = [...u.searchParams.entries()]
    .map(([k, v]) => [rfc3986(k), rfc3986(v)]).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : 1))
    .map(([k, v]) => k + "=" + v).join("&");
  const pfad = u.pathname.split("/").map((s) => rfc3986(decodeURIComponent(s))).join("/") || "/";
  const kanonisch = [method, pfad, query, namen.map((n) => n + ":" + h[n]).join("\n") + "\n", namen.join(";"), await sha256(body)].join("\n");
  const bereich = `${datum}/${z.region}/${service}/aws4_request`;
  const zuSignieren = ["AWS4-HMAC-SHA256", amzDate, bereich, await sha256(kanonisch)].join("\n");
  let k = await hmac(enc.encode("AWS4" + z.secret), datum);
  k = await hmac(k, z.region);
  k = await hmac(k, service);
  k = await hmac(k, "aws4_request");
  const signatur = hex(await hmac(k, zuSignieren));
  return {
    ...headers,
    "x-amz-date": amzDate,
    Authorization: `AWS4-HMAC-SHA256 Credential=${z.keyId}/${bereich}, SignedHeaders=${namen.join(";")}, Signature=${signatur}`,
  };
}

function b64(s: string): string {
  const bytes = enc.encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
function zeilen76(s: string): string {
  return s.replace(/.{1,76}/g, "$&\r\n").trimEnd();
}
/** RFC 2047 für Header mit Umlauten */
export function headerWort(s: string): string {
  return /^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${b64(s)}?=`;
}

export type Mail = {
  von: string; vonName: string; an: string; antwortAn?: string; betreff: string;
  text: string; html: string; abmeldenUrl?: string; abmeldenMail?: string; kennung?: string;
};

export function mime(m: Mail, jetzt = new Date()): string {
  const grenze = "=_ss_" + crypto.randomUUID().replace(/-/g, "");
  const kopf = [
    `From: ${headerWort(m.vonName)} <${m.von}>`,
    `To: <${m.an}>`,
    m.antwortAn ? `Reply-To: <${m.antwortAn}>` : "",
    `Subject: ${headerWort(m.betreff)}`,
    `Date: ${jetzt.toUTCString().replace("GMT", "+0000")}`,
    "MIME-Version: 1.0",
    m.abmeldenUrl ? `List-Unsubscribe: <${m.abmeldenUrl}>${m.abmeldenMail ? `, <mailto:${m.abmeldenMail}?subject=Abmelden>` : ""}` : "",
    m.abmeldenUrl ? "List-Unsubscribe-Post: List-Unsubscribe=One-Click" : "",
    m.kennung ? `X-Newsletter: ${m.kennung}` : "",
    `Content-Type: multipart/alternative; boundary="${grenze}"`,
  ].filter(Boolean);
  return [
    ...kopf, "",
    `--${grenze}`, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", zeilen76(b64(m.text)),
    `--${grenze}`, "Content-Type: text/html; charset=UTF-8", "Content-Transfer-Encoding: base64", "", zeilen76(b64(m.html)),
    `--${grenze}--`, "",
  ].join("\r\n");
}

/** Schickt eine Mail über SES v2 (Raw). Gibt die MessageId zurück oder wirft {status, dauerhaft}. */
export async function sende(z: Zugang, m: Mail, f: typeof fetch = fetch, configSet?: string): Promise<string> {
  const url = `https://email.${z.region}.amazonaws.com/v2/email/outbound-emails`;
  const body = JSON.stringify({
    FromEmailAddress: m.von,
    Destination: { ToAddresses: [m.an] },
    Content: { Raw: { Data: b64(mime(m)) } },
    ...(configSet ? { ConfigurationSetName: configSet } : {}),
  });
  const headers = await signiere(z, "ses", "POST", url, { "content-type": "application/json" }, body);
  const r = await f(url, { method: "POST", headers, body });
  const t = await r.text();
  if (!r.ok) {
    // 4xx außer Drosselung = dauerhaft (z. B. Adresse im Testmodus nicht bestätigt, abgelehnt)
    const dauerhaft = r.status >= 400 && r.status < 500 && r.status !== 429;
    throw Object.assign(new Error(`SES ${r.status}: ${t.slice(0, 300)}`), { status: r.status, dauerhaft });
  }
  return JSON.parse(t).MessageId as string;
}

export async function konto(z: Zugang, f: typeof fetch = fetch) {
  const url = `https://email.${z.region}.amazonaws.com/v2/email/account`;
  const headers = await signiere(z, "ses", "GET", url, {}, "");
  const r = await f(url, { headers });
  const t = await r.text();
  if (!r.ok) throw new Error(`SES ${r.status}: ${t.slice(0, 200)}`);
  return JSON.parse(t);
}
