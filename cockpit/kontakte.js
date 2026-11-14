/* Cockpit · Kontakte – Liste, Detail mit Timeline, Bearbeiten.
   Die Timeline bündelt Website-Ereignisse zu Besuchen (eine Sitzung = ein
   Eintrag) und zeigt Termine und Calls dazwischen. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { liste: [], suche: "", filter: "", detail: null, offen: {} };
  var aktiv = false;

  var STATUS = { lead: "Lead", mql: "MQL", sql: "SQL", kunde: "Kunde", verloren: "Verloren" };
  var PAKET = { "": "–", fokus: "Fokus", team: "Team", komplett: "Komplett" };
  var HERKUNFT = { "": "–", termin: "Terminbuchung", postfach: "Postfach", call: "Call", website: "Website",
                   linkedin_follower: "LinkedIn-Follower", linkedin_reaktion: "LinkedIn-Reaktion", manuell: "Manuell", import: "Import" };
  var GRUNDLAGE = { "": "– bitte wählen –", einwilligung: "Einwilligung (z. B. Formular, DOI)", bestandskunde: "Bestandskunde" };
  var FILTER = [["", "Alle Kontakte"], ["newsletter", "Newsletter erlaubt"], ["tag:linkedin_follower", "Tag: LinkedIn-Follower"],
                ["herkunft:linkedin_follower", "Herkunft: LinkedIn-Follower"], ["herkunft:linkedin_reaktion", "Herkunft: LinkedIn-Reaktion"],
                ["herkunft:termin", "Herkunft: Terminbuchung"], ["herkunft:postfach", "Herkunft: Postfach"], ["herkunft:call", "Herkunft: Call"],
                ["herkunft:website", "Herkunft: Website"]];
  var SEITENTYP = { home: "Startseite", preis: "Preise", kontakt: "Kontakt", zielgruppe: "Zielgruppen", produkt: "Produkt",
                    rechtliches: "Rechtliches", karriere: "Karriere", blog: "Blog", referenz: "Referenzen", sonstige: "Sonstige" };

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
    aktiv = true;
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    id ? detailLaden(id) : listeLaden();
  }
  function stop() { aktiv = false; }
  function fehler(e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; }

  /* ---------- Liste ---------- */
  function listeLaden() {
    Z.detail = null;
    return api("kontakte_liste", { suche: Z.suche, filter: Z.filter }).then(function (r) {
      Z.liste = r;
      if (!Z.suche && !Z.filter) { var z = document.querySelector('[data-zahl="kontakte"]'); if (z) z.textContent = r.length || ""; }
      if (aktiv) listeZeichnen();
    }).catch(fehler);
  }

  function listeZeichnen() {
    var fokus = document.activeElement && document.activeElement.hasAttribute("data-k-suche");
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Kontakte</h1><p class="leise">Alle Personen aus Terminbuchungen, Postfach, Calls und LinkedIn</p></div></div>' +
      '<div class="leiste k-leiste"><input type="search" class="suche" data-k-suche placeholder="Name, E-Mail, Firma oder Position" value="' + esc(Z.suche) + '">' +
        '<select class="k-filter" data-k-filter aria-label="Filter">' + FILTER.map(function (f) {
          return '<option value="' + f[0] + '"' + (Z.filter === f[0] ? " selected" : "") + ">" + esc(f[1]) + "</option>";
        }).join("") + "</select></div>" +
      '<p class="zahlzeile">' + Z.liste.length + (Z.liste.length === 1 ? " Kontakt" : " Kontakte") + "</p>" +
      (Z.liste.length ? '<div class="karte tabelle-rahmen"><table class="tabelle tabelle--klick"><thead><tr><th>Name</th><th>Firma</th><th>Herkunft</th><th>Status</th><th>Letzte Aktivität</th>' +
        '<th class="n">Besuche</th><th class="n">Termine</th><th class="n">LinkedIn</th><th class="n">Calls</th></tr></thead><tbody>' +
        Z.liste.map(function (k) {
          return '<tr data-kontakt="' + k.contact_id + '" tabindex="0"><td><b>' + esc(name(k)) + "</b>" + (k.newsletter_erlaubt ? ' <span class="pille pille--gut" title="Newsletter erlaubt">NL</span>' : "") +
              '<br><small class="leise">' + esc(k.email || k.position || "") + "</small></td>" +
            "<td>" + esc(k.firma || "–") + "</td><td>" + esc(HERKUNFT[k.herkunft || ""] || k.herkunft) + "</td><td>" + pille(k.lifecycle_stage) + "</td><td>" + relativ(k.letzte_aktivitaet) + "</td>" +
            '<td class="n">' + k.besuche + '</td><td class="n">' + k.termine + '</td><td class="n">' + (k.linkedin || 0) + '</td><td class="n">' + k.calls + "</td></tr>";
        }).join("") + "</tbody></table></div>"
        : '<div class="karte leer">' + (Z.suche || Z.filter ? "Kein Kontakt gefunden." : "Noch keine Kontakte. Sie entstehen automatisch mit jeder Terminbuchung.") + "</div>");
    if (fokus) { var f = wurzel.querySelector("[data-k-suche]"); if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } }
  }

  /* ---------- Detail ---------- */
  function detailLaden(id) {
    return api("kontakt", { contact_id: id }).then(function (d) {
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
      '<div class="kopf"><div><h1>' + esc(name(k)) + "</h1><p class=\"leise\">" + esc([k.position, k.email, k.firma, HERKUNFT[k.herkunft || ""] && k.herkunft ? "über " + HERKUNFT[k.herkunft] : ""].filter(Boolean).join(" · ")) + " · seit " + datum(k.created_at) + "</p></div>" + pille(k.lifecycle_stage) + "</div>" +
      '<div class="detail-raster">' +
        '<section class="karte panel"><div class="panel-kopf"><h2>Timeline</h2><span class="leise">neueste zuerst</span></div>' + timeline(d.timeline) + "</section>" +
        '<div class="detail-seite">' +
          '<section class="karte panel"><div class="panel-kopf"><h2>Angaben</h2></div><form class="stammdaten" data-stammdaten>' +
            '<div class="reihe reihe--titel"><label class="feld">Titel<input name="titel" value="' + esc(k.titel) + '" placeholder="Dr."></label><label class="feld">Vorname<input name="vorname" value="' + esc(k.vorname) + '"></label></div>' +
            '<label class="feld">Nachname<input name="nachname" value="' + esc(k.nachname) + '"></label>' +
            '<label class="feld">Position<input name="position" value="' + esc(k.position) + '"></label>' +
            '<label class="feld">Telefon<input name="telefon" value="' + esc(k.telefon) + '"></label>' +
            '<div class="reihe"><label class="feld">Herkunft <small>Erstkontakt</small><select name="herkunft">' + opt(HERKUNFT, k.herkunft) + "</select></label>" +
              '<label class="feld">Tags <small>mit Komma trennen</small><input name="tags" value="' + esc((k.tags || []).join(", ")) + '" placeholder="linkedin_follower"></label></div>' +
            '<fieldset class="nl-feld"><legend>Newsletter</legend>' +
              '<label class="nl-schalter"><input type="checkbox" name="newsletter_erlaubt"' + (k.newsletter_erlaubt ? " checked" : "") + "> Darf den Newsletter bekommen</label>" +
              '<label class="feld" data-nl-grund' + (k.newsletter_erlaubt ? "" : " hidden") + '>Grundlage<select name="newsletter_grundlage">' + opt(GRUNDLAGE, k.newsletter_grundlage) + "</select></label>" +
              '<small class="leise">' + (k.newsletter_erlaubt && k.newsletter_seit ? "erlaubt seit " + datum(k.newsletter_seit) + " · " : "") + "Jede Änderung wird mit Datum und Person protokolliert.</small>" +
            "</fieldset>" +
            '<div class="reihe"><label class="feld">Status<select name="lifecycle_stage">' + opt(STATUS, k.lifecycle_stage) + '</select></label>' +
              '<label class="feld">Paketinteresse<select name="paketinteresse">' + opt(PAKET, k.paketinteresse) + "</select></label></div>" +
            '<div class="reihe"><label class="feld">Zielgruppe<input name="zielgruppe" value="' + esc(k.zielgruppe) + '" placeholder="z. B. Makler"></label>' +
              '<label class="feld">Zuständig<input name="owner" value="' + esc(k.owner) + '" placeholder="Noah / Daniel"></label></div>' +
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
            '<small class="leise">Entfernt die Person mit allen Besuchen, Terminen und Calls.</small></div>' +
        "</div>" +
      "</div>";
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

  function timeline(t) {
    if (!t.length) return '<p class="panel-leer">Noch keine Aktivität.</p>';
    return '<ol class="timeline">' + eintraege(t).map(function (x) { return x.art === "besuch" ? besuch(x) : einzeln(x.e); }).join("") + "</ol>";
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
    return '<li class="tl tl--besuch"><span class="tl-punkt"></span><div class="tl-inhalt">' +
      '<button type="button" class="tl-kopf" data-tl="' + esc(b.key) + '" aria-expanded="' + auf + '">' +
        '<span class="tl-zeit">' + zeit(b.start || b.zeit) + "</span>" +
        "<b>Website-Besuch</b> <span class=\"leise\">· " + seiten.length + (seiten.length === 1 ? " Seite" : " Seiten") + (lesezeit ? " · " + dauer(lesezeit) + " gelesen" : "") + (herkunft ? " · über " + esc(herkunft) : "") + "</span>" +
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
    var p = e.props || {}, titel, text = "", klasse = "";
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
      text = '<small class="leise">' + (p.nur_monat ? "seit " + new Date(e.zeit).toLocaleDateString("de-DE", { month: "long", year: "numeric" }) + " (laut Follower-Liste nur der Monat)" : "") + "</small>";
    }
    else if (e.event_name === "linkedin_reaction") {
      var arten = { like: "Gefällt mir", celebrate: "Applaus", support: "Unterstützung", love: "Liebe", insightful: "Interessant", funny: "Witzig" };
      titel = "LinkedIn: " + esc(arten[p.art] || "Reaktion") + " auf „" + esc(p.beitrag || "Beitrag") + "“";
      klasse = "tl--linkedin";
      text = esc((p.kanal === "daniel" ? "Beitrag von Daniel" : "Beitrag der Firmenseite") + (p.veroeffentlicht ? " vom " + new Date(p.veroeffentlicht).toLocaleDateString("de-DE") : "")) +
        (p.url ? ' · <a href="' + esc(p.url) + '" target="_blank" rel="noopener">Beitrag öffnen</a>' : "") +
        ' <small class="leise">Zeitpunkt = wann die Liste eingefügt wurde</small>';
    }
    else { titel = esc(e.event_name); }
    return '<li class="tl ' + klasse + '"><span class="tl-punkt"></span><div class="tl-inhalt"><div class="tl-kopf tl-kopf--fest"><span class="tl-zeit">' + zeit(e.zeit) + "</span><b>" + titel + "</b></div>" +
      (text ? '<div class="tl-text">' + text + "</div>" : "") + "</div></li>";
  }
  function antworten(a) {
    var z = Object.keys(a).map(function (k) { return "<dt>" + esc(k) + "</dt><dd>" + esc(typeof a[k] === "object" ? JSON.stringify(a[k]) : a[k]) + "</dd>"; });
    return z.length ? '<dl class="antworten">' + z.join("") + "</dl>" : "";
  }

  /* ---------- Bedienung ---------- */
  var suchTimer;
  wurzel.addEventListener("input", function (e) {
    if (!aktiv || !e.target.hasAttribute("data-k-suche")) return;
    clearTimeout(suchTimer);
    suchTimer = setTimeout(function () { Z.suche = e.target.value.trim(); listeLaden(); }, 300);
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv) return;
    if (e.target.hasAttribute("data-k-filter")) { Z.filter = e.target.value; return listeLaden(); }
    if (e.target.name === "newsletter_erlaubt") { var g = wurzel.querySelector("[data-nl-grund]"); if (g) g.hidden = !e.target.checked; return; }
    if (e.target.name !== "lifecycle_stage") return;
    var l = wurzel.querySelector("[data-lost]"); if (l) l.hidden = e.target.value !== "verloren";
  });
  function oeffneKontakt(tr) { C.oeffne("kontakte", tr.getAttribute("data-kontakt")); }
  wurzel.addEventListener("keydown", function (e) {
    if (!aktiv || e.key !== "Enter") return;
    var tr = e.target.closest && e.target.closest("tr[data-kontakt]"); if (tr) oeffneKontakt(tr);
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
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
    ["titel", "vorname", "nachname", "telefon", "position", "lifecycle_stage", "paketinteresse", "zielgruppe", "owner", "lost_grund", "notizen", "herkunft", "newsletter_grundlage"].forEach(function (n) { daten[n] = f.elements[n].value; });
    daten.tags = f.elements.tags.value.split(",").map(function (t) { return t.trim(); }).filter(Boolean);
    daten.newsletter_erlaubt = f.elements.newsletter_erlaubt.checked;
    if (daten.newsletter_erlaubt && !daten.newsletter_grundlage) { m.textContent = "Bitte die Grundlage für den Newsletter wählen."; return; }
    knopf.disabled = true; m.textContent = "";
    api("kontakt_speichern", { kontakt: daten }).then(function () {
      return detailLaden(daten.contact_id).then(function () { var mm = wurzel.querySelector("[data-k-meldung]"); if (mm) { mm.textContent = "Gespeichert."; mm.classList.add("ok"); } });
    }).catch(function (err) { knopf.disabled = false; m.textContent = err.message; });
  });

  C.module.kontakte = { start: start, stop: stop };
})();
