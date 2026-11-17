/* Cockpit · LinkedIn – wer auf Beiträge der Firmenseite und von Daniel reagiert.
   Quelle: Reaktionsliste in LinkedIn kopieren und hier einfügen. Die Erkennung
   läuft im Browser; gespeichert werden Name, Position und Art der Reaktion.
   Zuordnung zu Kontakten nur von Hand (Name allein ist kein sicherer Schlüssel). */
(function () {
  "use strict";

  /* ---------- Erkennung (ohne DOM, auch in Tests nutzbar) ---------- */
  var ARTEN = {
    like: "like", celebrate: "celebrate", support: "support", love: "love", insightful: "insightful", funny: "funny",
    "gefällt mir": "like", applaus: "celebrate", "unterstützung": "support", "unterstützen": "support", "liebe": "love",
    interessant: "insightful", witzig: "funny", lustig: "funny"
  };
  var PROFIL = [/Profil von (.+?) anzeigen/i, /^View (.+?)[’']s\s+(?:verified\s+)?profile/i];

  function profilName(z) {
    for (var i = 0; i < PROFIL.length; i++) { var m = PROFIL[i].exec(z); if (m) return m[1].trim(); }
    return null;
  }
  function art(z) { return z ? ARTEN[z.toLowerCase()] || null : null; }

  function erkenne(text) {
    var z = String(text || "").split(/\r?\n/).map(function (s) { return s.replace(/\s+/g, " ").trim(); });
    var personen = [], gesehen = {};
    for (var i = 0; i < z.length; i++) {
      var name = profilName(z[i]);
      if (!name) continue;
      // Art der Reaktion: steht direkt über dem Namen (oder über der Profilzeile, falls die Namenszeile fehlt)
      var a = art(z[i - 1] === name ? z[i - 2] : z[i - 1]) || "reaktion";
      // Position: nächste Zeile nach dem Verbindungsgrad („· 2.“), sofern sie nicht schon die nächste Person ist
      var k = i + 1;
      while (k < z.length && (z[k] === "" || /^[·•]/.test(z[k]))) k++;
      var position = "";
      if (k < z.length && !art(z[k]) && !profilName(z[k]) && !(k + 1 < z.length && profilName(z[k + 1]))) position = z[k];
      var key = name.toLowerCase();
      if (gesehen[key]) continue;
      gesehen[key] = true;
      personen.push({ name: name, position: position, art: a });
    }
    return personen;
  }

  // Reaktionen von Seiten/Firmen (kein Personenprofil), z. B. die Firmenseite selbst:
  // Reaktions-Zeile, darunter ein Name, danach keine Profilzeile.
  function weitere(text) {
    var z = String(text || "").split(/\r?\n/).map(function (s) { return s.replace(/\s+/g, " ").trim(); });
    var namen = {};
    for (var i = 0; i + 1 < z.length; i++) {
      var n = z[i + 1], danach = z[i + 2] || "";
      if (!art(z[i]) || !n || art(n) || profilName(n) || /^[·•\d]/.test(n)) continue;
      if (profilName(danach) || (danach && !art(danach))) continue;
      namen[n.toLowerCase()] = true;
    }
    return Object.keys(namen).length;
  }

  // Follower-Tabelle aus Excel/Sheets (Tab-getrennt, sonst ; oder ,) mit Kopfzeile
  var MONAT = { januar: 1, jan: 1, january: 1, februar: 2, feb: 2, february: 2, "märz": 3, maerz: 3, mar: 3, march: 3, april: 4, apr: 4,
    mai: 5, may: 5, juni: 6, jun: 6, june: 6, juli: 7, jul: 7, july: 7, august: 8, aug: 8, september: 9, sep: 9, sept: 9,
    oktober: 10, okt: 10, oct: 10, october: 10, november: 11, nov: 11, dezember: 12, dez: 12, dec: 12, december: 12 };
  function monat(s) {
    s = String(s || "").trim().toLowerCase();
    var m = /^([a-zäöü]+)\.?\s+(\d{4})$/.exec(s);
    if (m && MONAT[m[1]]) return m[2] + "-" + ("0" + MONAT[m[1]]).slice(-2) + "-01";
    m = /^(\d{1,2})[./](\d{4})$/.exec(s); if (m && +m[1] >= 1 && +m[1] <= 12) return m[2] + "-" + ("0" + m[1]).slice(-2) + "-01";
    m = /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(s); if (m) return m[1] + "-" + m[2] + "-" + (m[3] || "01");
    m = /^(\d{1,2})\.(\d{1,2})\.(\d{4})$/.exec(s); if (m) return m[3] + "-" + ("0" + m[2]).slice(-2) + "-" + ("0" + m[1]).slice(-2);
    return "";
  }
  function erkenneFollower(text) {
    var zeilen = String(text || "").split(/\r?\n/).filter(function (z) { return z.trim(); });
    if (zeilen.length < 2) return { follower: [], fehlt: "Kopfzeile und mindestens eine Zeile" };
    var trenner = zeilen[0].indexOf("\t") >= 0 ? "\t" : zeilen[0].indexOf(";") >= 0 ? ";" : ",";
    var kopf = zeilen[0].split(trenner).map(function (k) { return k.trim().toLowerCase(); });
    function spalte(re) { for (var i = 0; i < kopf.length; i++) if (re.test(kopf[i])) return i; return -1; }
    var s = { name: spalte(/^(name|vollständiger name|full name)/), unternehmen: spalte(/^(unternehmen|firma|company)/),
              position: spalte(/^(position|headline|titel|job)/), seit: spalte(/(folgt|follow|seit|since)/),
              link: spalte(/(link|url|profil|linkedin)/) };
    if (s.name < 0) return { follower: [], fehlt: "Spalte „Name“" };
    var mitLink = 0, follower = [];
    zeilen.slice(1).forEach(function (z) {
      var c = z.split(trenner).map(function (x) { return x.trim().replace(/^"|"$/g, ""); });
      var name = c[s.name] || "";
      if (!name) return;
      var link = s.link >= 0 ? c[s.link] || "" : "";
      if (!/^https?:\/\/([a-z]+\.)?linkedin\.com\/in\//i.test(link)) link = ""; else mitLink++;
      follower.push({ name: name, unternehmen: s.unternehmen >= 0 ? c[s.unternehmen] || "" : "", position: s.position >= 0 ? c[s.position] || "" : "",
                      folgt_seit: s.seit >= 0 ? monat(c[s.seit]) : "", profil_url: link });
    });
    return { follower: follower, mitLink: mitLink, spalten: s };
  }

  var ARTNAME = { like: "Gefällt mir", celebrate: "Applaus", support: "Unterstützung", love: "Liebe", insightful: "Interessant", funny: "Witzig", reaktion: "Reaktion" };
  var KANAL = { firmenseite: "Firmenseite", daniel: "Daniel" };

  if (typeof window === "undefined" || !window.cockpit) {
    if (typeof module !== "undefined") module.exports = { erkenne: erkenne, weitere: weitere, erkenneFollower: erkenneFollower };
    return;
  }

  /* ---------- Modul ---------- */
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { daten: null, filter: "mehrfach", beitrag: null, kanal: "firmenseite", titel: "", datum: "", url: "", text: "", erkannt: [], weitere: 0, meldung: "", suche: null, alleBeitraege: false, fText: "", fErkannt: null, fMeldung: "", ausgeblendetOffen: false, sicht: "alle", bSicht: "alle" };
  try { var gemerkt = localStorage.getItem("cockpit.linkedin.sicht"); if (gemerkt === "firmenseite" || gemerkt === "daniel") Z.sicht = gemerkt; } catch (e) { /* ohne Speicher */ }
  var aktiv = false;

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function tag(d) { return d ? new Date(d).toLocaleDateString("de-DE", { day: "numeric", month: "short", year: "numeric" }) : "–"; }

  function start() { aktiv = true; wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  function stop() { aktiv = false; }
  function laden() {
    return api("linkedin", {}).then(function (d) {
      Z.daten = d;
      var offen = d.personen.filter(function (p) { return p.reaktionen > 1 && !p.kontakt && !p.ignoriert; }).length;
      var el = document.querySelector('[data-zahl="linkedin"]'); if (el) el.textContent = (offen + nachtragen(d.beitraege).length) || "";
      if (aktiv) zeichnen();
    }).catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  // Beiträge, bei denen laut Buffer Reaktionen fehlen (nur beobachtete: schon erfasst oder jünger als 30 Tage)
  function nachtragen(l) { return l.filter(function (b) { return b.beobachtet && b.fehlen > 0; }); }
  // Ansicht Alle / Firmenseite / Daniel
  function B() { return Z.daten.beitraege.filter(function (b) { return Z.sicht === "alle" || b.kanal === Z.sicht; }); }
  function P() {
    if (Z.sicht === "alle") return Z.daten.personen;
    return Z.daten.personen.filter(function (p) { return p[Z.sicht] > 0; })
      .map(function (p) { var x = {}; for (var k in p) x[k] = p[k]; x.reaktionen = p[Z.sicht]; return x; })
      .sort(function (a, b) { return b.reaktionen - a.reaktionen || (b.letzte > a.letzte ? 1 : -1); });
  }
  function wann(d) { return d ? new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "–"; }

  function zeichnen() {
    var d = Z.daten, offen = nachtragen(B()), pers = P();
    var mehrfach = pers.filter(function (p) { return p.reaktionen > 1 && !p.ignoriert; }).length;
    var mitKontakt = pers.filter(function (p) { return p.kontakt && !p.ignoriert; }).length;
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>LinkedIn</h1><p class="leise">' +
        ({ alle: "Wer auf Beiträge der Firmenseite und von Daniel reagiert", firmenseite: "Wer auf Beiträge der Firmenseite reagiert", daniel: "Wer auf Daniels Beiträge (#sofortsichtbar) reagiert" })[Z.sicht] + " · " +
        zahl(B().length) + " Beiträge · " + zahl(pers.filter(function (p) { return !p.ignoriert; }).length) + " Personen · " +
        zahl(mehrfach) + " mehrfach · " + zahl(mitKontakt) + " mit Kontakt</p></div>" +
        '<div class="seg li-sicht" role="group" aria-label="Ansicht">' + [["alle", "Alle"], ["firmenseite", "Firmenseite"], ["daniel", "Daniel"]].map(function (x) {
          return '<button type="button" data-li-sicht="' + x[0] + '" aria-pressed="' + (Z.sicht === x[0]) + '">' + x[1] + "</button>";
        }).join("") + "</div></div>" +
      '<div class="statusleiste">' + (d.import ? (d.import.fehler
          ? '<span class="status status--fehler" title="' + esc(d.import.fehler) + '"><i></i>Buffer: letzter Abruf ' + wann(d.import.gestartet) + " mit Fehler</span>"
          : '<span class="status status--ok"><i></i>Buffer: Abruf ' + wann(d.import.gestartet) + " · Zahlen von Buffer vom " + wann(d.buffer && d.buffer.stand) + "</span>")
        : '<span class="status status--aus"><i></i>Buffer: noch kein Abruf</span>') + "</div>" +
      (offen.length ? '<section class="karte panel li-nachtragen"><div class="panel-kopf"><h2>Nachtragen</h2><span class="leise">laut Buffer neue Reaktionen, die noch nicht erfasst sind</span></div><ul class="absender">' +
        offen.map(function (b) {
          return '<li class="absender-z"><div class="absender-wer"><b>' + esc(b.titel) + '</b><small class="leise">' + KANAL[b.kanal] + " · " + tag(b.veroeffentlicht) +
            " · " + zahl(b.laut_buffer) + " Reaktionen laut Buffer, " + zahl(b.erfasst + b.weitere) + " erfasst</small></div>" +
            '<div class="knoepfe"><span class="pille pille--verloren">' + b.fehlen + (b.fehlen === 1 ? " fehlt" : " fehlen") + "</span>" +
            (b.url ? '<a class="knopf" href="' + esc(b.url) + '" target="_blank" rel="noopener">In LinkedIn öffnen</a>' : "") +
            '<button type="button" class="knopf knopf--primaer" data-li-nachtragen="' + b.beitrag_id + '">Liste einfügen</button></div></li>';
        }).join("") + "</ul></section>" : "") +
      '<section class="karte panel" data-li-form>' + formular() + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Personen</h2><div class="seg" role="group" aria-label="Filter">' +
        [["mehrfach", "Mehrfach"], ["alle", "Alle"], ["offen", "Ohne Kontakt"], ["ignoriert", "Ignoriert"]].map(function (f) {
          return '<button type="button" data-li-filter="' + f[0] + '" aria-pressed="' + (Z.filter === f[0]) + '">' + f[1] + "</button>";
        }).join("") + "</div></div>" + personen() + "</section>" +
      '<section class="karte panel"><div class="panel-kopf li-b-kopf"><h2>Beiträge</h2><span class="leise">aus Buffer, täglich aktualisiert · Daniel nur mit #sofortsichtbar</span>' +
        (Z.sicht === "alle" ? '<div class="seg" role="group" aria-label="Beiträge filtern">' + [["alle", "Alle"], ["firmenseite", "Firmenseite"], ["daniel", "Daniel"]].map(function (x) {
          return '<button type="button" data-li-bsicht="' + x[0] + '" aria-pressed="' + (Z.bSicht === x[0]) + '">' + x[1] + "</button>"; }).join("") + "</div>" : "") + "</div>" +
        beitraege() + ausgeblendet() + "</section>" +
      (Z.sicht === "daniel" ? "" : '<section class="karte panel" data-li-follower>' + followerKarte() + "</section>");
  }

  /* ---------- Einfügen ---------- */
  function formular() {
    if (!Z.beitrag || Z.beitrag === "neu" || !B().some(function (x) { return x.beitrag_id === Z.beitrag; })) {
      // Vorauswahl: zuerst, was nachzutragen ist, sonst der neueste beobachtete Beitrag
      var vor = nachtragen(B())[0] || B().filter(function (x) { return x.beobachtet; })[0] || B()[0];
      Z.beitrag = vor ? vor.beitrag_id : null;
    }
    if (!Z.beitrag) return '<div class="panel-kopf"><h2>Reaktionen einfügen</h2></div><p class="panel-leer">Noch keine Beiträge aus Buffer – der Abruf läuft zweimal täglich.</p>';
    return '<div class="panel-kopf"><h2>Reaktionen einfügen</h2><span class="leise">Liste aus LinkedIn kopieren und hier einfügen</span></div>' +
      '<div class="li-form li-form--eins">' +
        '<label class="feld">Beitrag<select data-li-beitrag>' +
          optionen(B().filter(function (x) { return x.beobachtet; }), "Letzte 30 Tage und schon erfasste") +
          optionen(B().filter(function (x) { return !x.beobachtet; }), "Ältere Beiträge") +
        "</select></label>" +
      "</div>" +
      '<label class="feld">Reaktionsliste<textarea data-li-text rows="6" placeholder="In LinkedIn: auf die Zahl der Reaktionen klicken → „Alle“ → ganz nach unten scrollen → Cmd+A, Cmd+C → hier Cmd+V">' + esc(Z.text) + "</textarea></label>" +
      '<div data-li-vorschau>' + vorschau() + "</div>";
  }

  function optionen(l, gruppe) {
    if (!l.length) return "";
    return '<optgroup label="' + esc(gruppe) + '">' + l.map(function (b) {
      return '<option value="' + b.beitrag_id + '"' + (Z.beitrag === b.beitrag_id ? " selected" : "") + ">" +
        esc((b.veroeffentlicht ? tag(b.veroeffentlicht) + " · " : "") + KANAL[b.kanal] + " · " + b.titel +
            (b.laut_buffer != null ? " (" + b.laut_buffer + " Reaktionen)" : "")) + "</option>";
    }).join("") + "</optgroup>";
  }
  function gewaehlt() { var id = Z.beitrag; return (Z.daten ? Z.daten.beitraege : []).filter(function (b) { return b.beitrag_id === id; })[0]; }

  function vorschau() {
    var e = Z.erkannt, bekannt = {};
    (Z.daten ? Z.daten.personen : []).forEach(function (p) { bekannt[p.name.toLowerCase()] = p; });
    var neu = e.filter(function (p) { return !bekannt[p.name.toLowerCase()]; }).length;
    var fehlt = false;
    var info = !Z.text.trim() ? (Z.meldung ? "" : '<span class="leise">Noch nichts eingefügt.</span>')
      : !e.length ? '<span class="li-warnung">Keine Personen erkannt – bitte die Reaktionsliste kopieren (Fenster „Reaktionen“, nicht den Beitrag).</span>'
      : "<b>" + e.length + " Personen erkannt</b>" + (Z.weitere ? " + " + Z.weitere + (Z.weitere === 1 ? " Seite" : " Seiten") : "") +
        " · " + neu + " neu · " + (e.length - neu) + " schon bekannt" + abgleich(e.length + Z.weitere);
    return '<div class="li-vorschau">' +
      '<div class="li-info">' + info + (Z.meldung ? ' <span class="li-ok">' + esc(Z.meldung) + "</span>" : "") + "</div>" +
      '<button type="button" class="knopf knopf--primaer" data-li-speichern' + (!e.length || fehlt ? " disabled" : "") + ">" + (fehlt && e.length ? "Titel fehlt" : "Speichern") + "</button></div>" +
      (e.length ? '<ul class="li-chips">' + e.slice(0, 60).map(function (p) {
        var b = bekannt[p.name.toLowerCase()];
        return '<li class="pille' + (b && b.kontakt ? " pille--gut" : "") + '" title="' + esc(ARTNAME[p.art] + (p.position ? " · " + p.position : "")) + '">' + esc(p.name) + (b ? "" : " ·&nbsp;neu") + "</li>";
      }).join("") + (e.length > 60 ? '<li class="pille">+ ' + (e.length - 60) + " weitere</li>" : "") + "</ul>" : "");
  }
  function abgleich(inListe) {
    var b = gewaehlt();
    if (!b || b.laut_buffer == null) return "";
    if (inListe >= b.laut_buffer) return ' · <span class="li-ok">vollständig (' + b.laut_buffer + " laut Buffer)</span>";
    return ' · <span class="li-warnung">Buffer meldet ' + b.laut_buffer + " – ganz nach unten gescrollt? Neue Reaktionen seit dem letzten Buffer-Stand zählen erst morgen.</span>";
  }
  function vorschauNeu() { var v = wurzel.querySelector("[data-li-vorschau]"); if (v) v.innerHTML = vorschau(); }

  function speichern(knopf) {
    knopf.disabled = true; knopf.textContent = "Speichert …";
    var daten = { personen: Z.erkannt, weitere: Z.weitere };
    daten.beitrag_id = Z.beitrag;
    api("linkedin_erfassen", daten).then(function (r) {
      Z.meldung = r.neu_reaktionen + " neue Reaktionen gespeichert" + (r.gesamt > r.neu_reaktionen ? ", " + (r.gesamt - r.neu_reaktionen) + " waren schon erfasst" : "") +
        (r.neu_personen ? " · " + r.neu_personen + " neue Personen" : "");
      Z.beitrag = r.beitrag_id; Z.text = ""; Z.erkannt = []; Z.weitere = 0; Z.titel = ""; Z.datum = ""; Z.url = "";
      return laden();
    }).catch(function (err) { knopf.disabled = false; knopf.textContent = "Fehler: " + err.message; });
  }

  /* ---------- Personen ---------- */
  function personen() {
    var l = P().filter(function (p) {
      if (Z.filter === "ignoriert") return p.ignoriert;
      if (p.ignoriert) return false;
      if (Z.filter === "mehrfach") return p.reaktionen > 1;
      if (Z.filter === "offen") return !p.kontakt;
      return true;
    });
    if (!l.length) return '<p class="panel-leer">' + (Z.filter === "mehrfach" ? "Noch niemand hat auf mehr als einen erfassten Beitrag reagiert." : "Keine Personen in dieser Ansicht.") + "</p>";
    return '<div class="tabelle-scroll"><table class="tabelle li-personen"><thead><tr><th>Person</th><th class="n">Reaktionen</th><th>Zuletzt</th><th>Kontakt</th></tr></thead><tbody>' +
      l.map(function (p) {
        var aufteilung = Z.sicht !== "alle" ? "" : [p.firmenseite ? "Firmenseite " + p.firmenseite : "", p.daniel ? "Daniel " + p.daniel : ""].filter(Boolean).join(" · ");
        return "<tr><td><b>" + esc(p.name) + "</b>" + (p.position ? '<small class="li-position">' + esc(p.position) + "</small>" : "") + "</td>" +
          '<td class="n"><b>' + zahl(p.reaktionen) + '</b><small class="leise">' + esc(aufteilung) + "</small></td>" +
          "<td>" + tag(p.letzte) + "</td>" +
          '<td class="li-kontakt" data-li-zelle="' + p.person_id + '">' + kontaktZelle(p) + "</td></tr>";
      }).join("") + "</tbody></table></div>";
  }

  function kontaktZelle(p) {
    if (p.ignoriert) return '<button type="button" class="knopf" data-li-was="zurueckholen" data-person="' + p.person_id + '">Zurückholen</button>';
    if (p.kontakt) {
      return '<a href="#kontakte/' + p.kontakt.contact_id + '">' + esc(p.kontakt.name || p.kontakt.email || "Kontakt") + "</a>" +
        (p.kontakt.stufe ? ' <span class="pille pille--' + esc(p.kontakt.stufe) + '">' + esc(p.kontakt.stufe.toUpperCase()) + "</span>" : "") +
        ' <button type="button" class="li-link" data-li-was="loesen" data-person="' + p.person_id + '">lösen</button>';
    }
    if (Z.suche === p.person_id) {
      return '<input type="search" class="suche" data-li-suche="' + p.person_id + '" placeholder="Kontakt suchen: Name oder E-Mail" autocomplete="off">' +
        '<ul class="treffer" data-li-treffer></ul><button type="button" class="li-link" data-li-abbrechen>abbrechen</button>';
    }
    return (p.vorschlag
        ? '<div class="li-vorschlag">Vorschlag: <b>' + esc(p.vorschlag.name) + "</b>" + (p.vorschlag.email ? ' <span class="leise">' + esc(p.vorschlag.email) + "</span>" : "") +
          ' <button type="button" class="knopf knopf--primaer" data-li-was="zuordnen" data-person="' + p.person_id + '" data-kontakt="' + p.vorschlag.contact_id + '">Zuordnen</button></div>'
        : "") +
      '<div class="knoepfe">' +
        '<button type="button" class="knopf" data-li-was="kontakt_anlegen" data-person="' + p.person_id + '">Kontakt anlegen</button>' +
        '<button type="button" class="knopf" data-li-suchen="' + p.person_id + '">Zuordnen …</button>' +
        '<button type="button" class="knopf" data-li-was="ignorieren" data-person="' + p.person_id + '">Ignorieren</button>' +
      "</div>";
  }

  /* ---------- Beiträge ---------- */
  function beitraege() {
    var alle = B().filter(function (x) { return Z.sicht !== "alle" || Z.bSicht === "alle" || x.kanal === Z.bSicht; });
    var l = Z.alleBeitraege ? alle : alle.filter(function (x) { return x.beobachtet; });
    var mehr = alle.length - alle.filter(function (x) { return x.beobachtet; }).length;
    var umschalten = mehr ? '<p class="li-mehr"><button type="button" class="li-link" data-li-alle>' +
      (Z.alleBeitraege ? "nur letzte 30 Tage und erfasste zeigen" : "alle " + alle.length + " Beiträge zeigen (" + mehr + " ältere)") + "</button></p>" : "";
    if (!l.length) return '<p class="panel-leer">Keine Beiträge in dieser Ansicht.</p>' + umschalten;
    return '<ul class="li-beitraege">' + l.map(function (x) {
        var erfasst = x.erfasst + x.weitere, soll = x.laut_buffer || 0, anteil = soll ? Math.min(100, Math.round(erfasst / soll * 100)) : 0;
        return '<li class="li-b">' +
          '<div class="li-b-text"><span class="li-b-meta"><span class="li-kanal li-kanal--' + x.kanal + '">' + KANAL[x.kanal] + "</span>" + tag(x.veroeffentlicht) + "</span>" +
            (x.url ? '<a class="li-b-titel" href="' + esc(x.url) + '" target="_blank" rel="noopener">' + esc(x.titel) + "</a>" : '<span class="li-b-titel">' + esc(x.titel) + "</span>") + "</div>" +
          '<dl class="li-b-zahlen"><div><dt>Impressionen</dt><dd>' + zahl(x.impressionen) + "</dd></div><div><dt>Reaktionen</dt><dd>" + zahl(x.laut_buffer) + "</dd></div>" +
            "<div><dt>Kommentare</dt><dd>" + zahl(x.kommentare_laut_buffer) + "</dd></div>" +
            '<div class="li-b-erfasst"><dt>erfasst</dt><dd>' + zahl(erfasst) + (soll ? '<span class="leise"> / ' + zahl(soll) + "</span>" : "") +
              (soll ? '<span class="li-balken" aria-hidden="true"><i style="width:' + anteil + '%"></i></span>' : "") + "</dd></div></dl>" +
          '<div class="li-b-aktionen">' + (x.beobachtet && x.fehlen > 0 ? '<span class="pille pille--verloren">' + x.fehlen + (x.fehlen === 1 ? " fehlt" : " fehlen") + "</span>" : "") +
            '<button type="button" class="knopf knopf--klein" data-li-nachtragen="' + x.beitrag_id + '">' + (x.erfasst ? "Nachtragen" : "Einfügen") + "</button>" +
            (x.kanal === "daniel" ? '<button type="button" class="li-link" data-li-zuordnen="' + x.beitrag_id + '" data-z="empiria" title="gehört zu empiria – ausblenden">ausblenden</button>' : "") +
          "</div></li>";
      }).join("") + "</ul>" + umschalten;
  }

  /* ---------- Ausgeblendete Beiträge (empiria / ohne Kennzeichen) ---------- */
  function ausgeblendet() {
    var a = Z.daten.ausgeblendet;
    if (!a || !(a.unklar || a.empiria) || Z.sicht === "firmenseite") return "";
    var kopf = '<p class="li-mehr li-ausgeblendet">' + zahl(a.unklar) + " Beiträge von Daniel ohne Kennzeichen" +
      (a.empiria ? " und " + zahl(a.empiria) + " mit #empiria" : "") + " sind ausgeblendet und zählen nicht als Signal." +
      (a.unklar ? ' <button type="button" class="li-link" data-li-ausgeblendet>' + (Z.ausgeblendetOffen ? "zuklappen" : "ohne Kennzeichen zeigen und zuordnen") + "</button>" : "") + "</p>";
    if (!Z.ausgeblendetOffen || !a.unklar) return kopf;
    return kopf + '<div class="tabelle-scroll"><table class="tabelle li-unklar"><thead><tr><th>Veröffentlicht</th><th>Beitrag</th><th class="n">Reaktionen</th><th></th></tr></thead><tbody>' +
      a.beitraege.map(function (b) {
        return "<tr><td>" + tag(b.veroeffentlicht) + "</td><td>" + (b.url ? '<a href="' + esc(b.url) + '" target="_blank" rel="noopener">' + esc(b.titel) + "</a>" : esc(b.titel)) + "</td>" +
          '<td class="n">' + zahl(b.laut_buffer) + "</td>" +
          '<td class="li-aktionen"><button type="button" class="knopf knopf--primaer" data-li-zuordnen="' + b.beitrag_id + '" data-z="sofortsichtbar">sofort sichtbar</button> ' +
          '<button type="button" class="knopf" data-li-zuordnen="' + b.beitrag_id + '" data-z="empiria">empiria</button></td></tr>';
      }).join("") + "</tbody></table></div>";
  }

  /* ---------- Follower ---------- */
  function followerKarte() {
    var e = Z.fErkannt;
    var info = !Z.fText.trim() ? '<span class="leise">' + (Z.fMeldung ? "" : "Noch nichts eingefügt.") + "</span>"
      : e.fehlt ? '<span class="li-warnung">Nicht erkannt – es fehlt: ' + esc(e.fehlt) + ". Bitte die Tabelle mit Kopfzeile kopieren.</span>"
      : "<b>" + e.follower.length + " Follower erkannt</b>" + " · " + e.mitLink + " mit LinkedIn-Link" +
        " · Spalten: " + ["name", "unternehmen", "position", "seit", "link"].filter(function (k) { return e.spalten[k] >= 0; }).map(function (k) {
          return { name: "Name", unternehmen: "Unternehmen", position: "Position", seit: "Folgt seit", link: "Link" }[k]; }).join(", ");
    return '<details class="li-follower"' + (Z.fText || Z.fMeldung ? " open" : "") + '><summary><b>Follower der Firmenseite</b> <span class="leise">manueller Import – automatisch geht das noch nicht</span></summary>' +
      '<p class="leise nl-klein">Neue Follower werden Kontakte mit Herkunft und Tag „LinkedIn-Follower“ (Newsletter: Nein). Bekannte Personen werden ergänzt, nicht doppelt angelegt.</p>' +
      '<label class="feld">Follower-Liste <small>in Excel die Tabelle samt Kopfzeile markieren, Cmd+C, hier Cmd+V. Bekannte Personen werden ergänzt, nicht doppelt angelegt.</small>' +
        '<textarea data-li-ftext rows="4" placeholder="Name → Unternehmen → Position → Folgt seit → Link">' + esc(Z.fText) + "</textarea></label>" +
      '<div class="li-vorschau"><div class="li-info">' + info + (Z.fMeldung ? ' <span class="li-ok">' + esc(Z.fMeldung) + "</span>" : "") + "</div>" +
        '<button type="button" class="knopf knopf--primaer" data-li-fspeichern' + (e && e.follower.length ? "" : " disabled") + ">Follower übernehmen</button></div></details>";
  }
  function followerNeu() { var k = wurzel.querySelector("[data-li-follower]"); if (k) k.innerHTML = followerKarte(); }

  /* ---------- Bedienung ---------- */
  var suchTimer;
  wurzel.addEventListener("input", function (e) {
    if (!aktiv) return;
    var t = e.target;
    if (t.hasAttribute("data-li-ftext")) {
      Z.fText = t.value; Z.fErkannt = erkenneFollower(t.value); Z.fMeldung = "";
      var k = wurzel.querySelector("[data-li-follower] .li-vorschau");
      if (k) { var tmp = document.createElement("div"); tmp.innerHTML = followerKarte(); k.replaceWith(tmp.querySelector(".li-vorschau")); }
      return;
    }
    if (t.hasAttribute("data-li-text")) { Z.text = t.value; Z.erkannt = erkenne(t.value); Z.weitere = weitere(t.value); Z.meldung = ""; vorschauNeu(); }
    else if (t.hasAttribute("data-li-feld")) { Z[t.getAttribute("data-li-feld")] = t.value; if (t.getAttribute("data-li-feld") === "titel") vorschauNeu(); }
    else if (t.hasAttribute("data-li-suche")) {
      clearTimeout(suchTimer);
      var person = t.getAttribute("data-li-suche"), wert = t.value.trim();
      suchTimer = setTimeout(function () {
        api("kontakte", { suche: wert }).then(function (r) {
          var ul = wurzel.querySelector("[data-li-treffer]"); if (!ul) return;
          ul.innerHTML = r.map(function (k) {
            var n = [k.vorname, k.nachname].filter(Boolean).join(" ");
            return '<li><button type="button" data-li-was="zuordnen" data-person="' + person + '" data-kontakt="' + k.contact_id + '"><b>' + esc(n || k.email) + "</b><small>" + esc(n ? k.email || "" : "") + "</small></button></li>";
          }).join("") || '<li class="leise">Kein Treffer – dann „Kontakt anlegen“.</li>';
        }).catch(function () {});
      }, 250);
    }
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv || !e.target.hasAttribute("data-li-beitrag")) return;
    Z.beitrag = e.target.value; Z.meldung = "";
    var f = wurzel.querySelector("[data-li-form]"); if (f) f.innerHTML = formular();
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t;
    if ((t = e.target.closest("[data-li-sicht]"))) {
      Z.sicht = t.getAttribute("data-li-sicht"); Z.suche = null; Z.meldung = "";
      try { localStorage.setItem("cockpit.linkedin.sicht", Z.sicht); } catch (err) { /* ohne Speicher */ }
      if (Z.sicht !== "alle") Z.kanal = Z.sicht;
      if (Z.beitrag && Z.beitrag !== "neu" && !B().some(function (b) { return b.beitrag_id === Z.beitrag; })) Z.beitrag = null;
      return zeichnen();
    }
    if ((t = e.target.closest("[data-li-filter]"))) { Z.filter = t.getAttribute("data-li-filter"); Z.suche = null; return zeichnen(); }
    if ((t = e.target.closest("[data-li-kanal]"))) {
      Z.kanal = t.getAttribute("data-li-kanal");
      wurzel.querySelectorAll("[data-li-kanal]").forEach(function (b) { b.setAttribute("aria-pressed", String(b === t)); });
      return;
    }
    if ((t = e.target.closest("[data-li-speichern]"))) return speichern(t);
    if ((t = e.target.closest("[data-li-fspeichern]"))) {
      t.disabled = true; t.textContent = "Wird übernommen …";
      var knopf = t;
      return api("linkedin_follower", { follower: Z.fErkannt.follower }).then(function (r) {
        Z.fMeldung = r.gesamt + " Follower übernommen: " + r.neue_kontakte + " neue Kontakte, " + r.verknuepft + " mit bestehenden Kontakten verbunden" +
          (r.mit_link ? ", " + r.mit_link + " Links" : "") + (r.team ? ", " + r.team + " vom Team übersprungen" : "");
        Z.fText = ""; Z.fErkannt = null;
        return laden();
      }).catch(function (err) { knopf.disabled = false; knopf.textContent = "Fehler: " + err.message; });
    }
    if (e.target.closest("[data-li-alle]")) { Z.alleBeitraege = !Z.alleBeitraege; return zeichnen(); }
    if ((t = e.target.closest("[data-li-bsicht]"))) { Z.bSicht = t.getAttribute("data-li-bsicht"); return zeichnen(); }
    if (e.target.closest("[data-li-ausgeblendet]")) { Z.ausgeblendetOffen = !Z.ausgeblendetOffen; return zeichnen(); }
    if ((t = e.target.closest("[data-li-zuordnen]"))) {
      t.disabled = true;
      var bid = t.getAttribute("data-li-zuordnen");
      if (Z.beitrag === bid) Z.beitrag = null;
      return api("linkedin_zuordnen", { beitrag_id: bid, zugehoerigkeit: t.getAttribute("data-z") }).then(laden)
        .catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
    if ((t = e.target.closest("[data-li-nachtragen]"))) {
      Z.beitrag = t.getAttribute("data-li-nachtragen"); Z.meldung = "";
      var f = wurzel.querySelector("[data-li-form]"); if (f) { f.innerHTML = formular(); f.scrollIntoView({ behavior: "smooth", block: "start" }); var ta = f.querySelector("textarea"); if (ta) ta.focus(); }
      return;
    }
    if ((t = e.target.closest("[data-li-loeschen]"))) {
      if (!confirm("Beitrag „" + t.getAttribute("data-titel") + "“ mit allen erfassten Reaktionen löschen?")) return;
      var id = t.getAttribute("data-li-loeschen");
      if (Z.beitrag === id) Z.beitrag = null;
      return api("linkedin_beitrag_loeschen", { beitrag_id: id }).then(laden).catch(function (err) { alert("Fehler: " + err.message); });
    }
    if ((t = e.target.closest("[data-li-suchen]"))) {
      Z.suche = t.getAttribute("data-li-suchen");
      var zelle = wurzel.querySelector('[data-li-zelle="' + Z.suche + '"]');
      var p = Z.daten.personen.filter(function (x) { return x.person_id === Z.suche; })[0];
      if (zelle && p) { zelle.innerHTML = kontaktZelle(p); var s = zelle.querySelector("input"); s.value = p.name.replace(/,.*$/, ""); s.focus(); s.dispatchEvent(new Event("input", { bubbles: true })); }
      return;
    }
    if (e.target.closest("[data-li-abbrechen]")) { Z.suche = null; return zeichnen(); }
    if ((t = e.target.closest("[data-li-was]"))) {
      t.disabled = true;
      return api("linkedin_person", { person_id: t.getAttribute("data-person"), was: t.getAttribute("data-li-was"), contact_id: t.getAttribute("data-kontakt") })
        .then(function () { Z.suche = null; return laden(); })
        .catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
  });

  C.module.linkedin = { start: start, stop: stop, erkenne: erkenne };
})();
