/* Cockpit · Kontakte – Liste, Detail mit Timeline, Bearbeiten.
   Die Timeline bündelt Website-Ereignisse zu Besuchen (eine Sitzung = ein
   Eintrag) und zeigt Termine und Calls dazwischen. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { liste: [], listen: [], suche: "", filter: "", detail: null, offen: {}, auswahl: {}, menue: null, panel: null, meldung: "", neu: [], neuOffen: false,
            ansicht: "kontakte", f: {}, fMenue: false, fSeite: null, facetten: null, firmen: [], firmaName: "" };
  try { var gemerkt = JSON.parse(localStorage.getItem("cockpit.kontakte.filter") || "null"); if (gemerkt) { Z.f = gemerkt.f || {}; Z.ansicht = gemerkt.ansicht || "kontakte"; Z.firmaName = gemerkt.firmaName || ""; } } catch (e) {}
  function merken() { try { localStorage.setItem("cockpit.kontakte.filter", JSON.stringify({ f: Z.f, ansicht: Z.ansicht, firmaName: Z.firmaName })); } catch (e) {} }

  /* ---------- Filter-Baukasten ---------- */
  var FDEF = [
    { k: "name", label: "Name", typ: "text", ph: "Name enthält …", extra: ["name_unvollstaendig", "nur unvollständige Namen"] },
    { k: "firma", label: "Firma", typ: "text", ph: "Firma enthält …" },
    { k: "position", label: "Position", typ: "text", ph: "Position enthält …", extra: ["position_leer", "nur ohne Position"] },
    { k: "herkunft", label: "Herkunft", typ: "multi", facette: "herkunft", optionen: [["linkedin", "LinkedIn"], ["instagram", "Instagram"], ["facebook", "Facebook"], ["website", "Website"],
        ["termin", "Terminbuchung"], ["postfach", "Postfach"], ["call", "Call"], ["manuell", "Manuell"], ["import", "Import"]] },
    { k: "follower", label: "Follower", typ: "multi", facette: "follower", optionen: [["linkedin", "LinkedIn"], ["instagram", "Instagram"], ["facebook", "Facebook"]] },
    { k: "newsletter", label: "Newsletter", typ: "eins", facette: "newsletter", optionen: [["ja", "berechtigt"], ["nein", "nicht berechtigt"]] },
    { k: "signale", label: "Signale", typ: "multi", optionen: [["website", "Website besucht"], ["preise", "Preise angesehen"], ["termin", "Termin"], ["call", "Call"],
        ["mail_ein", "Mail erhalten"], ["mail_aus", "Mail gesendet"], ["nl_offen", "Newsletter geöffnet"], ["nl_klick", "Newsletter geklickt"],
        ["li_reaktion", "LinkedIn-Reaktion"], ["li_kommentar", "LinkedIn-Kommentar"], ["ig_like", "Instagram-Like"], ["ig_kommentar", "Instagram-Kommentar"]] },
    { k: "liste", label: "Liste", typ: "liste" }
  ];
  function fdef(k) { return FDEF.filter(function (d) { return d.k === k; })[0]; }
  function filterAktiv() { return Object.keys(Z.f).some(function (k) { var v = Z.f[k]; return Array.isArray(v) ? v.length : !!v; }); }
  function optLabel(d, v) { var o = (d.optionen || []).filter(function (x) { return x[0] === v; })[0]; return o ? o[1] : v; }
  function chipsHtml() {
    var c = [];
    FDEF.forEach(function (d) {
      var v = Z.f[d.k], t = "";
      if (d.typ === "text" && v) t = d.label + " enthält „" + v + "“";
      if (d.typ === "multi" && v && v.length) t = d.label + ": " + v.map(function (x) { return optLabel(d, x); }).join(", ") +
        (d.k === "signale" && Z.f.signal_tage ? " · letzte " + Z.f.signal_tage + " Tage" : "");
      if (d.typ === "eins" && v) t = d.label + ": " + optLabel(d, v);
      if (t) c.push('<span class="k-chip"><button type="button" class="k-chip-text" data-k-chip="' + d.k + '">' + esc(t) + '</button><button type="button" class="k-chip-weg" data-k-chip-weg="' + d.k + '" aria-label="Filter entfernen">×</button></span>');
      if (d.extra && Z.f[d.extra[0]]) c.push('<span class="k-chip"><button type="button" class="k-chip-text" data-k-chip="' + d.k + '">' + esc(d.extra[1]) + '</button><button type="button" class="k-chip-weg" data-k-chip-weg="' + d.extra[0] + '" aria-label="Filter entfernen">×</button></span>');
    });
    if (Z.f.firma_id) c.push('<span class="k-chip"><span class="k-chip-text">Firma: ' + esc(Z.firmaName || "ausgewählt") + '</span><button type="button" class="k-chip-weg" data-k-chip-weg="firma_id" aria-label="Filter entfernen">×</button></span>');
    if (c.length > 1) c.push('<button type="button" class="li-link" data-k-filter-leeren>alle Filter entfernen</button>');
    return c.join("");
  }
  function fMenueHtml() {
    if (!Z.fMenue) return "";
    return '<div class="k-fmenue" role="menu">' + FDEF.map(function (d) {
        var an = d.typ === "text" ? !!Z.f[d.k] || (d.extra && Z.f[d.extra[0]]) : d.typ === "multi" ? (Z.f[d.k] || []).length : d.typ === "eins" ? !!Z.f[d.k] : false;
        return '<button type="button" role="menuitem" data-k-fseite="' + d.k + '" aria-expanded="' + (Z.fSeite === d.k) + '">' + esc(d.label) + (an ? ' <i class="k-fpunkt"></i>' : "") + "</button>";
      }).join("") + "</div>" + (Z.fSeite ? '<div class="k-fseite">' + fSeiteHtml(fdef(Z.fSeite)) + "</div>" : "");
  }
  function fSeiteHtml(d) {
    var fa = (Z.facetten && d.facette && Z.facetten[d.facette]) || {};
    var kopf = '<p class="k-fseite-kopf">' + esc(d.label) + "</p>";
    if (d.typ === "text") return kopf + '<input type="search" class="suche" data-k-ftext="' + d.k + '" placeholder="' + esc(d.ph) + '" value="' + esc(Z.f[d.k] || "") + '" autocomplete="off">' +
      (d.extra ? '<label class="k-fopt"><input type="checkbox" data-k-fextra="' + d.extra[0] + '"' + (Z.f[d.extra[0]] ? " checked" : "") + "> " + esc(d.extra[1]) + "</label>" : "");
    if (d.typ === "multi") return kopf + d.optionen.map(function (o) {
        return '<label class="k-fopt"><input type="checkbox" data-k-fmulti="' + d.k + '" value="' + o[0] + '"' + ((Z.f[d.k] || []).indexOf(o[0]) >= 0 ? " checked" : "") + "> " + esc(o[1]) +
          (fa[o[0]] != null ? '<small class="leise">' + fa[o[0]] + "</small>" : "") + "</label>";
      }).join("") +
      (d.k === "signale" ? '<label class="feld k-fzeit">Zeitraum<select data-k-fzeit>' + [["", "jemals"], ["7", "letzte 7 Tage"], ["30", "letzte 30 Tage"], ["90", "letzte 90 Tage"], ["365", "letztes Jahr"]].map(function (o) {
          return '<option value="' + o[0] + '"' + (String(Z.f.signal_tage || "") === o[0] ? " selected" : "") + ">" + o[1] + "</option>"; }).join("") + "</select></label>" +
        '<p class="leise nl-mini">Signal-Score: kommt, sobald die Gewichtung der Signale steht.</p>' : "");
    if (d.typ === "eins") return kopf + d.optionen.map(function (o) {
        return '<label class="k-fopt"><input type="radio" name="k-feins-' + d.k + '" data-k-feins="' + d.k + '" value="' + o[0] + '"' + (Z.f[d.k] === o[0] ? " checked" : "") + "> " + esc(o[1]) +
          (fa[o[0]] != null ? '<small class="leise">' + fa[o[0]] + "</small>" : "") + "</label>";
      }).join("") + (Z.f[d.k] ? '<button type="button" class="li-link" data-k-chip-weg="' + d.k + '">egal</button>' : "");
    if (d.typ === "liste") return kopf + (Z.listen.length ? Z.listen.map(function (l) {
        return '<a class="k-fopt k-fliste" href="#kontakte/liste:' + encodeURIComponent(l.liste) + '">' + esc(l.liste.replace(/_/g, " ")) + '<small class="leise">' + l.kontakte + "</small></a>";
      }).join("") : '<p class="leise">Noch keine Listen.</p>');
    return "";
  }
  function ergebnisNeu() {
    var e = wurzel.querySelector("[data-k-ergebnis]"); if (e) e.innerHTML = ergebnisHtml();
    var c = wurzel.querySelector("[data-k-chips]"); if (c) c.innerHTML = chipsHtml();
    var m = wurzel.querySelector("[data-k-fmenue-ort]");
    if (m) wurzel.querySelectorAll(".k-fmenue [data-k-fseite]").forEach(function (b) {
      var d = fdef(b.getAttribute("data-k-fseite")), an = d.typ === "text" ? !!Z.f[d.k] || (d.extra && Z.f[d.extra[0]]) : d.typ === "multi" ? (Z.f[d.k] || []).length : d.typ === "eins" ? !!Z.f[d.k] : false;
      b.innerHTML = esc(d.label) + (an ? ' <i class="k-fpunkt"></i>' : "");
    });
  }
  function fMenueNeu() { var m = wurzel.querySelector("[data-k-fmenue-ort]"); if (m) m.innerHTML = fMenueHtml(); var b = wurzel.querySelector("[data-k-fknopf]"); if (b) b.setAttribute("aria-expanded", String(!!Z.fMenue)); }
  var filterTimer = null;
  function filterGeaendert(sofort) {
    merken(); clearTimeout(filterTimer);
    filterTimer = setTimeout(function () { listeLaden(true); }, sofort ? 0 : 250);
  }
  function firmenHtml() {
    if (!Z.firmen.length) return '<div class="karte leer">' + (filterAktiv() || Z.suche ? "Keine Firma passt zu den Filtern." : "Noch keine Firmen.") + "</div>";
    return '<p class="zahlzeile">' + zahlText(Z.firmen.length, "Firma", "Firmen") + "</p>" +
      '<div class="karte tabelle-rahmen"><table class="tabelle tabelle--klick k-firmen"><thead><tr><th>Firma</th><th class="n">Kontakte</th><th>Follower</th><th>Herkunft</th><th>Letzte Aktivität</th></tr></thead><tbody>' +
      Z.firmen.map(function (f) {
        return '<tr data-k-firma="' + f.company_id + '" data-name="' + esc(f.name) + '" tabindex="0"><td><b>' + esc(f.name) + "</b>" + (f.domain ? '<small class="k-unter">' + esc(f.domain) + "</small>" : "") + "</td>" +
          '<td class="n">' + (filterAktiv() && f.treffer !== f.kontakte ? f.treffer + ' <small class="leise">von ' + f.kontakte + "</small>" : f.kontakte) + "</td>" +
          "<td>" + (f.follower || []).map(function (x) { return '<span class="pille">' + esc({ linkedin: "LinkedIn", instagram: "Instagram", facebook: "Facebook" }[x] || x) + "</span>"; }).join(" ") + "</td>" +
          "<td>" + esc((f.herkunft || []).map(function (h) { return HERKUNFT[h] || h; }).join(", ")) + "</td><td>" + relativ(f.letzte_aktivitaet) + "</td></tr>";
      }).join("") + "</tbody></table></div>";
  }
  var aktiv = false;

  var STATUS = { lead: "Lead", mql: "MQL", sql: "SQL", kunde: "Kunde", verloren: "Verloren" };
  var PAKET = { "": "–", fokus: "Fokus", team: "Team", komplett: "Komplett" };
  var HERKUNFT = { "": "–", termin: "Terminbuchung", postfach: "Postfach", call: "Call", website: "Website",
                   linkedin_follower: "LinkedIn-Follower", linkedin_reaktion: "LinkedIn-Reaktion", manuell: "Manuell", import: "Import" };
  var GRUNDLAGE = { "": "– bitte wählen –", einwilligung: "Einwilligung (z. B. Formular, DOI)", bestandskunde: "Bestandskunde" };
  var FILTER = [["", "Alle Kontakte"], ["newsletter", "Newsletter erlaubt"], ["ohne_position", "Position fehlt"], ["name_unvollstaendig", "Name unvollständig"],
                ["herkunft:linkedin_follower", "Herkunft: LinkedIn-Follower"], ["herkunft:linkedin_reaktion", "Herkunft: LinkedIn-Reaktion"],
                ["herkunft:termin", "Herkunft: Terminbuchung"], ["herkunft:postfach", "Herkunft: Postfach"], ["herkunft:call", "Herkunft: Call"],
                ["herkunft:website", "Herkunft: Website"]];
  var SEITENTYP = { home: "Startseite", preis: "Preise", kontakt: "Kontakt", zielgruppe: "Zielgruppen", produkt: "Produkt",
                    rechtliches: "Rechtliches", karriere: "Karriere", blog: "Blog", referenz: "Referenzen", sonstige: "Sonstige" };

  var I = {
    sprech: '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/>',
    auge: '<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="1.8"/>',
    web: '<path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM1.5 8h13M8 1.5c1.8 1.8 2.6 4 2.6 6.5S9.8 12.7 8 14.5M8 1.5C6.2 3.3 5.4 5.5 5.4 8s.8 4.7 2.6 6.5"/>',
    termin: '<rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>',
    absage: '<rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3M6.3 8.8l3.4 3.4M9.7 8.8l-3.4 3.4"/>',
    mailEin: '<rect x="1.5" y="3" width="13" height="10" rx="1.5"/><path d="M2 4l6 4.5L14 4"/>',
    mailAus: '<path d="M14.5 1.5L7 9M14.5 1.5L10 14.5 7 9 1.5 6z"/>',
    call: '<path d="M3 2h2.6l1.2 3-1.6 1a8 8 0 0 0 3.8 3.8l1-1.6 3 1.2V12a2 2 0 0 1-2 2A11 11 0 0 1 1 4a2 2 0 0 1 2-2z"/>',
    daumen: '<path d="M5 7v7H2.5V7zM5 7l2.6-5a1.6 1.6 0 0 1 2.2 1.6L9.3 6.5h3.4a1.5 1.5 0 0 1 1.5 1.8l-1 4.6a1.5 1.5 0 0 1-1.5 1.1H5"/>',
    folgen: '<circle cx="6" cy="5" r="2.8"/><path d="M1.5 14c.6-2.6 2.3-4 4.5-4s3.9 1.4 4.5 4M12.5 5v4M10.5 7h4"/>',
    news: '<path d="M2 4h12v8.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 12.5zM2 4.5l6 4 6-4M5 1.5h6"/>',
    klick: '<path d="M6.5 6.5l7 2.6-3 1.1-1.1 3zM6.5 1.5v2M2.9 3l1.4 1.4M1.5 6.5h2"/>',
    weg: '<circle cx="8" cy="8" r="6.5"/><path d="M5 8h6"/>',
    warn: '<path d="M8 1.8l6.5 11.7H1.5zM8 6.5v3M8 11.6v.1"/>',
    preis: '<path d="M8.6 1.5H14v5.4L7.4 13.5a1.4 1.4 0 0 1-2 0L1.9 10a1.4 1.4 0 0 1 0-2zM11 4.5v.1"/>',
    plus: '<path d="M8 3v10M3 8h10"/>', kreuz: '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>'
  };
  function icon(n) { return '<svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">' + I[n] + "</svg>"; }
  function tagName(t) { return String(t).replace(/_/g, " "); }

  function name(k) { return [k.titel, k.vorname, k.nachname].filter(Boolean).join(" ") || k.email || "Ohne Namen"; }
  function zeit(d) { return new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }); }
  function datum(d) { return new Date(d).toLocaleDateString("de-DE", { day: "numeric", month: "short", year: "numeric" }); }
  function relativ(d) {
    if (!d) return '<span class="leise">–</span>';
    var t = Math.floor((Date.now() - new Date(d)) / 864e5);
    return t < 1 ? "heute" : t < 2 ? "gestern" : t < 30 ? "vor " + t + " Tagen" : datum(d);
  }
  function pille(stage) { return '<span class="pille pille--' + esc(stage) + '">' + esc(STATUS[stage] || stage) + "</span>"; }
  function dauer(s) { return s < 60 ? Math.round(s) + " s" : Math.round(s / 60) + " min"; }

  function start(id) {
    aktiv = true; Z.menue = null; Z.panel = null; Z.auswahl = {}; Z.meldung = ""; Z.fMenue = false; Z.fSeite = null;
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    // #kontakte/liste:<name> öffnet die Liste
    if (id && id.indexOf("liste:") === 0) { Z.filter = "tag:" + decodeURIComponent(id.slice(6)); Z.suche = ""; id = null; }
    id ? detailLaden(id) : listeLaden();
  }
  function aktuelleListe() { return Z.filter.indexOf("tag:") === 0 ? Z.filter.slice(4) : null; }
  function ausgewaehlt() { return Object.keys(Z.auswahl).filter(function (k) { return Z.auswahl[k]; }); }
  function stop() { aktiv = false; }
  function fehler(e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; }

  /* ---------- Liste ---------- */
  function listeLaden(nurErgebnis) {
    Z.detail = null;
    var liste = aktuelleListe(), firmen = Z.ansicht === "firmen" && !liste;
    var suche = api(firmen ? "firmen_liste" : "kontakte_suche", { suche: Z.suche, filter: Z.f, liste: liste || "" });
    if (nurErgebnis && wurzel.querySelector("[data-k-ergebnis]")) {
      return suche.then(function (r) { if (firmen) Z.firmen = r; else Z.liste = r; if (aktiv) ergebnisNeu(); }).catch(fehler);
    }
    return Promise.all([suche, api("listen", {}), api("postfach", { tage: 90 }).catch(function () { return null; }),
                        api("kontakte_facetten", {}).catch(function () { return null; })]).then(function (x) {
      if (firmen) { Z.firmen = x[0]; Z.liste = []; } else Z.liste = x[0];
      Z.listen = x[1] || []; Z.neu = x[2] && x[2].unbekannt || []; Z.facetten = x[3];
      var da = {}; Z.liste.forEach(function (k) { da[k.contact_id] = true; });
      Object.keys(Z.auswahl).forEach(function (k) { if (!da[k]) delete Z.auswahl[k]; });
      if (Z.facetten) { var z = document.querySelector('[data-zahl="kontakte"]'); if (z) z.textContent = Z.facetten.gesamt || ""; }
      if (aktiv) listeZeichnen();
    }).catch(fehler);
  }

  function listeZeichnen() {
    var fokus = document.activeElement && document.activeElement.hasAttribute("data-k-suche");
    var liste = aktuelleListe(), info = liste && Z.listen.filter(function (l) { return l.liste === liste; })[0];
    var aus = ausgewaehlt(), alle = Z.liste.length && aus.length === Z.liste.length;
    wurzel.innerHTML =
      (liste ? '<p class="zurueck"><a href="#kontakte" data-k-alle>← Alle Kontakte</a></p>' : "") +
      '<div class="kopf"><div><h1>' + (liste ? "Liste „" + esc(liste) + "“" : "Kontakte") + '</h1><p class="leise">' +
        (liste ? zahlText(info ? info.kontakte : Z.liste.length, "Kontakt", "Kontakte") + " · " + zahlText(info ? info.erlaubt : 0, "darf", "dürfen") + " den Newsletter bekommen"
               : "Alle Personen aus Terminbuchungen, Postfach, Calls, LinkedIn und Listen") + "</p></div>" +
        (liste ? '<button type="button" class="knopf knopf--gefahr" data-k-liste-loeschen>Liste auflösen</button>'
               : '<button type="button" class="knopf" data-k-tags-knopf aria-expanded="' + !!Z.tagsVerwalten + '">Tags verwalten</button>') + "</div>" +
      (Z.tagsVerwalten && !liste ? tagsPanel() : "") +
      (!liste ? neuBereich() : "") +
      '<div class="leiste k-leiste">' +
        (!liste ? '<div class="seg" role="group" aria-label="Ansicht"><button type="button" data-k-ansicht="kontakte" aria-pressed="' + (Z.ansicht !== "firmen") + '">Kontakte' +
          (Z.facetten ? " <small>" + Z.facetten.gesamt + "</small>" : "") + '</button><button type="button" data-k-ansicht="firmen" aria-pressed="' + (Z.ansicht === "firmen") + '">Firmen' +
          (Z.facetten ? " <small>" + Z.facetten.firmen + "</small>" : "") + "</button></div>" : "") +
        '<input type="search" class="suche" data-k-suche placeholder="Suchen: Name, E-Mail, Firma oder Position" value="' + esc(Z.suche) + '">' +
        '<div class="k-filterort"><button type="button" class="knopf k-fknopf" data-k-fknopf aria-haspopup="true" aria-expanded="' + !!Z.fMenue + '">+ Filter</button>' +
          '<div data-k-fmenue-ort>' + fMenueHtml() + "</div></div></div>" +
      '<div class="k-chips" data-k-chips>' + chipsHtml() + "</div>" +
      '<div class="k-auswahlleiste"' + (aus.length ? "" : " hidden") + '><b>' + aus.length + " ausgewählt</b>" +
        '<button type="button" class="knopf knopf--primaer" data-k-aktion="liste">Zu Liste hinzufügen</button>' +
        (liste ? '<button type="button" class="knopf" data-k-aktion="entfernen">Aus „' + esc(liste) + '“ entfernen</button>' : "") +
        '<button type="button" class="li-link" data-k-aktion="aufheben">Auswahl aufheben</button></div>' +
      '<div data-k-panel>' + panel() + "</div>" +
      (Z.meldung ? '<p class="k-meldung">' + esc(Z.meldung) + "</p>" : "") +
      '<div data-k-ergebnis>' + ergebnisHtml() + "</div>";
    if (fokus) { var f = wurzel.querySelector("[data-k-suche]"); if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } }
    var pin = wurzel.querySelector("[data-k-panel] input[data-k-neu]"); if (pin && Z.panel && Z.panel.fokus) { pin.focus(); Z.panel.fokus = false; }
  }
  function ergebnisHtml() {
    var liste = aktuelleListe(), aus = ausgewaehlt(), alle = Z.liste.length && aus.length === Z.liste.length;
    if (Z.ansicht === "firmen" && !liste) return firmenHtml();
    return '<p class="zahlzeile">' + zahlText(Z.liste.length, "Kontakt", "Kontakte") + (Z.liste.length >= 1000 ? " (die ersten 1.000 – Suche oder Filter eingrenzen)" : "") + "</p>" +
      (Z.liste.length ? '<div class="karte tabelle-rahmen k-tabelle"><table class="tabelle tabelle--klick k-zeilen">' +
        '<colgroup><col class="k-c-wahl"><col class="k-c-name"><col class="k-c-firma"><col class="k-c-pos"><col class="k-c-status"><col class="k-c-akt"><col class="k-c-menue"></colgroup><thead><tr>' +
        '<th class="k-wahl"><input type="checkbox" data-k-alle-wahl aria-label="Alle auswählen"' + (alle ? " checked" : "") + "></th>" +
        "<th>Name</th><th>Firma</th><th>Position</th><th>Status</th><th>Letzte Aktivität</th><th class=\"k-menue-spalte\"><span class=\"sr\">Aktionen</span></th></tr></thead><tbody>" +
        Z.liste.map(function (k) {
          var id = k.contact_id;
          return '<tr data-kontakt="' + id + '" tabindex="0"' + (Z.auswahl[id] ? ' class="k-gewaehlt"' : "") + ">" +
            '<td class="k-wahl"><input type="checkbox" data-k-wahl="' + id + '" aria-label="' + esc(name(k)) + ' auswählen"' + (Z.auswahl[id] ? " checked" : "") + "></td>" +
            "<td><b>" + esc(name(k)) + "</b>" + (k.newsletter_erlaubt ? ' <span class="pille pille--gut" title="Newsletter erlaubt">NL</span>' : "") +
              (k.email ? '<small class="k-unter">' + esc(k.email) + "</small>" : "") + (k.telefon ? '<small class="k-unter">' + esc(k.telefon) + "</small>" : "") + "</td>" +
            '<td><span class="k-firma">' + esc(k.firma || "–") + '</span></td><td class="k-position">' + esc(k.position || "–") + "</td><td>" + pille(k.lifecycle_stage) + "</td><td>" + relativ(k.letzte_aktivitaet) + "</td>" +
            '<td class="k-menue-spalte"><button type="button" class="k-punkte" data-k-menue="' + id + '" aria-label="Aktionen für ' + esc(name(k)) + '" aria-haspopup="true" aria-expanded="' + (Z.menue === id) + '">⋮</button>' +
              (Z.menue === id ? menue(k, liste) : "") + "</td></tr>";
        }).join("") + "</tbody></table></div>"
        : '<div class="karte leer">' + (Z.suche || Z.filter || filterAktiv() ? "Kein Kontakt gefunden." : "Noch keine Kontakte. Sie entstehen automatisch mit jeder Terminbuchung.") + "</div>");
  }
  /* ---------- Neu aus dem Postfach: externe Absender, die noch kein Kontakt sind ---------- */
  function wannKurz(d) { return d ? new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "–"; }
  function neuBereich() {
    if (!Z.neu.length) return "";
    return '<details class="karte k-neu" data-k-neu-box' + (Z.neuOffen ? " open" : "") + '><summary><span class="k-neu-zahl">' + Z.neu.length + "</span>" +
        "<b>Neu aus dem Postfach</b><span class=\"leise\">haben euch geschrieben, sind aber noch kein Kontakt</span></summary>" +
      '<ul class="k-neu-liste">' + Z.neu.map(function (a) {
        return '<li><div class="k-neu-wer"><b>' + esc(a.name || a.email) + "</b>" + (a.name ? '<span class="leise">' + esc(a.email) + "</span>" : "") +
            (a.betreff ? '<span class="k-neu-betreff">' + esc(a.betreff) + "</span>" : "") +
            '<small class="leise">' + a.mails + (a.mails === 1 ? " Mail" : " Mails") + " · zuletzt " + wannKurz(a.letzte) + "</small></div>" +
          '<div class="k-neu-knoepfe"><button type="button" class="knopf knopf--primaer knopf--klein" data-k-uebernehmen="' + esc(a.email) + '" data-name="' + esc(a.name || "") + '">Übernehmen</button>' +
          '<button type="button" class="knopf knopf--klein" data-k-ablehnen="' + esc(a.email) + '">Ablehnen</button></div></li>';
      }).join("") + "</ul></details>";
  }

  function tagsPanel() {
    return '<section class="karte panel k-tags-panel"><div class="panel-kopf"><h2>Tags</h2><span class="leise">Diese Tags stehen in der Kontaktkarte unter „+“ zur Auswahl und sind zugleich die Listen</span></div>' +
      '<ul class="k-tags-liste">' + (Z.listen.length ? Z.listen.map(function (l) {
        return '<li><a class="k-tag" href="#kontakte/liste:' + encodeURIComponent(l.liste) + '">' + esc(l.liste.replace(/_/g, " ")) + "</a>" +
          '<span class="leise">' + zahlText(l.kontakte, "Kontakt", "Kontakte") + "</span>" +
          '<button type="button" class="li-link li-link--gefahr" data-k-tag-loeschen="' + esc(l.liste) + '">löschen</button></li>';
      }).join("") : '<li class="leise">Noch keine Tags.</li>') + "</ul>" +
      '<div class="k-tag-anlegen"><label class="feld">Neuer Tag<input data-k-tag-name maxlength="60" placeholder="z. B. Bestandskunde"></label>' +
        '<button type="button" class="knopf knopf--primaer" data-k-tag-anlegen>Anlegen</button></div></section>';
  }
  function zahlText(n, eins, viele) { return Number(n || 0).toLocaleString("de-DE") + " " + (n === 1 ? eins : viele); }

  function menue(k, liste) {
    return '<div class="k-menue" role="menu">' +
      '<button type="button" role="menuitem" data-k-m="liste" data-id="' + k.contact_id + '">Liste</button>' +
      '<button type="button" role="menuitem" data-k-m="bearbeiten" data-id="' + k.contact_id + '">Bearbeiten</button>' +
      (liste ? '<button type="button" role="menuitem" data-k-m="entfernen" data-id="' + k.contact_id + '">Aus „' + esc(liste) + '“ entfernen</button>' : "") +
      '<button type="button" role="menuitem" class="k-menue-gefahr" data-k-m="loeschen" data-id="' + k.contact_id + '">Löschen</button></div>';
  }

  // Auswahlfeld „Zu Liste hinzufügen“ (für einen oder mehrere Kontakte)
  function panel() {
    var P = Z.panel; if (!P) return "";
    var n = P.ids.length;
    return '<div class="karte k-panel"><b>' + (n === 1 ? esc(P.name) : n + " Kontakte") + " einer Liste hinzufügen</b>" +
      '<div class="k-panel-reihe"><label class="feld">Bestehende Liste<select data-k-bestehend><option value="">– wählen –</option>' +
        Z.listen.map(function (l) { return '<option value="' + esc(l.liste) + '"' + (P.liste === l.liste ? " selected" : "") + ">" + esc(l.liste) + " (" + l.kontakte + ")</option>"; }).join("") +
      '</select></label><span class="k-oder">oder</span><label class="feld">Neue Liste<input data-k-neu maxlength="60" value="' + esc(P.neu || "") + '" placeholder="z. B. Bestandskunden 2026"></label></div>' +
      '<p class="leise nl-klein">Die Liste ist eine Markierung. Den Newsletter bekommen nur Kontakte, bei denen „Newsletter erlaubt“ gesetzt ist.</p>' +
      '<div class="knoepfe"><button type="button" class="knopf" data-k-aktion="panel-zu">Abbrechen</button>' +
        '<button type="button" class="knopf knopf--primaer" data-k-aktion="hinzufuegen">Hinzufügen</button></div></div>';
  }
  function panelOeffnen(ids, nameEinzeln) { Z.panel = { ids: ids, name: nameEinzeln || "", liste: "", neu: "", fokus: true }; Z.menue = null; listeZeichnen(); }

  function zuordnen(ids, liste, was) {
    return api("liste_zuordnen", { contact_ids: ids, liste: liste, was: was }).then(function (r) {
      Z.meldung = was === "hinzufuegen"
        ? zahlText(r.geaendert, "Kontakt", "Kontakte") + " zur Liste „" + r.liste + "“ hinzugefügt" + (r.ausgewaehlt > r.geaendert ? " (" + (r.ausgewaehlt - r.geaendert) + " waren schon drin)" : "") +
          ". Von den ausgewählten " + (r.mit_erlaubnis === 1 ? "darf 1" : "dürfen " + r.mit_erlaubnis) + " den Newsletter bekommen."
        : zahlText(r.geaendert, "Kontakt", "Kontakte") + " aus „" + r.liste + "“ entfernt.";
      Z.panel = null; Z.auswahl = {};
      return listeLaden();
    });
  }

  /* ---------- Detail ---------- */
  function detailLaden(id) {
    return Promise.all([api("kontakt", { contact_id: id }), api("listen", {})]).then(function (x) {
      var d = x[0]; Z.listen = x[1] || [];
      if (d) { Z.tags = (d.kontakt.tags || []).slice(); Z.tagMenue = false; }
      if (!d) { Z.detail = null; if (aktiv) wurzel.innerHTML = '<div class="karte leer">Kontakt nicht gefunden. <a href="#kontakte" data-zurueck>Zur Liste</a></div>'; return; }
      Z.detail = d; Z.offen = {};
      if (aktiv) detailZeichnen();
    }).catch(fehler);
  }

  function detailZeichnen() {
    var d = Z.detail, k = d.kontakt;
    var opt = function (map, wert) { return Object.keys(map).map(function (v) { return '<option value="' + v + '"' + ((wert || "") === v ? " selected" : "") + ">" + esc(map[v]) + "</option>"; }).join(""); };
    wurzel.innerHTML =
      '<p class="zurueck"><a href="#kontakte" data-zurueck>← Alle Kontakte</a></p>' +
      '<div class="kopf"><div><h1>' + esc(name(k)) + "</h1><p class=\"leise\">" + esc([k.position, k.firma, k.email].filter(Boolean).join(" · ")) + " · seit " + datum(k.created_at) + "</p></div>" + pille(k.lifecycle_stage) + "</div>" +
      '<div class="detail-raster">' +
        '<section class="karte panel"><div class="panel-kopf"><h2>Verlauf</h2><span class="leise">neueste zuerst</span></div>' + timeline(d.timeline) + "</section>" +
        '<div class="detail-seite">' +
          signale(d.timeline, k) +
          '<section class="karte panel"><div class="panel-kopf"><h2>Angaben</h2></div><form class="stammdaten" data-stammdaten>' +
            '<div class="reihe reihe--titel"><label class="feld">Titel<input name="titel" value="' + esc(k.titel) + '" placeholder="Dr."></label><label class="feld">Vorname<input name="vorname" value="' + esc(k.vorname) + '"></label></div>' +
            '<label class="feld">Nachname<input name="nachname" value="' + esc(k.nachname) + '"></label>' +
            '<label class="feld">E-Mail<input name="email" type="email" value="' + esc(k.email) + '" placeholder="name@firma.de"></label>' +
            '<label class="feld">Telefon<input name="telefon" value="' + esc(k.telefon) + '"></label>' +
            '<label class="feld">Position<input name="position" value="' + esc(k.position) + '"></label>' +
            '<div class="feld"><span>Tags</span><div class="k-tags" data-k-tags>' + tagsHtml() + "</div></div>" +
            '<label class="feld">Herkunft <small>Erstkontakt</small><select name="herkunft">' + opt(HERKUNFT, k.herkunft) + "</select></label>" +
            '<label class="k-nl"><span>Newsletter</span><input type="checkbox" class="k-schalter" name="newsletter_erlaubt"' + (k.newsletter_erlaubt ? " checked" : "") + "></label>" +
            '<label class="feld" data-nl-grund' + (k.newsletter_erlaubt ? "" : " hidden") + '>Grundlage<select name="newsletter_grundlage">' + opt(GRUNDLAGE, k.newsletter_grundlage) + "</select>" +
              (k.newsletter_erlaubt && k.newsletter_seit ? "<small>erlaubt seit " + datum(k.newsletter_seit) + "</small>" : "") + "</label>" +
            '<div class="reihe"><label class="feld">Status<select name="lifecycle_stage">' + opt(STATUS, k.lifecycle_stage) + '</select></label>' +
              '<label class="feld">Paketinteresse<select name="paketinteresse">' + opt(PAKET, k.paketinteresse) + "</select></label></div>" +
            '<label class="feld">Zuständig<input name="owner" value="' + esc(k.owner) + '" placeholder="Noah / Daniel"></label>' +
            '<label class="feld" data-lost' + (k.lifecycle_stage === "verloren" ? "" : " hidden") + '>Grund für Verlust<input name="lost_grund" value="' + esc(k.lost_grund) + '"></label>' +
            '<label class="feld">Notizen<textarea name="notizen" rows="5">' + esc(k.notizen) + "</textarea></label>" +
            '<p class="fehler" data-k-meldung></p>' +
            '<div class="knoepfe"><button type="submit" class="knopf knopf--primaer">Speichern</button></div>' +
          "</form></section>" +
          '<section class="karte panel"><div class="panel-kopf"><h2>Kennungen</h2></div>' +
            (d.identitaeten.length ? '<table class="tabelle"><tbody>' + d.identitaeten.map(function (i) {
              return "<tr><td>" + esc({ visitor_id: "Website-Besucher", email: "E-Mail", telefon: "Telefon", linkedin_profile_url: "LinkedIn" }[i.typ] || i.typ) + '</td><td class="kennung">' +
                (i.typ === "linkedin_profile_url" ? '<a href="' + esc(i.wert) + '" target="_blank" rel="noopener">' + esc(i.wert.replace(/^https:\/\/(www\.)?linkedin\.com/, "")) + "</a>"
                  : esc(i.typ === "visitor_id" ? i.wert.slice(0, 8) + "…" : i.wert)) + '</td><td class="leise">' + esc(i.quelle) + "</td></tr>";
            }).join("") + "</tbody></table>" : '<p class="panel-leer">Keine.</p>') +
          "</section>" +
          '<div class="gefahrzone"><button type="button" class="knopf knopf--gefahr" data-k-loeschen>Kontakt endgültig löschen</button>' +
            '<small class="leise">Entfernt die Person mit allen Besuchen, Terminen, Mails und Calls.</small></div>' +
        "</div>" +
      "</div>";
  }

  // Tags als Chips; „+“ öffnet die Auswahl aus dem Katalog
  function tagsHtml() {
    var frei = Z.listen.filter(function (l) { return Z.tags.indexOf(l.liste) < 0; });
    return Z.tags.map(function (t) {
      return '<span class="k-tag">' + esc(tagName(t)) + '<button type="button" data-k-tag-weg="' + esc(t) + '" aria-label="Tag ' + esc(tagName(t)) + ' entfernen">' + icon("kreuz") + "</button></span>";
    }).join("") +
      '<span class="k-tag-neu"><button type="button" class="k-tag-plus" data-k-tag-plus aria-haspopup="true" aria-expanded="' + !!Z.tagMenue + '" aria-label="Tag hinzufügen">' + icon("plus") + "</button>" +
      (Z.tagMenue ? '<div class="k-tag-menue" role="menu">' + (frei.length ? frei.map(function (l) {
          return '<button type="button" role="menuitem" data-k-tag-dazu="' + esc(l.liste) + '">' + esc(tagName(l.liste)) + '<small>' + l.kontakte + "</small></button>";
        }).join("") : '<p class="leise">Alle Tags sind schon gesetzt.</p>') +
        '<a class="k-tag-verwalten" href="#kontakte" data-k-tags-verwalten>Tags verwalten</a></div>' : "") + "</span>";
  }
  function tagsNeu() { var el = wurzel.querySelector("[data-k-tags]"); if (el) el.innerHTML = tagsHtml(); }

  // Zusammenfassung der Signale aus dem Verlauf
  function signale(t, k) {
    function n(name) { return t.filter(function (e) { return e.event_name === name; }); }
    function zuletzt(l) { return l.length ? relativ(l[0].zeit) : ""; }
    var web = t.filter(function (e) { return e.quelle === "website"; });
    var sitzungen = {}; web.forEach(function (e) { if (e.sitzung) sitzungen[e.sitzung] = true; });
    var seiten = n("page_view"), preise = web.filter(function (e) { return e.event_name === "pricing_toggle" || e.seitentyp === "preis"; });
    var termine = n("meeting_booked"), kal = n("calendar_meeting").filter(function (e) { return !(e.props || {}).abgesagt; });
    var calls = n("call_recorded"), ein = n("mail_received"), aus = n("mail_sent");
    var klicks = n("email_click"), nlEin = n("email_sent"), ab = n("email_unsubscribe");
    var li = n("linkedin_reaction"), folgt = n("linkedin_follow"), liK = n("linkedin_comment"), auf = n("email_open");
    var igL = n("instagram_like"), igK = n("instagram_comment"), igF = n("instagram_follow");
    var z = [];
    function zeile(ic, titel, wert, wann) { z.push('<li><span class="k-sig-ic">' + icon(ic) + '</span><span class="k-sig-t">' + titel + '</span><b>' + wert + "</b>" + (wann ? '<small>' + wann + "</small>" : "<small></small>") + "</li>"); }
    if (web.length) zeile("web", "Website-Besuche", Object.keys(sitzungen).length || 1, zuletzt(web));
    if (seiten.length) zeile("web", "Seiten angesehen", seiten.length, "");
    if (preise.length) zeile("preis", "Preise angesehen", "ja", zuletzt(preise));
    if (termine.length) zeile("termin", "Termine gebucht", termine.length, zuletzt(termine));
    if (kal.length) zeile("termin", "Termine im Kalender", kal.length, zuletzt(kal));
    if (calls.length) zeile("call", "Calls", calls.length, zuletzt(calls));
    if (ein.length) zeile("mailEin", "Mails erhalten", ein.length, zuletzt(ein));
    if (aus.length) zeile("mailAus", "Mails gesendet", aus.length, zuletzt(aus));
    if (nlEin.length) zeile("news", "Newsletter bekommen", nlEin.length, zuletzt(nlEin));
    if (auf.length) zeile("auge", "Newsletter geöffnet", auf.length, zuletzt(auf));
    if (klicks.length) zeile("klick", "Newsletter-Klicks", klicks.length, zuletzt(klicks));
    if (ab.length) zeile("weg", "Newsletter abbestellt", "ja", zuletzt(ab));
    if (li.length) zeile("daumen", "LinkedIn-Reaktionen", li.length, zuletzt(li));
    if (liK.length) zeile("sprech", "LinkedIn-Kommentare", liK.length, zuletzt(liK));
    if (igF.length) zeile("folgen", "Folgt auf Instagram", "ja", "");
    if (igL.length) zeile("daumen", "Instagram-Likes", igL.length, zuletzt(igL));
    if (igK.length) zeile("sprech", "Instagram-Kommentare", igK.length, zuletzt(igK));
    if (folgt.length) zeile("folgen", "Folgt der Firmenseite", "seit", new Date(folgt[0].zeit).toLocaleDateString("de-DE", { month: "short", year: "numeric" }));
    var stand = k.newsletter_erlaubt ? '<span class="pille pille--gut">Newsletter erlaubt</span>' : '<span class="pille">kein Newsletter</span>';
    return '<section class="karte panel"><div class="panel-kopf"><h2>Signale</h2>' + stand + "</div>" +
      (z.length ? '<ul class="k-signale">' + z.join("") + "</ul>" : '<p class="panel-leer">Noch keine Signale.</p>') + "</section>";
  }

  // Ereignisse in Einträge bündeln: alles einer Website-Sitzung wird ein Eintrag.
  function eintraege(t) {
    var liste = [], sitzungen = {};
    t.forEach(function (e) {
      if (e.quelle === "website") {
        var key = e.sitzung || "ohne-" + e.zeit;
        if (!sitzungen[key]) { sitzungen[key] = { art: "besuch", key: key, zeit: e.zeit, ereignisse: [] }; liste.push(sitzungen[key]); }
        sitzungen[key].ereignisse.push(e);
        if (e.zeit < sitzungen[key].start || !sitzungen[key].start) sitzungen[key].start = e.zeit;
      } else {
        liste.push({ art: "einzeln", zeit: e.zeit, e: e });
      }
    });
    return liste;
  }

  function tagLabel(d) {
    var t = new Date(d), heute = new Date(), gestern = new Date(Date.now() - 864e5);
    if (t.toDateString() === heute.toDateString()) return "Heute";
    if (t.toDateString() === gestern.toDateString()) return "Gestern";
    return t.toLocaleDateString("de-DE", { weekday: "short", day: "numeric", month: "long", year: t.getFullYear() === heute.getFullYear() ? undefined : "numeric" });
  }
  function uhr(d) { return new Date(d).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" }); }
  function timeline(t) {
    if (!t.length) return '<p class="panel-leer">Noch keine Aktivität.</p>';
    var letzter = "", out = [];
    eintraege(t).forEach(function (x) {
      var z = x.art === "besuch" ? (x.start || x.zeit) : x.zeit, nurMonat = x.e && (x.e.props || {}).nur_monat;
      var lab = nurMonat ? new Date(z).toLocaleDateString("de-DE", { month: "long", year: "numeric" }) : tagLabel(z);
      if (lab !== letzter) { out.push('<li class="tl-tag">' + esc(lab) + "</li>"); letzter = lab; }
      out.push(x.art === "besuch" ? besuch(x) : einzeln(x.e));
    });
    return '<ol class="timeline">' + out.join("") + "</ol>";
  }

  function besuch(b) {
    var ev = b.ereignisse.slice().reverse();   // chronologisch
    var seiten = ev.filter(function (e) { return e.event_name === "page_view"; });
    var lesezeit = ev.filter(function (e) { return e.event_name === "section_time"; }).reduce(function (a, e) { return a + (Number(e.props.seconds) || 0); }, 0);
    var st = ev.filter(function (e) { return e.event_name === "session_start"; })[0];
    var herkunft = st ? (st.props.utm_source ? st.props.utm_source + (st.props.utm_campaign ? " · " + st.props.utm_campaign : "") :
      st.props.gclid ? "Google Ads" : st.props.referrer ? st.props.referrer.replace(/^https?:\/\/(www\.)?/, "") : "direkt") : null;
    var marken = [];
    if (ev.some(function (e) { return e.event_name === "meeting_booked"; })) marken.push('<span class="pille pille--gut">Termin gebucht</span>');
    else if (ev.some(function (e) { return e.event_name === "booking_widget_view"; })) marken.push('<span class="pille">Kalender geöffnet</span>');
    if (ev.some(function (e) { return e.event_name === "pricing_toggle" || e.seitentyp === "preis"; })) marken.push('<span class="pille">Preise angesehen</span>');
    var auf = !!Z.offen[b.key];
    return '<li class="tl tl--besuch"><span class="tl-icon">' + icon("web") + '</span><div class="tl-inhalt">' +
      '<button type="button" class="tl-kopf" data-tl="' + esc(b.key) + '" aria-expanded="' + auf + '">' +
        '<b>Website-Besuch</b><span class="tl-zeit">' + uhr(b.start || b.zeit) + "</span>" +
        '<span class="tl-sub">' + seiten.length + (seiten.length === 1 ? " Seite" : " Seiten") + (lesezeit ? " · " + dauer(lesezeit) + " gelesen" : "") + (herkunft ? " · über " + esc(herkunft) : "") + "</span>" +
        (marken.length ? '<span class="tl-marken">' + marken.join("") + "</span>" : "") +
      "</button>" +
      (auf ? '<ul class="tl-details">' + ev.map(function (e) { return "<li>" + ereignisText(e) + "</li>"; }).join("") + "</ul>" : "") +
      "</div></li>";
  }

  function ereignisText(e) {
    var uhr = new Date(e.zeit).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
    var seite = SEITENTYP[e.seitentyp] || e.pfad || "";
    var t = {
      session_start: "Besuch beginnt",
      page_view: "Seite " + esc(e.pfad || "") + ' <span class="leise">' + esc(seite) + "</span>",
      section_view: "Abschnitt „" + esc(e.props.section || "") + "“ gesehen",
      section_time: "„" + esc(e.props.section || "") + "“ " + (Number(e.props.seconds) || 0) + " s gelesen",
      cta_click: "Klick: " + esc(e.props.ziel || "") + (e.props.text ? " („" + esc(e.props.text) + "“)" : ""),
      pricing_toggle: "Preise auf " + esc(e.props.intervall || "") + " umgestellt",
      booking_widget_view: "Kalender geöffnet",
      meeting_booked: "<b>Termin gebucht</b>",
      scroll_depth: "Gescrollt bis " + esc(e.props.percent || "") + " %"
    }[e.event_name] || esc(e.event_name);
    return '<span class="tl-uhr">' + uhr + "</span> " + t;
  }

  function einzeln(e) {
    var p = e.props || {}, titel, text = "", klasse = "", ic = "news";
    if (e.event_name === "meeting_booked") { titel = "Termin gebucht"; klasse = "tl--termin"; text = (p.termin_start ? "für " + zeit(p.termin_start) : "") + (p.antworten ? antworten(p.antworten) : ""); }
    else if (e.event_name === "meeting_rescheduled") { titel = "Termin verlegt"; klasse = "tl--termin"; text = p.termin_start ? "neu: " + zeit(p.termin_start) : ""; }
    else if (e.event_name === "meeting_canceled") { titel = "Termin abgesagt"; klasse = "tl--absage"; text = p.absage_grund ? "Grund: " + esc(p.absage_grund) : ""; }
    else if (e.event_name === "meeting_no_show") { titel = p.no_show === false ? "Nicht-Erscheinen zurückgenommen" : "Nicht erschienen"; klasse = "tl--absage"; }
    else if (e.event_name === "mail_received" || e.event_name === "mail_sent") {
      var rein = e.event_name === "mail_received";
      titel = (rein ? "Mail erhalten" : "Mail gesendet") + (p.betreff ? ": " + esc(p.betreff) : "");
      klasse = "tl--mail";
      text = (p.vorschau ? '<span class="tl-vorschau">' + esc(p.vorschau) + "</span>" : "") +
        '<small class="leise">' + (rein ? "an " : "aus ") + esc(p.postfach || "") + (p.anhang ? " · mit Anhang" : "") + "</small>";
    }
    else if (e.event_name === "calendar_meeting") {
      titel = (p.abgesagt ? "Termin abgesagt: " : "Termin: ") + esc(p.betreff || "ohne Titel");
      klasse = p.abgesagt ? "tl--absage" : "tl--termin";
      text = esc([p.beginn ? zeit(p.beginn) + (p.ende ? "–" + new Date(p.ende).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" }) : "") : "",
                  p.ort, p.online ? "online" : "", p.postfach ? "Kalender " + p.postfach : ""].filter(Boolean).join(" · "));
    }
    else if (e.event_name === "call_recorded") { titel = "Call: " + esc(p.titel || "Gespräch"); klasse = "tl--call"; text = p.call_id ? '<a href="#calls/' + esc(p.call_id) + '" data-call="' + esc(p.call_id) + '">Protokoll öffnen</a>' : ""; }
    else if (e.event_name === "linkedin_follow") {
      titel = "Folgt der Firmenseite auf LinkedIn"; klasse = "tl--linkedin";
      text = p.nur_monat ? '<small class="leise">laut Follower-Liste ist nur der Monat bekannt</small>' : "";
    }
    else if (e.event_name === "linkedin_reaction") {
      var arten = { like: "Gefällt mir", celebrate: "Applaus", support: "Unterstützung", love: "Liebe", insightful: "Interessant", funny: "Witzig" };
      titel = "LinkedIn: " + esc(arten[p.art] || "Reaktion") + " auf „" + esc(p.beitrag || "Beitrag") + "“";
      klasse = "tl--linkedin";
      text = esc((p.kanal === "daniel" ? "Beitrag von Daniel" : "Beitrag der Firmenseite") + (p.veroeffentlicht ? " vom " + new Date(p.veroeffentlicht).toLocaleDateString("de-DE") : "")) +
        (p.url ? ' · <a href="' + esc(p.url) + '" target="_blank" rel="noopener">Beitrag öffnen</a>' : "") +
        ' <small class="leise">Zeitpunkt = wann die Liste eingefügt wurde</small>';
    }
    else if (e.event_name === "linkedin_comment") {
      titel = "LinkedIn: Kommentar zu „" + esc(p.beitrag || "Beitrag") + "“"; klasse = "tl--linkedin";
      text = (p.text ? '<span class="tl-vorschau">„' + esc(p.text) + "“</span>" : "") +
        esc((p.kanal === "daniel" ? "Beitrag von Daniel" : "Beitrag der Firmenseite") + (p.veroeffentlicht ? " vom " + new Date(p.veroeffentlicht).toLocaleDateString("de-DE") : "")) +
        (p.url ? ' · <a href="' + esc(p.url) + '" target="_blank" rel="noopener">Beitrag öffnen</a>' : "");
    }
    else if (e.event_name === "instagram_follow") {
      titel = "Folgt sofort sichtbar auf Instagram"; klasse = "tl--linkedin"; ic = "folgen";
      text = (p.benutzername ? "@" + esc(p.benutzername) + " · " : "") + '<small class="leise">seit wann, ist nicht bekannt – Datum = Erfassung der Follower-Liste</small>';
    }
    else if (e.event_name === "instagram_like" || e.event_name === "instagram_comment") {
      var kom = e.event_name === "instagram_comment";
      titel = "Instagram: " + (kom ? "Kommentar zu" : "Like auf") + " „" + esc(p.beitrag || "Beitrag") + "“"; klasse = "tl--linkedin"; ic = kom ? "sprech" : "daumen";
      text = (kom && p.text ? '<span class="tl-vorschau">„' + esc(p.text) + "“</span>" : "") + (p.benutzername ? "@" + esc(p.benutzername) : "") +
        (p.url ? ' · <a href="' + esc(p.url) + '" target="_blank" rel="noopener">Beitrag öffnen</a>' : "");
    }
    else if (e.event_name === "email_open") { titel = "Newsletter geöffnet: " + esc(p.betreff || ""); klasse = "tl--news"; ic = "auge"; }
    else if (e.event_name === "email_sent") { titel = "Newsletter: " + esc(p.betreff || ""); klasse = "tl--news"; }
    else if (e.event_name === "email_delivered") { titel = "Newsletter zugestellt"; klasse = "tl--news"; }
    else if (e.event_name === "email_click") { titel = "Newsletter-Link geklickt"; klasse = "tl--klick"; text = p.url ? '<span class="tl-vorschau">' + esc(String(p.url).replace(/[?&]utm_[^&#]*/g, "").replace(/\?$/, "")) + "</span>" : ""; }
    else if (e.event_name === "email_unsubscribe") { titel = "Newsletter abbestellt"; klasse = "tl--absage"; }
    else if (e.event_name === "email_bounce") { titel = p.hard ? "Newsletter unzustellbar" : "Newsletter vorübergehend nicht zustellbar"; klasse = "tl--absage"; }
    else if (e.event_name === "email_complaint") { titel = "Newsletter als Spam markiert"; klasse = "tl--absage"; }
    else { titel = esc(e.event_name); }
    ic = { "tl--termin": "termin", "tl--absage": /^email_(unsub|bounce|compl)/.test(e.event_name) ? (e.event_name === "email_unsubscribe" ? "weg" : "warn") : "absage",
           "tl--mail": e.event_name === "mail_sent" ? "mailAus" : "mailEin", "tl--call": "call",
           "tl--linkedin": /_follow$/.test(e.event_name) ? "folgen" : /_comment$/.test(e.event_name) ? "sprech" : "daumen",
           "tl--news": e.event_name === "email_open" ? "auge" : "news", "tl--klick": "klick" }[klasse] || ic;
    return '<li class="tl ' + klasse + '"><span class="tl-icon">' + icon(ic) + '</span><div class="tl-inhalt"><div class="tl-kopf tl-kopf--fest"><b>' + titel + '</b><span class="tl-zeit">' + (p.nur_monat ? "" : uhr(e.zeit)) + "</span></div>" +
      (text ? '<div class="tl-text">' + text + "</div>" : "") + "</div></li>";
  }
  function antworten(a) {
    var z = Object.keys(a).map(function (k) { return "<dt>" + esc(k) + "</dt><dd>" + esc(typeof a[k] === "object" ? JSON.stringify(a[k]) : a[k]) + "</dd>"; });
    return z.length ? '<dl class="antworten">' + z.join("") + "</dl>" : "";
  }

  /* ---------- Bedienung ---------- */
  var suchTimer;
  wurzel.addEventListener("input", function (e) {
    if (aktiv && Z.panel && e.target.hasAttribute("data-k-neu")) { Z.panel.neu = e.target.value; return; }
    if (!aktiv || !e.target.hasAttribute("data-k-suche")) return;
    clearTimeout(suchTimer);
    suchTimer = setTimeout(function () { Z.suche = e.target.value.trim(); listeLaden(); }, 300);
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv) return;
    if (e.target.hasAttribute("data-k-filter")) {
      Z.filter = e.target.value; Z.auswahl = {}; Z.meldung = "";
      history.replaceState(null, "", aktuelleListe() ? "#kontakte/liste:" + encodeURIComponent(aktuelleListe()) : "#kontakte");
      return listeLaden();
    }
    if (Z.panel && e.target.hasAttribute("data-k-bestehend")) { Z.panel.liste = e.target.value; return; }
    if (e.target.name === "newsletter_erlaubt") { var g = wurzel.querySelector("[data-nl-grund]"); if (g) g.hidden = !e.target.checked; return; }
    if (e.target.name !== "lifecycle_stage") return;
    var l = wurzel.querySelector("[data-lost]"); if (l) l.hidden = e.target.value !== "verloren";
  });
  wurzel.addEventListener("input", function (e) {
    if (!aktiv || Z.detail) return;
    var t = e.target;
    if (t.hasAttribute("data-k-ftext")) { var k = t.getAttribute("data-k-ftext"), v = t.value.trim(); if (v) Z.f[k] = v; else delete Z.f[k]; return filterGeaendert(false); }
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv || Z.detail) return;
    var t = e.target, k;
    if ((k = t.getAttribute("data-k-fmulti"))) {
      Z.f[k] = [].slice.call(wurzel.querySelectorAll('[data-k-fmulti="' + k + '"]:checked')).map(function (x) { return x.value; });
      if (!Z.f[k].length) { delete Z.f[k]; if (k === "signale") delete Z.f.signal_tage; }
      return filterGeaendert(true);
    }
    if ((k = t.getAttribute("data-k-feins"))) { Z.f[k] = t.value; return filterGeaendert(true); }
    if ((k = t.getAttribute("data-k-fextra"))) { if (t.checked) Z.f[k] = true; else delete Z.f[k]; return filterGeaendert(true); }
    if (t.hasAttribute("data-k-fzeit")) { if (t.value) Z.f.signal_tage = Number(t.value); else delete Z.f.signal_tage; return filterGeaendert(true); }
  });
  document.addEventListener("click", function (e) {
    // Ziel schon ersetzt (Menü wurde neu gezeichnet) → war ein Klick im Menü
    if (!aktiv || !Z.fMenue || !e.target.isConnected || e.target.closest(".k-filterort, .k-chips")) return;
    Z.fMenue = false; Z.fSeite = null; fMenueNeu();
  });
  document.addEventListener("keydown", function (e) {
    if (aktiv && Z.fMenue && e.key === "Escape") { Z.fMenue = false; Z.fSeite = null; fMenueNeu(); var b = wurzel.querySelector("[data-k-fknopf]"); if (b) b.focus(); }
  });
  wurzel.addEventListener("toggle", function (e) {
    if (aktiv && e.target.hasAttribute && e.target.hasAttribute("data-k-neu-box")) Z.neuOffen = e.target.open;
  }, true);
  function oeffneKontakt(tr) { C.oeffne("kontakte", tr.getAttribute("data-kontakt")); }
  wurzel.addEventListener("keydown", function (e) {
    if (!aktiv || e.key !== "Enter") return;
    var tr = e.target.closest && e.target.closest("tr[data-kontakt]"); if (tr) oeffneKontakt(tr);
  });
  document.addEventListener("click", function (e) {
    // Menü schließen, wenn außerhalb geklickt wird
    if (!aktiv || Z.menue === null || e.target.closest(".k-menue, [data-k-menue]")) return;
    Z.menue = null; listeZeichnen();
  });
  document.addEventListener("keydown", function (e) {
    if (aktiv && e.key === "Escape" && (Z.menue !== null || Z.panel)) { Z.menue = null; Z.panel = null; listeZeichnen(); }
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t;
    if (Z.detail) {
      if (e.target.closest("[data-k-tag-plus]")) { Z.tagMenue = !Z.tagMenue; return tagsNeu(); }
      if ((t = e.target.closest("[data-k-tag-dazu]"))) { Z.tags.push(t.getAttribute("data-k-tag-dazu")); Z.tagMenue = false; return tagsNeu(); }
      if ((t = e.target.closest("[data-k-tag-weg]"))) { var w = t.getAttribute("data-k-tag-weg"); Z.tags = Z.tags.filter(function (x) { return x !== w; }); return tagsNeu(); }
      if (e.target.closest("[data-k-tags-verwalten]")) { e.preventDefault(); Z.tagsVerwalten = true; return C.oeffne("kontakte"); }
      if (Z.tagMenue && !e.target.closest(".k-tag-neu")) { Z.tagMenue = false; tagsNeu(); }
    }
    if (e.target.closest(".k-wahl")) {                       // Auswahlkästchen: nicht den Kontakt öffnen
      var cb = e.target.closest("[data-k-wahl]"), alleCb = e.target.closest("[data-k-alle-wahl]");
      if (cb) { Z.auswahl[cb.getAttribute("data-k-wahl")] = cb.checked; listeZeichnen(); }
      else if (alleCb) { var an = alleCb.checked; Z.auswahl = {}; if (an) Z.liste.forEach(function (k) { Z.auswahl[k.contact_id] = true; }); listeZeichnen(); }
      else { var inp = e.target.closest(".k-wahl").querySelector("input"); if (inp && e.target !== inp) inp.click(); }
      return;
    }
    if ((t = e.target.closest("[data-k-menue]"))) { e.stopPropagation(); var mid = t.getAttribute("data-k-menue"); Z.menue = Z.menue === mid ? null : mid; return listeZeichnen(); }
    if ((t = e.target.closest("[data-k-m]"))) {
      e.stopPropagation();
      var was = t.getAttribute("data-k-m"), id = t.getAttribute("data-id"), k = Z.liste.filter(function (x) { return x.contact_id === id; })[0];
      Z.menue = null;
      if (was === "bearbeiten") return C.oeffne("kontakte", id);
      if (was === "liste") return panelOeffnen([id], name(k));
      if (was === "entfernen") return zuordnen([id], aktuelleListe(), "entfernen").catch(fehler);
      if (was === "loeschen") {
        if (!confirm("„" + name(k) + "“ mit allen Besuchen, Terminen, Mails und Calls endgültig löschen? Das lässt sich nicht rückgängig machen.")) return listeZeichnen();
        return api("kontakt_loeschen", { contact_id: id }).then(function () { Z.meldung = "„" + name(k) + "“ wurde gelöscht."; delete Z.auswahl[id]; return listeLaden(); }).catch(fehler);
      }
      return;
    }
    if ((t = e.target.closest("[data-k-ansicht]"))) { Z.ansicht = t.getAttribute("data-k-ansicht"); Z.auswahl = {}; merken(); return listeLaden(); }
    if (e.target.closest("[data-k-fknopf]")) { Z.fMenue = !Z.fMenue; Z.fSeite = null; return fMenueNeu(); }
    if ((t = e.target.closest("[data-k-fseite]"))) {
      Z.fSeite = Z.fSeite === t.getAttribute("data-k-fseite") ? null : t.getAttribute("data-k-fseite"); fMenueNeu();
      var ti = wurzel.querySelector("[data-k-ftext]"); if (ti) { ti.focus(); ti.setSelectionRange(ti.value.length, ti.value.length); }
      return;
    }
    if ((t = e.target.closest("[data-k-chip]"))) { Z.fMenue = true; Z.fSeite = t.getAttribute("data-k-chip"); fMenueNeu(); var tc = wurzel.querySelector("[data-k-ftext]"); if (tc) tc.focus(); return; }
    if ((t = e.target.closest("[data-k-chip-weg]"))) {
      var weg = t.getAttribute("data-k-chip-weg"); delete Z.f[weg]; if (weg === "signale") delete Z.f.signal_tage; if (weg === "firma_id") Z.firmaName = "";
      if (Z.fMenue) fMenueNeu();
      return filterGeaendert(true);
    }
    if (e.target.closest("[data-k-filter-leeren]")) { Z.f = {}; Z.firmaName = ""; if (Z.fMenue) fMenueNeu(); return filterGeaendert(true); }
    if ((t = e.target.closest("tr[data-k-firma]"))) {
      Z.ansicht = "kontakte"; Z.f = { firma_id: t.getAttribute("data-k-firma") }; Z.firmaName = t.getAttribute("data-name"); merken(); return listeLaden();
    }
    if ((t = e.target.closest("[data-k-uebernehmen]"))) {
      t.disabled = true; t.textContent = "…";
      var mail = t.getAttribute("data-k-uebernehmen");
      return api("absender_uebernehmen", { email: mail, name: t.getAttribute("data-name") }).then(function () {
        Z.neuOffen = true; Z.meldung = mail + " ist jetzt Kontakt – frühere Mails hängen im Verlauf."; return listeLaden();
      }).catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
    if ((t = e.target.closest("[data-k-ablehnen]"))) {
      t.disabled = true;
      var weg = t.getAttribute("data-k-ablehnen");
      return api("absender_ignorieren", { email: weg }).then(function () {
        Z.neu = Z.neu.filter(function (a) { return a.email !== weg; }); Z.neuOffen = true; listeZeichnen();
      }).catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
    if (e.target.closest("[data-k-tags-knopf]")) { Z.tagsVerwalten = !Z.tagsVerwalten; return listeZeichnen(); }
    if (e.target.closest("[data-k-tag-anlegen]")) {
      var feld = wurzel.querySelector("[data-k-tag-name]"), neu = (feld && feld.value || "").trim();
      if (!neu) return feld && feld.focus();
      return api("tag_anlegen", { name: neu }).then(function (n) { Z.meldung = "Tag „" + n + "“ angelegt."; return listeLaden(); }).catch(fehler);
    }
    if ((t = e.target.closest("[data-k-tag-loeschen]"))) {
      var tl = t.getAttribute("data-k-tag-loeschen");
      if (!confirm("Tag „" + tl + "“ löschen? Er wird bei allen Kontakten entfernt, die Kontakte selbst bleiben.")) return;
      return api("liste_loeschen", { liste: tl }).then(function (n) { Z.meldung = "Tag „" + tl + "“ gelöscht (" + n + " Kontakte)."; return listeLaden(); }).catch(fehler);
    }
    if ((t = e.target.closest("[data-k-aktion]"))) {
      var a = t.getAttribute("data-k-aktion");
      if (a === "aufheben") { Z.auswahl = {}; return listeZeichnen(); }
      if (a === "liste") return panelOeffnen(ausgewaehlt());
      if (a === "panel-zu") { Z.panel = null; return listeZeichnen(); }
      if (a === "entfernen") {
        var ids = ausgewaehlt();
        if (!confirm(ids.length + (ids.length === 1 ? " Kontakt" : " Kontakte") + " aus der Liste „" + aktuelleListe() + "“ entfernen? Die Kontakte selbst bleiben erhalten.")) return;
        return zuordnen(ids, aktuelleListe(), "entfernen").catch(fehler);
      }
      if (a === "hinzufuegen") {
        var ziel = (Z.panel.neu || "").trim() || Z.panel.liste;
        if (!ziel) { alert("Bitte eine bestehende Liste wählen oder einen Namen für eine neue Liste eingeben."); return; }
        t.disabled = true;
        return zuordnen(Z.panel.ids, ziel, "hinzufuegen").catch(function (err) { t.disabled = false; alert("Fehler: " + err.message); });
      }
    }
    if (e.target.closest("[data-k-liste-loeschen]")) {
      var l = aktuelleListe();
      if (!confirm("Liste „" + l + "“ auflösen? Die Markierung wird bei allen Kontakten entfernt, die Kontakte selbst bleiben erhalten.")) return;
      return api("liste_loeschen", { liste: l }).then(function (n) { Z.meldung = "Liste „" + l + "“ aufgelöst (" + n + " Kontakte)."; Z.filter = ""; history.replaceState(null, "", "#kontakte"); return listeLaden(); }).catch(fehler);
    }
    if (e.target.closest("[data-k-alle]")) { e.preventDefault(); Z.filter = ""; Z.meldung = ""; history.pushState(null, "", "#kontakte"); return listeLaden(); }
    var tr = e.target.closest("tr[data-kontakt]"); if (tr) return oeffneKontakt(tr);
    var z = e.target.closest("[data-zurueck]"); if (z) { e.preventDefault(); return C.oeffne("kontakte"); }
    var c = e.target.closest("[data-call]"); if (c) { e.preventDefault(); return C.oeffne("calls", c.getAttribute("data-call")); }
    var t = e.target.closest("[data-tl]");
    if (t) { var k = t.getAttribute("data-tl"); Z.offen[k] = !Z.offen[k]; return detailZeichnen(); }
    if (e.target.closest("[data-k-loeschen]")) {
      var k2 = Z.detail.kontakt;
      if (!confirm("„" + name(k2) + "“ mit allen Besuchen, Terminen und Calls endgültig löschen? Das lässt sich nicht rückgängig machen.")) return;
      api("kontakt_loeschen", { contact_id: k2.contact_id }).then(function () { C.oeffne("kontakte"); }).catch(fehler);
    }
  });
  wurzel.addEventListener("submit", function (e) {
    if (!aktiv || !e.target.hasAttribute("data-stammdaten")) return;
    e.preventDefault();
    var f = e.target, m = wurzel.querySelector("[data-k-meldung]"), knopf = f.querySelector('button[type="submit"]');
    var daten = { contact_id: Z.detail.kontakt.contact_id };
    ["email", "titel", "vorname", "nachname", "telefon", "position", "lifecycle_stage", "paketinteresse", "owner", "lost_grund", "notizen", "herkunft", "newsletter_grundlage"].forEach(function (n) { daten[n] = f.elements[n].value; });
    daten.tags = Z.tags.slice();
    daten.newsletter_erlaubt = f.elements.newsletter_erlaubt.checked;
    if (daten.newsletter_erlaubt && !daten.newsletter_grundlage) { m.textContent = "Bitte die Grundlage für den Newsletter wählen."; return; }
    knopf.disabled = true; m.textContent = "";
    api("kontakt_speichern", { kontakt: daten }).then(function () {
      return detailLaden(daten.contact_id).then(function () { var mm = wurzel.querySelector("[data-k-meldung]"); if (mm) { mm.textContent = "Gespeichert."; mm.classList.add("ok"); } });
    }).catch(function (err) { knopf.disabled = false; m.textContent = err.message; });
  });

  C.module.kontakte = { start: start, stop: stop };
})();
