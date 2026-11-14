// Edge Function postfach-import – Einstieg. Logik in handler.ts.
// Secrets: IMPORT_SECRET, MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_DOMAIN
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve((req) =>
  verarbeite(req, {
    env: Deno.env.toObject(),
    fetch,
    rpc: async (funktion, args) => {
      const r = await fetch(`${url}/rest/v1/rpc/${funktion}`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(args),
      });
      if (!r.ok) throw new Error(`Supabase ${funktion} ${r.status}: ${(await r.text()).slice(0, 300)}`);
      const t = await r.text();
      return t ? JSON.parse(t) : null;
    },
  })
);
