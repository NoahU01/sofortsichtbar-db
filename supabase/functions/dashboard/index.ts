// Edge Function dashboard – Einstieg. Logik in handler.ts.
import { verarbeite } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;

// Wo ein Token geprüft wird – nach seinem Aussteller (iss). Die Schlüssel
// sind öffentlich; geprüft wird das Token selbst beim jeweiligen Auth-Server.
const DANIEL_URL = Deno.env.get("DASHBOARD_AUTH_URL") ?? "https://abwynhhoyhppvcecrxxa.supabase.co";
const DANIEL_KEY = Deno.env.get("DASHBOARD_PUBLISHABLE_KEY") ?? "sb_publishable_P7tU5WUl5L4QuhAgzxqW3g_jTG1CxON";
const AUSSTELLER: Record<string, { url: string; key: string }> = {
  [`${url}/auth/v1`]: { url, key: anon },                     // Cockpit
  [`${DANIEL_URL}/auth/v1`]: { url: DANIEL_URL, key: DANIEL_KEY }, // empiria-dashboard
};

function aussteller(token: string): string | null {
  try {
    const teil = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(teil + "=".repeat((4 - (teil.length % 4)) % 4))).iss ?? null;
  } catch {
    return null;
  }
}

Deno.serve((req) =>
  verarbeite(req, {
    pruefeLogin: async (token) => {
      const ziel = AUSSTELLER[aussteller(token) ?? ""];
      if (!ziel) return null;
      const r = await fetch(`${ziel.url}/auth/v1/user`, { headers: { apikey: ziel.key, Authorization: `Bearer ${token}` } });
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
