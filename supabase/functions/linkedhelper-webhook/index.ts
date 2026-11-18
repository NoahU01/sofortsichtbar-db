// Edge Function linkedhelper-webhook – Einstieg. Logik in handler.ts.
// Secret: LINKEDHELPER_KEY (steht in der Webhook-URL als ?k=…)
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve((req) =>
  verarbeite(req, {
    env: Deno.env.toObject(),
    fetch,
    rpc: async (fn, args) => {
      const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(args),
      });
      if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 300)}`);
      const t = await r.text();
      return t ? JSON.parse(t) : null;
    },
  })
);
