// Edge Function dashboard – Einstieg. Logik in handler.ts.
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Anmeldung von Daniels Dashboard (Supabase „dashboard empiria“). Beide Werte
// sind öffentlich (stehen auch im Dashboard-Code); geprüft wird das Token.
const AUTH_URL = Deno.env.get("DASHBOARD_AUTH_URL") ?? "https://abwynhhoyhppvcecrxxa.supabase.co";
const AUTH_KEY = Deno.env.get("DASHBOARD_PUBLISHABLE_KEY") ?? "sb_publishable_P7tU5WUl5L4QuhAgzxqW3g_jTG1CxON";

Deno.serve((req) =>
  verarbeite(req, {
    pruefeLogin: async (token) => {
      const r = await fetch(`${AUTH_URL}/auth/v1/user`, { headers: { apikey: AUTH_KEY, Authorization: `Bearer ${token}` } });
      if (r.status === 401 || r.status === 403) return null;
      if (!r.ok) throw new Error(`Auth ${r.status}`);
      const u = await r.json();
      return typeof u?.email === "string" ? u.email.toLowerCase() : null;
    },
    rpc: async (funktion, args) => {
      const r = await fetch(`${url}/rest/v1/rpc/${funktion}`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(args),
      });
      if (!r.ok) throw new Error(`Supabase ${funktion} ${r.status}: ${(await r.text()).slice(0, 300)}`);
      return r.json();
    },
  })
);
