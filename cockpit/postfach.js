/* Cockpit · Postfach – Microsoft-365-Postfächer von sofort sichtbar.
   Zeigt den Stand je Postfach und die externen Absender, die noch kein
   Kontakt sind: übernehmen (wird Kontakt, frühere Mails hängen an) oder
   ignorieren (taucht nicht mehr auf). */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { tage: 30, daten: null };
  var aktiv = false;

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function wann(d) { return d ? new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "–"; }

  function start() { aktiv = true; wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  function stop() { aktiv = false; }
  function laden() {
    return api("postfach", { tage: Z.tage }).then(function (d) {
      Z.daten = d;
      var z = document.querySelector('[data-zahl="postfach"]'); if (z) z.textContent = d.unbekannt.length || "";
      if (aktiv) zeichnen();
    }).catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  function zeichnen() {
    var d = Z.daten, imp = d.importe[0];
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Postfach</h1><p class="leise">Mails und Kalender aller @sofortsichtbar.de-Postfächer · alle 15 Minuten</p></div></div>' +
      '<div class="statusleiste">' + (imp ? (imp.fehler
          ? '<span class="status status--fehler" title="' + esc(imp.fehler) + '"><i></i>Letzter Abruf ' + wann(imp.gestartet) + " mit Fehlern</span>"
          : '<span class="status status--ok"><i></i>Letzter Abruf ' + wann(imp.gestartet) + " · " + zahl(imp.zeilen) + " neue Einträge</span>")
        : '<span class="status status--aus"><i></i>Noch kein Abruf</span>') + "</div>" +
      '<div class="filterleiste karte"><span class="flabel">Zeitraum</span><div class="seg" role="group" aria-label="Zeitraum">' +
        [7, 30, 90].map(function (t) { return '<button type="button" data-p-tage="' + t + '" aria-pressed="' + (Z.tage === t) + '">' + t + " Tage</button>"; }).join("") +
      "</div></div>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Unbekannte Absender</h2><span class="leise">extern, noch kein Kontakt · ' + d.unbekannt.length + "</span></div>" +
        unbekannt(d.unbekannt) + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Postfächer</h2><span class="leise">' + zahl(d.zugeordnet) + " Mails und Termine im Zeitraum Kontakten zugeordnet</span></div>" +
        postfaecher(d.postfaecher) + "</section>";
  }

  function unbekannt(l) {
    if (!l.length) return '<p class="panel-leer">Keine – alle externen Absender sind zugeordnet oder ignoriert.</p>';
    return '<ul class="absender">' + l.map(function (a) {
      return '<li class="absender-z"><div class="absender-wer"><b>' + esc(a.name || a.email) + "</b>" + (a.name ? ' <span class="leise">' + esc(a.email) + "</span>" : "") +
          '<small class="leise">' + zahl(a.mails) + (a.mails === 1 ? " Mail" : " Mails") + " · zuletzt " + wann(a.letzte) + "</small>" +
          (a.betreff ? '<span class="absender-betreff">' + esc(a.betreff) + "</span>" : "") +
          (a.vorschau ? '<span class="absender-vorschau">' + esc(a.vorschau) + "</span>" : "") + "</div>" +
        '<div class="knoepfe"><button type="button" class="knopf knopf--primaer" data-uebernehmen="' + esc(a.email) + '" data-name="' + esc(a.name || "") + '">Als Kontakt übernehmen</button>' +
        '<button type="button" class="knopf" data-ignorieren="' + esc(a.email) + '">Ignorieren</button></div></li>';
    }).join("") + "</ul>";
  }

  function postfaecher(l) {
    if (!l.length) return '<p class="panel-leer">Noch keine Postfächer abgerufen.</p>';
    return '<table class="tabelle"><thead><tr><th>Postfach</th><th class="n">Mails gesamt</th><th class="n">im Zeitraum</th><th class="n">Termine</th><th>Stand</th></tr></thead><tbody>' +
      l.map(function (p) {
        return '<tr><td><span class="pfad">' + esc(p.postfach) + '</span></td><td class="n">' + zahl(p.mails) + '</td><td class="n">' + zahl(p.mails_zeitraum) + '</td><td class="n">' + zahl(p.termine) + "</td>" +
          "<td>" + (p.fehler ? '<span class="status status--fehler" title="' + esc(p.fehler) + '"><i></i>Fehler</span>' : '<span class="status status--ok"><i></i>' + wann(p.aktualisiert) + "</span>") + "</td></tr>";
      }).join("") + "</tbody></table>";
  }

  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t = e.target.closest("[data-p-tage]");
    if (t) { Z.tage = Number(t.getAttribute("data-p-tage")); return laden(); }
    var u = e.target.closest("[data-uebernehmen]");
    if (u) {
      u.disabled = true; u.textContent = "Wird übernommen …";
      return api("absender_uebernehmen", { email: u.getAttribute("data-uebernehmen"), name: u.getAttribute("data-name") })
        .then(laden)
        .catch(function (err) { u.disabled = false; u.textContent = "Fehler: " + err.message; });
    }
    var g = e.target.closest("[data-ignorieren]");
    if (g) {
      g.disabled = true;
      return api("absender_ignorieren", { email: g.getAttribute("data-ignorieren") }).then(laden)
        .catch(function (err) { g.disabled = false; g.textContent = "Fehler: " + err.message; });
    }
  });

  C.module.postfach = { start: start, stop: stop };
})();
