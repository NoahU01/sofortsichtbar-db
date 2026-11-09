// Edge Function cal-webhook – Einstieg. Logik in handler.ts.
// Secret: supabase secrets set CAL_WEBHOOK_SECRET=…  (gleicher Wert wie in Cal.com)
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve((req) =>
  verarbeite(req, {
    secret: Deno.env.get("CAL_WEBHOOK_SECRET"),
    speichern: async (p) => {
      const r = await fetch(`${url}/rest/v1/rpc/ingest_cal_webhook`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p }),
      });
      if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 300)}`);
      return r.json();
    },
  })
);
