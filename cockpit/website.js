/* Cockpit · Website – was auf sofortsichtbar.de passiert.
   Quelle: eigenes First-Party-Tracking (core.events, source = website).
   Besucher und Sitzungen gibt es nur bei Einwilligung (Statistik);
   Seitenaufrufe zählen auch ohne. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { tage: 30, intern: false, daten: null };
  var aktiv = false;

  var SEITENTYP = { home: "Startseite", preis: "Preise", kontakt: "Kontakt", zielgruppe: "Zielgruppen", produkt: "Produkt",
                    rechtliches: "Rechtliches", karriere: "Karriere", blog: "Blog", referenz: "Referenzen", sonstige: "Sonstige" };
  var KLICKZIEL = { kontakt: "Zur Kontaktseite", mail: "E-Mail", telefon: "Telefon", zielgruppe: "Zielgruppen-Seite", sonstige: "Sonstige" };

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function prozent(a, b) { return b ? Math.round(100 * a / b) + " %" : "–"; }
  function tagKurz(d) { return new Date(d + "T12:00:00").toLocaleDateString("de-DE", { day: "numeric", month: "numeric" }); }
  function tagLang(d) { return new Date(d + "T12:00:00").toLocaleDateString("de-DE", { weekday: "short", day: "numeric", month: "long" }); }
  function name(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1).replace(/[-_]/g, " ") : "–"; }

  function start() {
    aktiv = true;
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    laden();
  }
  function stop() { aktiv = false; }

  function laden() {
    api("website", { tage: Z.tage, intern: Z.intern }).then(function (d) { Z.daten = d; if (aktiv) zeichnen(); })
      .catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  /* ---------- Darstellung ---------- */
  function zeichnen() {
    var d = Z.daten, k = d.kennzahlen;
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Website</h1><p class="leise">sofortsichtbar.de · eigenes Tracking, ohne Google</p></div></div>' +
      '<div class="filterleiste karte">' +
        '<span class="flabel">Zeitraum</span><div class="seg" role="group" aria-label="Zeitraum">' +
          [7, 30, 90].map(function (t) { return '<button type="button" data-tage="' + t + '" aria-pressed="' + (Z.tage === t) + '">' + t + " Tage</button>"; }).join("") +
        "</div>" +
        '<label class="schalter"><input type="checkbox" data-intern' + (Z.intern ? " checked" : "") + "> Eigene Zugriffe und Vorschau einrechnen</label>" +
      "</div>" +
      '<div class="kacheln">' +
        kachel("Seitenaufrufe", zahl(k.seitenaufrufe), "alle, auch ohne Einwilligung") +
        kachel("Besucher", zahl(k.besucher), "mit Einwilligung, wiedererkannt") +
        kachel("Sitzungen", zahl(k.sitzungen), "mit Einwilligung") +
        kachel("Einwilligung", k.einwilligung == null ? "–" : k.einwilligung + " %", "Anteil der Seitenaufrufe") +
        kachel("Kalender geöffnet", zahl(k.kalender), "Cal.com-Kalender angezeigt") +
        kachel("Termine gebucht", zahl(k.buchungen), "über die Website") +
      "</div>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Seitenaufrufe pro Tag</h2></div>' + verlauf(d.verlauf) + "</section>" +
      '<div class="raster">' +
        panel("Woher die Besucher kommen", "nur Sitzungen mit Einwilligung", quellen(d.quellen)) +
        panel("Weg zur Buchung", "im Zeitraum", trichter(k)) +
        panel("Seiten", "meistgesehen", seiten(d.seiten)) +
        panel("Klicks auf Kontaktwege", "", liste(d.klicks.map(function (x) { return [KLICKZIEL[x.ziel] || name(x.ziel), x.anzahl]; }), "Noch keine Klicks.")) +
      "</div>" +
      panel("Abschnitte", "Wie weit gescrollt wird und wie lange jeder Abschnitt gelesen wird", abschnitte(d.abschnitte), true) +
      '<div class="raster">' +
        panel("Geräte", "Anteil der Seitenaufrufe", liste(d.geraete.map(function (x) { return [name(x.geraet), x.anteil + " %"]; }), "Noch keine Daten.")) +
      "</div>";
  }

  function kachel(titel, wert, hinweis) {
    return '<div class="kachel karte"><span class="flabel">' + esc(titel) + '</span><b class="kachel-wert">' + wert + "</b><small>" + esc(hinweis) + "</small></div>";
  }
  function panel(titel, sub, inhalt, breit) {
    return '<section class="karte panel' + (breit ? " panel--breit" : "") + '"><div class="panel-kopf"><h2>' + esc(titel) + "</h2>" +
      (sub ? '<span class="leise">' + esc(sub) + "</span>" : "") + "</div>" + inhalt + "</section>";
  }
  function leer(t) { return '<p class="panel-leer">' + esc(t) + "</p>"; }

  // Säulen je Tag: eine Reihe, eine Farbe, Hover zeigt den Wert.
  function verlauf(v) {
    if (!v.length) return leer("Keine Daten.");
    var max = Math.max.apply(null, v.map(function (x) { return x.seitenaufrufe; }).concat([1]));
    var schritt = max <= 4 ? 1 : max <= 10 ? 2 : max <= 50 ? 10 : max <= 100 ? 20 : Math.ceil(max / 5 / 50) * 50;
    var oben = Math.ceil(max / schritt) * schritt;
    var cs = getComputedStyle(wurzel), innen = wurzel.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    var W = Math.max(300, Math.round(innen - 2 * 22)), H = 220, L = 36, U = 26, ob = 10, breite = (W - L) / v.length, balken = Math.min(24, breite * 0.6);
    var y = function (n) { return ob + (H - ob - U) * (1 - n / oben); };
    var raster = "", s = "";
    for (var g = 0; g <= oben; g += schritt) {
      raster += '<line x1="' + L + '" x2="' + W + '" y1="' + y(g) + '" y2="' + y(g) + '" class="achse"/>' +
        '<text x="' + (L - 8) + '" y="' + (y(g) + 4) + '" text-anchor="end" class="achse-text">' + g + "</text>";
    }
    var jedes = Math.ceil(v.length / Math.max(2, Math.min(10, Math.floor((W - L) / 64))));
    v.forEach(function (t, i) {
      var x = L + i * breite + (breite - balken) / 2, h = (H - ob - U) * t.seitenaufrufe / oben, r = Math.min(4, h);
      var pfad = h > 0 ? "M" + x + "," + (y(0)) + "v" + (-(h - r)) + "q0,-" + r + " " + r + ",-" + r + "h" + (balken - 2 * r) + "q" + r + ",0 " + r + "," + r + "v" + (h - r) + "z" : "";
      s += '<g class="saeule" data-tip="' + esc(tagLang(t.tag) + ": " + t.seitenaufrufe + " Seitenaufrufe, " + t.sitzungen + " Sitzungen") + '">' +
        '<rect x="' + (L + i * breite) + '" y="' + ob + '" width="' + breite + '" height="' + (H - ob - U + 4) + '" class="treffer-flaeche"/>' +
        (pfad ? '<path d="' + pfad + '" class="balken"/>' : "") + "</g>";
      if (i % jedes === 0) s += '<text x="' + (L + i * breite + breite / 2) + '" y="' + (H - 6) + '" text-anchor="middle" class="achse-text">' + tagKurz(t.tag) + "</text>";
    });
    return '<div class="diagramm"><svg viewBox="0 0 ' + W + " " + H + '" width="100%" role="img" aria-label="Seitenaufrufe pro Tag">' + raster + s + '</svg><div class="tooltip" hidden></div></div>';
  }

  function quellen(q) {
    if (!q.length) return leer("Noch keine Sitzungen mit Einwilligung.");
    return '<table class="tabelle"><thead><tr><th>Quelle</th><th class="n">Sitzungen</th><th class="n">Kalender</th><th class="n">Buchungen</th></tr></thead><tbody>' +
      q.map(function (x) { return "<tr><td>" + esc(x.quelle) + '</td><td class="n">' + zahl(x.sitzungen) + '</td><td class="n">' + zahl(x.kalender) + '</td><td class="n">' + zahl(x.buchungen) + "</td></tr>"; }).join("") +
      "</tbody></table>";
  }

  function seiten(s) {
    if (!s.length) return leer("Noch keine Seitenaufrufe.");
    return '<table class="tabelle"><thead><tr><th>Seite</th><th class="n">Aufrufe</th><th class="n">Sitzungen</th></tr></thead><tbody>' +
      s.map(function (x) { return '<tr><td><span class="pfad">' + esc(x.pfad) + '</span> <small class="leise">' + esc(SEITENTYP[x.seitentyp] || "") + '</small></td><td class="n">' + zahl(x.aufrufe) + '</td><td class="n">' + zahl(x.sitzungen) + "</td></tr>"; }).join("") +
      "</tbody></table>";
  }

  function trichter(k) {
    var stufen = [["Seitenaufrufe", k.seitenaufrufe], ["Kalender geöffnet", k.kalender], ["Termin gebucht", k.buchungen]];
    var max = Math.max(k.seitenaufrufe, 1);
    return '<div class="trichter">' + stufen.map(function (s, i) {
      return '<div class="stufe"><div class="stufe-kopf"><span>' + esc(s[0]) + "</span><b>" + zahl(s[1]) + "</b>" +
        (i ? '<small class="leise">' + prozent(s[1], stufen[i - 1][1]) + " der Stufe davor</small>" : "") + "</div>" +
        '<div class="spur"><div class="fuellung" style="width:' + Math.max(s[1] ? 1.5 : 0, 100 * s[1] / max) + '%"></div></div></div>';
    }).join("") + "</div>";
  }

  function abschnitte(a) {
    if (!a.length) return leer("Noch keine Daten zu Abschnitten.");
    var gruppen = {};
    a.forEach(function (x) { (gruppen[x.seitentyp] = gruppen[x.seitentyp] || []).push(x); });
    return '<div class="abschnitt-raster">' + Object.keys(gruppen).map(function (typ) {
      return '<div><h3 class="abschnitt-titel">' + esc(SEITENTYP[typ] || name(typ)) + '</h3><table class="tabelle"><thead><tr><th>Abschnitt</th><th>Erreicht</th><th class="n">Ø Lesezeit</th></tr></thead><tbody>' +
        gruppen[typ].map(function (x) {
          var r = Math.min(100, x.reichweite || 0);
          return "<tr><td>" + esc(name(x.abschnitt)) + '</td><td><div class="reichweite"><div class="spur"><div class="fuellung" style="width:' + r + '%"></div></div><span>' + (x.reichweite == null ? "–" : x.reichweite + " %") + "</span></div></td>" +
            '<td class="n">' + (x.sekunden == null ? "–" : String(x.sekunden).replace(".", ",") + " s") + "</td></tr>";
        }).join("") + "</tbody></table></div>";
    }).join("") + "</div>";
  }

  function liste(zeilen, leerText) {
    if (!zeilen.length) return leer(leerText);
    return '<table class="tabelle"><tbody>' + zeilen.map(function (z) { return "<tr><td>" + esc(z[0]) + '</td><td class="n">' + (typeof z[1] === "number" ? zahl(z[1]) : esc(z[1])) + "</td></tr>"; }).join("") + "</tbody></table>";
  }

  /* ---------- Bedienung ---------- */
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var b = e.target.closest("[data-tage]"); if (!b) return;
    Z.tage = Number(b.getAttribute("data-tage")); wurzel.querySelector(".kacheln").style.opacity = ".5"; laden();
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv || !e.target.hasAttribute("data-intern")) return;
    Z.intern = e.target.checked; laden();
  });
  // Tooltip am Diagramm
  wurzel.addEventListener("mousemove", function (e) {
    if (!aktiv) return;
    var g = e.target.closest && e.target.closest(".saeule"), d = e.target.closest && e.target.closest(".diagramm");
    if (!d) return;
    var tip = d.querySelector(".tooltip");
    d.querySelectorAll(".saeule--hover").forEach(function (x) { if (x !== g) x.classList.remove("saeule--hover"); });
    if (!g) { tip.hidden = true; return; }
    g.classList.add("saeule--hover");
    var box = d.getBoundingClientRect();
    tip.textContent = g.getAttribute("data-tip"); tip.hidden = false;
    var x = e.clientX - box.left, w = tip.offsetWidth;
    tip.style.left = Math.max(0, Math.min(box.width - w, x - w / 2)) + "px";
    tip.style.top = Math.max(0, e.clientY - box.top - 44) + "px";
  });
  wurzel.addEventListener("mouseout", function (e) {
    var d = e.target.closest && e.target.closest(".diagramm");
    if (d && !d.contains(e.relatedTarget)) { d.querySelector(".tooltip").hidden = true; d.querySelectorAll(".saeule--hover").forEach(function (x) { x.classList.remove("saeule--hover"); }); }
  });
  var groesse;
  window.addEventListener("resize", function () { clearTimeout(groesse); groesse = setTimeout(function () { if (aktiv && Z.daten) zeichnen(); }, 200); });

  C.module.website = { start: start, stop: stop };
})();
