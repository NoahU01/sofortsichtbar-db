/* Cockpit · sofort sichtbar – Anmeldung, Datenzugriff, Navigation.

   Anmeldung: Login-Link per E-Mail (Supabase Auth dieses Projekts). Neue
   Konten entstehen nicht von selbst – nur wer angelegt ist, bekommt einen
   Link. Gelesen und geschrieben wird ausschließlich über die Edge Function
   `dashboard`; die prüft das Token und die Freigabeliste core.dashboard_zugang.
   Der Schlüssel unten ist öffentlich und ohne Login wertlos. */
(function () {
  "use strict";
  var SUPABASE_URL = "https://udrcjopiixhlntmnsosj.supabase.co";
  var PUBLISHABLE_KEY = "sb_publishable_ADhdFWkXopKCsc8L7NDtTg_lrW94FLF";
  var API = SUPABASE_URL + "/functions/v1/dashboard";

  var sb = window.supabase.createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  var $ = function (s) { return document.querySelector(s); };
  var loginEl = $("[data-login]"), appEl = $("[data-app]");

  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return "&#" + c.charCodeAt(0) + ";"; }); }

  function api(aktion, daten) {
    return sb.auth.getSession().then(function (s) {
      var t = s.data.session && s.data.session.access_token;
      if (!t) throw Object.assign(new Error("nicht angemeldet"), { status: 401 });
      return fetch(API, {
        method: "POST",
        headers: { Authorization: "Bearer " + t, "Content-Type": "application/json" },
        body: JSON.stringify(Object.assign({ aktion: aktion }, daten || {}))
      }).then(function (r) {
        return r.json().catch(function () { return {}; }).then(function (j) {
          if (!r.ok) throw Object.assign(new Error(j.fehler || "Fehler " + r.status), { status: r.status, email: j.email });
          return j;
        });
      });
    });
  }

  window.cockpit = { api: api, esc: esc, main: $("[data-main]"), module: {} };

  /* ---------- Anmeldung ---------- */
  function zeigeLogin(meldung) {
    appEl.hidden = true; loginEl.hidden = false;
    $("[data-login-meldung]").textContent = meldung || "";
  }

  $("[data-login-form]").addEventListener("submit", function (e) {
    e.preventDefault();
    var email = e.target.email.value.trim().toLowerCase();
    var knopf = e.target.querySelector("button"), m = $("[data-login-meldung]");
    knopf.disabled = true; m.textContent = "Wird gesendet …";
    sb.auth.signInWithOtp({ email: email, options: { shouldCreateUser: false, emailRedirectTo: location.origin } })
      .then(function (r) {
        knopf.disabled = false;
        if (r.error) {
          m.textContent = /signups not allowed|not found|Signups/i.test(r.error.message)
            ? "Für diese Adresse gibt es kein Konto." : "Das hat nicht geklappt: " + r.error.message;
          return;
        }
        m.textContent = "Link ist unterwegs – bitte Postfach prüfen.";
      });
  });

  $("[data-abmelden]").addEventListener("click", function () { sb.auth.signOut().then(function () { zeigeLogin(); }); });

  function start() {
    api("ich").then(function (r) {
      loginEl.hidden = true; appEl.hidden = false;
      $("[data-konto]").textContent = r.email;
      oeffne("calls");
    }).catch(function (e) {
      if (e.status === 403) return zeigeLogin("Angemeldet als " + (e.email || "?") + " – diese Adresse ist nicht freigegeben.");
      if (e.status === 401) return zeigeLogin();
      zeigeLogin("Datenbank nicht erreichbar: " + e.message);
    });
  }

  /* ---------- Navigation ---------- */
  function oeffne(name) {
    document.querySelectorAll("[data-nav]").forEach(function (b) { b.setAttribute("aria-current", String(b.getAttribute("data-nav") === name)); });
    var m = window.cockpit.module[name];
    if (m) m.start();
  }
  document.querySelectorAll("[data-nav]").forEach(function (b) {
    b.addEventListener("click", function () { oeffne(b.getAttribute("data-nav")); });
  });

  sb.auth.getSession().then(function (s) { s.data.session ? start() : zeigeLogin(); });
  sb.auth.onAuthStateChange(function (ereignis) { if (ereignis === "SIGNED_IN" && appEl.hidden) start(); });
})();
