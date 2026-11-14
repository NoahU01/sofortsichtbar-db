/* Cockpit · Suche – Google Search Console und Bing Webmaster Tools.
   Quelle: analytics.suche_tage / analytics.suchbegriffe, täglich per
   Edge Function suche-import befüllt. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { tage: 28, quelle: "google", daten: null };
  var aktiv = false;

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function dez(n, e) { return n == null ? "–" : String(n).replace(".", ",") + (e || ""); }
  function tagKurz(d) { return new Date(d + "T12:00:00").toLocaleDateString("de-DE", { day: "numeric", month: "numeric" }); }
  function tagLang(d) { return new Date(d + "T12:00:00").toLocaleDateString("de-DE", { weekday: "short", day: "numeric", month: "long" }); }
  function wann(d) { return new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }); }

  function start() { aktiv = true; wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  function stop() { aktiv = false; }
  function laden() {
    api("suche", { tage: Z.tage }).then(function (d) { Z.daten = d; if (aktiv) zeichnen(); })
      .catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  function zeichnen() {
    var d = Z.daten, g = d.kennzahlen.google || {}, b = d.kennzahlen.bing || {};
    var begriffe = d.suchbegriffe.filter(function (x) { return x.quelle === Z.quelle; });
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Suche</h1><p class="leise">Wie sofortsichtbar.de bei Google und Bing gefunden wird</p></div></div>' +
      status(d.importe) +
      '<div class="filterleiste karte"><span class="flabel">Zeitraum</span><div class="seg" role="group" aria-label="Zeitraum">' +
        [7, 28, 90, 365].map(function (t) { return '<button type="button" data-s-tage="' + t + '" aria-pressed="' + (Z.tage === t) + '">' + (t === 365 ? "12 Monate" : t + " Tage") + "</button>"; }).join("") +
      '</div><span class="leise filter-hinweis">Google meldet mit 2–3 Tagen Verzögerung, Bing-Suchbegriffe wochenweise.</span></div>' +
      '<div class="kacheln">' +
        kachel("Klicks Google", zahl(g.klicks), "aus der Google-Suche") +
        kachel("Impressionen Google", zahl(g.impressionen), "so oft angezeigt") +
        kachel("Klickrate Google", g.ctr == null ? "–" : dez(g.ctr, " %"), "Klicks je Impression") +
        kachel("Ø Position Google", dez(g.position), "gewichtet nach Impressionen") +
        kachel("Klicks Bing", zahl(b.klicks), "Bing, Copilot u. a.") +
        kachel("Impressionen Bing", zahl(b.impressionen), "") +
      "</div>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Klicks aus der Google-Suche pro Tag</h2></div>' + verlauf(d.verlauf) + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Suchbegriffe</h2>' +
        '<div class="seg" role="group" aria-label="Suchmaschine">' + ["google", "bing"].map(function (q) {
          return '<button type="button" data-s-quelle="' + q + '" aria-pressed="' + (Z.quelle === q) + '">' + (q === "google" ? "Google" : "Bing") + "</button>"; }).join("") + "</div>" +
        '<span class="leise">nach Impressionen</span></div>' + tabelle(begriffe) + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Seiten in der Google-Suche</h2></div>' + seiten(d.seiten) + "</section>";
  }

  function status(importe) {
    var namen = { google: "Search Console", bing: "Bing", ga4: "Google Analytics" };
    var zeilen = ["google", "bing", "ga4"].map(function (q) {
      var i = importe.filter(function (x) { return x.quelle === q; })[0];
      if (!i) return '<span class="status status--aus"><i></i>' + namen[q] + ": noch nicht verbunden</span>";
      if (i.fehler) return '<span class="status status--fehler" title="' + esc(i.fehler) + '"><i></i>' + namen[q] + ": Fehler beim Abruf " + wann(i.gestartet) + "</span>";
      return '<span class="status status--ok"><i></i>' + namen[q] + ": abgerufen " + wann(i.gestartet) + "</span>";
    });
    return '<div class="statusleiste">' + zeilen.join("") + "</div>";
  }

  function kachel(titel, wert, hinweis) {
    return '<div class="kachel karte"><span class="flabel">' + esc(titel) + '</span><b class="kachel-wert">' + wert + "</b><small>" + esc(hinweis) + "</small></div>";
  }

  function verlauf(v) {
    if (!v.some(function (x) { return x.google_impr > 0 || x.google > 0; })) return '<p class="panel-leer">Noch keine Daten aus der Search Console.</p>';
    var max = Math.max.apply(null, v.map(function (x) { return x.google; }).concat([1]));
    var schritt = max <= 4 ? 1 : max <= 10 ? 2 : max <= 50 ? 10 : max <= 100 ? 20 : Math.ceil(max / 5 / 50) * 50;
    var oben = Math.ceil(max / schritt) * schritt;
    var cs = getComputedStyle(wurzel), innen = wurzel.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    var W = Math.max(300, Math.round(innen - 44)), H = 200, L = 36, U = 26, ob = 10, breite = (W - L) / v.length, balken = Math.min(24, breite * 0.6);
    var y = function (n) { return ob + (H - ob - U) * (1 - n / oben); };
    var s = "";
    for (var gg = 0; gg <= oben; gg += schritt) s += '<line x1="' + L + '" x2="' + W + '" y1="' + y(gg) + '" y2="' + y(gg) + '" class="achse"/><text x="' + (L - 8) + '" y="' + (y(gg) + 4) + '" text-anchor="end" class="achse-text">' + gg + "</text>";
    var jedes = Math.ceil(v.length / Math.max(2, Math.min(10, Math.floor((W - L) / 64))));
    v.forEach(function (t, i) {
      var x = L + i * breite + (breite - balken) / 2, h = (H - ob - U) * t.google / oben, r = Math.min(4, h);
      var pfad = h > 0 ? "M" + x + "," + y(0) + "v" + (-(h - r)) + "q0,-" + r + " " + r + ",-" + r + "h" + (balken - 2 * r) + "q" + r + ",0 " + r + "," + r + "v" + (h - r) + "z" : "";
      s += '<g class="saeule" data-tip="' + esc(tagLang(t.tag) + ": " + t.google + " Klicks, " + t.google_impr + " Impressionen") + '"><rect x="' + (L + i * breite) + '" y="' + ob + '" width="' + breite + '" height="' + (H - ob - U + 4) + '" class="treffer-flaeche"/>' + (pfad ? '<path d="' + pfad + '" class="balken"/>' : "") + "</g>";
      if (i % jedes === 0) s += '<text x="' + (L + i * breite + breite / 2) + '" y="' + (H - 6) + '" text-anchor="middle" class="achse-text">' + tagKurz(t.tag) + "</text>";
    });
    return '<div class="diagramm"><svg viewBox="0 0 ' + W + " " + H + '" width="100%" role="img" aria-label="Klicks aus der Google-Suche pro Tag">' + s + '</svg><div class="tooltip" hidden></div></div>';
  }

  function tabelle(z) {
    if (!z.length) return '<p class="panel-leer">Noch keine Suchbegriffe.</p>';
    return '<div class="tabelle-scroll"><table class="tabelle"><thead><tr><th>Suchbegriff</th><th class="n">Klicks</th><th class="n">Impressionen</th><th class="n">Klickrate</th><th class="n">Ø Position</th></tr></thead><tbody>' +
      z.map(function (x) {
        return "<tr><td>" + esc(x.suchbegriff) + '</td><td class="n">' + zahl(x.klicks) + '</td><td class="n">' + zahl(x.impressionen) + '</td><td class="n">' + (x.ctr == null ? "–" : dez(x.ctr, " %")) + '</td><td class="n">' + dez(x.position) + "</td></tr>";
      }).join("") + "</tbody></table></div>";
  }

  function seiten(z) {
    if (!z.length) return '<p class="panel-leer">Noch keine Daten.</p>';
    return '<table class="tabelle"><thead><tr><th>Seite</th><th class="n">Klicks</th><th class="n">Impressionen</th><th class="n">Ø Position</th></tr></thead><tbody>' +
      z.map(function (x) { return '<tr><td><span class="pfad">' + esc(x.seite || "/") + '</span></td><td class="n">' + zahl(x.klicks) + '</td><td class="n">' + zahl(x.impressionen) + '</td><td class="n">' + dez(x.position) + "</td></tr>"; }).join("") +
      "</tbody></table>";
  }

  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t = e.target.closest("[data-s-tage]");
    if (t) { Z.tage = Number(t.getAttribute("data-s-tage")); wurzel.querySelector(".kacheln").style.opacity = ".5"; return laden(); }
    var q = e.target.closest("[data-s-quelle]");
    if (q) { Z.quelle = q.getAttribute("data-s-quelle"); zeichnen(); }
  });
  var groesse;
  window.addEventListener("resize", function () { clearTimeout(groesse); groesse = setTimeout(function () { if (aktiv && Z.daten) zeichnen(); }, 200); });

  C.module.suche = { start: start, stop: stop };
})();
