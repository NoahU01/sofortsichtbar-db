/* Cockpit · Einstellungen – Datenquellen: läuft jede Anbindung, wann kam
   zuletzt etwas an, gab es Fehler. Darunter der Stand je Postfach. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var aktiv = false, daten = null;

  // max: nach wie vielen Stunden ohne Abruf etwas nicht stimmt
  var ABRUFE = [
    { q: "postfach", name: "Postfach (Microsoft 365)", was: "Mails und Termine aller @sofortsichtbar.de-Postfächer", takt: "alle 15 Min.", max: 1 },
    { q: "buffer", name: "Buffer", was: "Beiträge und Zahlen von LinkedIn, Facebook, Instagram", takt: "2× täglich", max: 26 },
    { q: "google", name: "Google Search Console", was: "Suchbegriffe, Klicks, Impressionen", takt: "täglich", max: 30 },
    { q: "ga4", name: "Google Analytics 4", was: "Nutzer, Sitzungen, Seitenaufrufe", takt: "täglich", max: 30 },
    { q: "bing", name: "Bing Webmaster", was: "Suchbegriffe aus Bing", takt: "täglich", max: 30 }
  ];
  var EINGANG = [
    { q: "website", name: "Website-Tracking", was: "Besuche und Klicks auf sofortsichtbar.de", takt: "laufend" },
    { q: "cal", name: "Terminbuchung (Cal.com)", was: "Buchungen und Absagen", takt: "bei jeder Buchung" }
  ];

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function wann(d) {
    if (!d) return "–";
    var t = new Date(d), min = Math.round((Date.now() - t) / 6e4);
    if (min < 1) return "gerade eben";
    if (min < 60) return "vor " + min + " Min.";
    if (min < 24 * 60 && t.getDate() === new Date().getDate()) return "heute, " + t.toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
    return t.toLocaleString("de-DE", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }
  function status(art, text, titel) {
    return '<span class="dq-status dq-status--' + art + '"' + (titel ? ' title="' + esc(titel) + '"' : "") + "><i></i>" + text + "</span>";
  }

  function start() { aktiv = true; wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  function stop() { aktiv = false; }
  function laden() {
    return api("datenquellen", {}).then(function (d) { daten = d; if (aktiv) zeichnen(); })
      .catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  function zeile(q, s, letzter, info, hinweis) {
    return '<li class="dq"><div class="dq-wer"><b>' + esc(q.name) + '</b><span class="leise">' + esc(q.was) + "</span>" +
        (hinweis ? '<span class="dq-hinweis' + (s.indexOf("dq-status--fehler") < 0 ? " dq-hinweis--leise" : "") + '">' + esc(hinweis) + "</span>" : "") + "</div>" +
      '<span class="dq-takt leise">' + esc(q.takt) + "</span>" +
      '<span class="dq-wann"><span>' + letzter + "</span>" + (info ? '<small class="leise">' + info + "</small>" : "") + "</span>" +
      s + "</li>";
  }

  function zeichnen() {
    var d = daten, a = d.abrufe || {}, ev = d.ereignisse || {}, probleme = 0;
    var zeilen = ABRUFE.map(function (q) {
      var x = a[q.q], s, hinweis = "";
      if (!x) s = status("aus", "noch kein Abruf");
      else if (x.fehler) { s = status("fehler", "Fehler", x.fehler); hinweis = x.fehler.slice(0, 160); probleme++; }
      else if ((Date.now() - new Date(x.letzter)) / 36e5 > q.max) { s = status("warn", "verzögert"); probleme++; }
      else s = status("ok", "läuft");
      var info = x ? zahl(x.zeilen) + " neue Einträge" + (x.fehler_7t ? " · " + x.fehler_7t + " Fehler in 7 Tagen" : "") : "";
      return zeile(q, s, x ? wann(x.letzter) : "–", info, hinweis);
    }).concat(EINGANG.map(function (q) {
      var x = ev[q.q];
      return zeile(q, x ? status("ok", "empfängt") : status("aus", "nichts in 90 Tagen"), x ? wann(x.letzter) : "–",
        x ? zahl(x.anzahl_7t) + " in den letzten 7 Tagen" : "", "");
    }));

    var n = d.newsletter, nlStatus, nlInfo = "";
    if (!n) nlStatus = status("aus", "nicht eingerichtet");
    else if (n.fehler) { nlStatus = status("fehler", "Fehler", n.fehler); probleme++; }
    else if (n.produktion === false) nlStatus = status("warn", "Testmodus");
    else { nlStatus = status("ok", "bereit"); nlInfo = zahl(n.gesendet_24h) + " von " + zahl(n.max_24h) + " Mails in 24 Std."; }
    zeilen.push(zeile({ name: "Newsletter-Versand (Amazon SES)", was: "als Daniel Ströbel, über sofortsichtbar.de", takt: "jede Minute" },
      nlStatus, n ? wann(n.geprueft) : "–", nlInfo, n && n.fehler ? n.fehler.slice(0, 160) : (n ? "" : "Zugangsschlüssel fehlt noch (scripts/ses-einrichten.sh)")));

    var li = d.linkedin || {};
    zeilen.push(zeile({ name: "LinkedIn-Reaktionen", was: "werden von Hand eingefügt, Buffer meldet fehlende", takt: "von Hand" },
      li.reaktionen_zuletzt ? status("ok", "aktiv") : status("aus", "noch nichts eingefügt"), wann(li.reaktionen_zuletzt),
      zahl(li.personen) + " Personen erfasst", ""));

    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Einstellungen</h1><p class="leise">Datenquellen und Anbindungen</p></div>' +
        '<button type="button" class="knopf" data-dq-neu>Aktualisieren</button></div>' +
      '<section class="karte panel"><div class="panel-kopf"><h2>Datenquellen</h2><span class="leise">' +
        (probleme ? probleme + (probleme === 1 ? " Quelle braucht" : " Quellen brauchen") + " Aufmerksamkeit" : "alles läuft") + "</span></div>" +
        '<ul class="dq-liste">' + zeilen.join("") + "</ul></section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Postfächer</h2><span class="leise">Microsoft 365 · Mails und Kalender</span></div>' +
        postfaecher(d.postfaecher || []) + "</section>";
  }

  function postfaecher(l) {
    if (!l.length) return '<p class="panel-leer">Noch keine Postfächer abgerufen.</p>';
    return '<div class="tabelle-rahmen"><table class="tabelle"><thead><tr><th>Postfach</th><th class="n">Mails</th><th class="n">Termine</th><th>Stand</th></tr></thead><tbody>' +
      l.map(function (p) {
        return '<tr><td><span class="pfad">' + esc(p.postfach) + '</span></td><td class="n">' + zahl(p.mails) + '</td><td class="n">' + zahl(p.termine) + "</td><td>" +
          (p.fehler ? status("fehler", "Fehler", p.fehler) : status("ok", wann(p.aktualisiert))) + "</td></tr>";
      }).join("") + "</tbody></table></div>";
  }

  wurzel.addEventListener("click", function (e) {
    if (aktiv && e.target.closest("[data-dq-neu]")) { wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  });

  C.module.einstellungen = { start: start, stop: stop };
})();
