// Edge Function suche-import – Einstieg. Logik in handler.ts.
// Secrets: IMPORT_SECRET, GOOGLE_DIENSTKONTO_B64, GA4_PROPERTY, BING_API_KEY (+ optional GSC_SITE, BING_SITE)
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve((req) =>
  verarbeite(req, {
    env: Deno.env.toObject(),
    fetch,
    speichern: async (p) => {
      const r = await fetch(`${url}/rest/v1/rpc/ingest_suche`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p }),
      });
      if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 300)}`);
      return r.json();
    },
  })
);
