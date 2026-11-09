/* Cockpit · Calls – Gesprächsprotokolle hochladen und durchsuchen.
   Gleiche Funktionen wie die Calls-Seite im empiria-dashboard
   (assets/ss-calls.js dort), gleiche Datenbank, eigenes Aussehen. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { calls: [], suche: "", offen: null, detail: {}, form: null, termine: [], kontakte: [] };
  var aktiv = false;

  function markiert(s) { return esc(s).replace(/⟦/g, "<mark>").replace(/⟧/g, "</mark>"); }
  function datum(d) { return d ? new Date(d).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", year: "numeric" }) : "–"; }
  function zeit(d) { return d ? new Date(d).toLocaleString("de-DE", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : ""; }
  function lokal(d) { var x = d ? new Date(d) : new Date(); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 16); }
  function absaetze(t) { return String(t || "").split(/\n\s*\n/).map(function (a) { return a.trim() ? "<p>" + esc(a).replace(/\n/g, "<br>") + "</p>" : ""; }).join(""); }
  function name(k) { return [k.vorname, k.nachname].filter(Boolean).join(" "); }

  function fehler(e) { wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; }

  function start() {
    aktiv = true; Z.form = null;
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    liste().catch(fehler);
  }
  function liste() {
    return api("calls", { suche: Z.suche }).then(function (r) {
      Z.calls = r;
      if (!Z.suche) { var z = document.querySelector('[data-zahl="calls"]'); if (z) z.textContent = r.length || ""; }
      zeichnen();
    });
  }

  /* ---------- Darstellung ---------- */
  function zeichnen() {
    var fokus = document.activeElement && document.activeElement.hasAttribute("data-suche");
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Calls</h1><p class="leise">Gesprächsprotokolle aus ChatGPT – zentral abgelegt und durchsuchbar</p></div>' +
        (Z.form ? "" : '<button type="button" class="knopf knopf--primaer" data-neu>+ Protokoll hochladen</button>') + "</div>" +
      (Z.form ? formular() :
        '<div class="leiste"><input type="search" class="suche" data-suche placeholder="In allen Gesprächen suchen – z. B. Bestandsübertragung" value="' + esc(Z.suche) + '"></div>' +
        '<p class="zahlzeile">' + (Z.suche ? Z.calls.length + " Treffer" : Z.calls.length + (Z.calls.length === 1 ? " Gespräch" : " Gespräche")) + "</p>" +
        (Z.calls.length ? '<ul class="calls karte">' + Z.calls.map(zeile).join("") + "</ul>"
          : '<div class="karte leer">' + (Z.suche ? "Nichts gefunden." : "Noch keine Gespräche abgelegt.") + "</div>"));
    if (fokus) { var f = wurzel.querySelector("[data-suche]"); if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } }
  }

  function zeile(c) {
    var auf = Z.offen === c.call_id, d = Z.detail[c.call_id];
    return '<li class="call' + (auf ? " call--auf" : "") + '">' +
      '<button type="button" class="call-kopf" data-auf="' + c.call_id + '" aria-expanded="' + auf + '">' +
        '<span class="call-datum">' + datum(c.stattgefunden_am) + "</span>" +
        '<span class="call-wer"><b>' + esc(c.titel || "Gespräch") + "</b><small>" + esc(c.name || c.email || "ohne Kontakt") + "</small>" +
          (Z.suche && c.ausschnitt ? '<small class="ausschnitt">… ' + markiert(c.ausschnitt) + " …</small>"
           : c.zusammenfassung ? '<small class="ausschnitt">' + esc(c.zusammenfassung) + "</small>" : "") +
        "</span>" +
        '<span class="pille">' + esc((c.hochgeladen_von || "").split("@")[0]) + "</span>" +
      "</button>" +
      (auf ? '<div class="call-det">' + (d ? detail(d) : '<p class="meta">Lädt …</p>') + "</div>" : "") +
      "</li>";
  }

  function detail(d) {
    return '<p class="meta">' + esc(zeit(d.stattgefunden_am)) + (d.email ? ' · <a href="mailto:' + esc(d.email) + '">' + esc(d.email) + "</a>" : "") +
        " · hochgeladen von " + esc(d.hochgeladen_von) + "</p>" +
      (d.zusammenfassung ? '<div class="block"><p class="flabel">Zusammenfassung</p>' + absaetze(d.zusammenfassung) + "</div>" : "") +
      '<details class="transkript"' + (d.zusammenfassung ? "" : " open") + "><summary>Transkript · " + d.transkript.length.toLocaleString("de-DE") + " Zeichen</summary>" + absaetze(d.transkript) + "</details>" +
      '<div class="knoepfe"><button type="button" class="knopf" data-bearbeiten="' + d.call_id + '">Bearbeiten</button>' +
        '<button type="button" class="knopf knopf--gefahr" data-loeschen="' + d.call_id + '">Löschen</button></div>';
  }

  /* ---------- Formular ---------- */
  function neuesFormular(vorlage) {
    Z.form = vorlage || { modus: "termin", booking_uid: "", contact_id: "", email: "", vorname: "", nachname: "", kontaktName: "",
      stattgefunden_am: lokal(), titel: "", transkript: "", zusammenfassung: "", aufnahme_zugestimmt: false };
    zeichnen();
    if (Z.form.modus === "termin") termineLaden();
  }
  function termineLaden() { api("termine").then(function (r) { Z.termine = r; if (Z.form && aktiv) zeichnen(); }).catch(function () {}); }
  function kontaktTreffer(r) {
    return r.map(function (k) {
      var n = name(k);
      return '<li><button type="button" data-kontakt="' + k.contact_id + '" data-name="' + esc(n || k.email) + '"><b>' + esc(n || k.email) + "</b><small>" + esc(n ? k.email || "" : "") + "</small></button></li>";
    }).join("") || '<li class="meta">Kein Treffer – „Neuer Kontakt“ wählen.</li>';
  }

  function formular() {
    var f = Z.form, feld = "";
    if (f.modus === "termin") {
      feld = !Z.termine.length ? '<p class="meta">Keine Cal.com-Termine in den letzten 14 Tagen.</p>' :
        '<ul class="termine">' + Z.termine.map(function (t) {
          return '<li><button type="button" class="termin' + (f.booking_uid === t.booking_uid ? " termin--gew" : "") + '" data-termin="' + esc(t.booking_uid) + '"' + (t.abgesagt ? " disabled" : "") + ">" +
            '<span class="termin-zeit">' + esc(zeit(t.termin_start)) + "</span>" +
            "<span><b>" + esc(t.name || t.email) + "</b><small>" + esc([t.unternehmen, t.titel].filter(Boolean).join(" · ")) + "</small></span>" +
            (t.abgesagt ? '<span class="pille">abgesagt</span>' : t.call_id ? '<span class="pille pille--gut">Protokoll vorhanden</span>' : "<span></span>") +
            "</button></li>";
        }).join("") + "</ul>";
    } else if (f.modus === "kontakt") {
      feld = f.contact_id ? '<p class="gewaehlt">' + esc(f.kontaktName) + ' <button type="button" data-kontakt-weg>ändern</button></p>' :
        '<input type="search" class="suche" data-kontakt-suche placeholder="Name oder E-Mail" autocomplete="off"><ul class="treffer">' + kontaktTreffer(Z.kontakte) + "</ul>";
    } else if (f.modus === "neu") {
      feld = '<div class="reihe"><label class="feld">Vorname<input data-f="vorname" value="' + esc(f.vorname) + '"></label>' +
        '<label class="feld">Nachname<input data-f="nachname" value="' + esc(f.nachname) + '"></label></div>' +
        '<label class="feld">E-Mail<input type="email" data-f="email" value="' + esc(f.email) + '" placeholder="Pflicht – darüber wird der Kontakt erkannt"></label>';
    }
    var modi = '<div class="seg" role="group" aria-label="Zuordnung">' + ["termin", "kontakt", "neu"].map(function (m) {
      return '<button type="button" data-modus="' + m + '" aria-pressed="' + (f.modus === m) + '">' + { termin: "Termin aus Cal.com", kontakt: "Bestehender Kontakt", neu: "Neuer Kontakt" }[m] + "</button>";
    }).join("") + "</div>";

    return '<div class="karte form">' +
      '<div class="form-kopf"><h2>' + (f.call_id ? "Protokoll bearbeiten" : "Protokoll hochladen") + '</h2><button type="button" class="knopf" data-abbrechen>Abbrechen</button></div>' +
      (f.call_id ? "" : '<div class="schritt"><span class="flabel">Mit wem?</span>' + modi + feld + "</div>") +
      '<div class="reihe"><label class="feld">Wann<input type="datetime-local" data-f="stattgefunden_am" value="' + esc(f.stattgefunden_am) + '"></label>' +
        '<label class="feld">Titel<input data-f="titel" value="' + esc(f.titel) + '" placeholder="z. B. Kennenlernen"></label></div>' +
      '<label class="feld">Transkript<small>Aus ChatGPT kopieren und einfügen – oder eine Textdatei wählen</small><textarea data-f="transkript" rows="10">' + esc(f.transkript) + "</textarea></label>" +
      '<label class="datei"><input type="file" accept=".txt,.md,.vtt,.srt,text/plain" data-datei><span>Textdatei wählen (.txt, .md)</span></label>' +
      '<label class="feld">Zusammenfassung<small>Optional – die Zusammenfassung von ChatGPT</small><textarea data-f="zusammenfassung" rows="5">' + esc(f.zusammenfassung) + "</textarea></label>" +
      (f.call_id ? "" : '<label class="zustimmung"><input type="checkbox" data-f="aufnahme_zugestimmt"' + (f.aufnahme_zugestimmt ? " checked" : "") + "> Alle Teilnehmer haben der Aufnahme zugestimmt.</label>") +
      '<p class="fehler" data-fehler></p>' +
      '<div class="knoepfe"><button type="button" class="knopf knopf--primaer" data-speichern>Speichern</button></div>' +
      "</div>";
  }

  function formFehler(t) { var p = wurzel.querySelector("[data-fehler]"); if (p) p.textContent = t; }

  function speichern() {
    var f = Z.form;
    if (!f.transkript.trim()) return formFehler("Bitte das Transkript einfügen.");
    if (!f.call_id && !f.aufnahme_zugestimmt) return formFehler("Bitte bestätigen, dass alle der Aufnahme zugestimmt haben.");
    if (!f.call_id && f.modus === "termin" && !f.booking_uid) return formFehler("Bitte einen Termin wählen.");
    if (!f.call_id && f.modus === "kontakt" && !f.contact_id) return formFehler("Bitte einen Kontakt wählen.");
    if (!f.call_id && f.modus === "neu" && f.email.indexOf("@") < 0) return formFehler("Bitte eine E-Mail-Adresse angeben.");
    var knopf = wurzel.querySelector("[data-speichern]"); knopf.disabled = true; knopf.textContent = "Speichert …";
    var bestand = !!f.call_id;
    api("speichern", { call: {
      call_id: f.call_id || null,
      booking_uid: f.modus === "termin" || bestand ? f.booking_uid : "",
      contact_id: f.modus === "kontakt" || bestand ? f.contact_id : "",
      email: f.modus === "neu" ? f.email : "", vorname: f.modus === "neu" ? f.vorname : "", nachname: f.modus === "neu" ? f.nachname : "",
      stattgefunden_am: f.stattgefunden_am ? new Date(f.stattgefunden_am).toISOString() : null,
      titel: f.titel, transkript: f.transkript, zusammenfassung: f.zusammenfassung,
      aufnahme_zugestimmt: true   // beim Bearbeiten bereits bestätigt; die Datenbank lässt nichts anderes zu
    } }).then(function (id) {
      Z.form = null; delete Z.detail[id]; Z.suche = "";
      return liste().then(function () { oeffnen(id); });
    }).catch(function (e) { knopf.disabled = false; knopf.textContent = "Speichern"; formFehler(e.message); });
  }

  function oeffnen(id) {
    Z.offen = id; zeichnen();
    if (!Z.detail[id]) api("call", { call_id: id }).then(function (d) { Z.detail[id] = d; if (Z.offen === id) zeichnen(); }).catch(fehler);
  }

  /* ---------- Bedienung ---------- */
  var suchTimer, kontaktTimer;
  wurzel.addEventListener("input", function (e) {
    if (!aktiv) return;
    var el = e.target;
    if (el.hasAttribute("data-suche")) {
      clearTimeout(suchTimer);
      suchTimer = setTimeout(function () { Z.suche = el.value.trim(); Z.offen = null; liste().catch(fehler); }, 300);
      return;
    }
    if (el.hasAttribute("data-kontakt-suche")) {
      clearTimeout(kontaktTimer);
      kontaktTimer = setTimeout(function () {
        api("kontakte", { suche: el.value.trim() }).then(function (r) {
          Z.kontakte = r; var ul = wurzel.querySelector(".treffer"); if (ul) ul.innerHTML = kontaktTreffer(r);
        }).catch(function () {});
      }, 250);
      return;
    }
    var f = el.getAttribute("data-f");
    if (f && Z.form) Z.form[f] = el.type === "checkbox" ? el.checked : el.value;
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv) return;
    var el = e.target;
    if (el.getAttribute("data-f") === "aufnahme_zugestimmt" && Z.form) Z.form.aufnahme_zugestimmt = el.checked;
    if (el.hasAttribute("data-datei") && el.files && el.files[0]) {
      var r = new FileReader();
      r.onload = function () { Z.form.transkript = String(r.result); var ta = wurzel.querySelector('[data-f="transkript"]'); if (ta) ta.value = Z.form.transkript; };
      r.readAsText(el.files[0]);
    }
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var b = e.target.closest("button"); if (!b) return;
    if (b.hasAttribute("data-neu")) return neuesFormular();
    if (b.hasAttribute("data-abbrechen")) { Z.form = null; return zeichnen(); }
    if (b.hasAttribute("data-speichern")) return speichern();
    if (b.hasAttribute("data-modus")) {
      Z.form.modus = b.getAttribute("data-modus"); zeichnen();
      if (Z.form.modus === "kontakt" && !Z.form.contact_id) {
        var s = wurzel.querySelector("[data-kontakt-suche]"); if (s) s.focus();
        api("kontakte", { suche: "" }).then(function (r) { Z.kontakte = r; var ul = wurzel.querySelector(".treffer"); if (ul) ul.innerHTML = kontaktTreffer(r); }).catch(function () {});
      }
      if (Z.form.modus === "termin" && !Z.termine.length) termineLaden();
      return;
    }
    if (b.hasAttribute("data-termin")) {
      var t = Z.termine.filter(function (x) { return x.booking_uid === b.getAttribute("data-termin"); })[0]; if (!t) return;
      Z.form.booking_uid = t.booking_uid; Z.form.stattgefunden_am = lokal(t.termin_start);
      if (!Z.form.titel) Z.form.titel = [t.titel ? t.titel.split(/ (?:zwischen|between|mit|sofort sichtbar|&) /i)[0] : "Gespräch", t.name].filter(Boolean).join(" – ");
      return zeichnen();
    }
    if (b.hasAttribute("data-kontakt")) { Z.form.contact_id = b.getAttribute("data-kontakt"); Z.form.kontaktName = b.getAttribute("data-name"); return zeichnen(); }
    if (b.hasAttribute("data-kontakt-weg")) { Z.form.contact_id = ""; Z.form.kontaktName = ""; return zeichnen(); }
    if (b.hasAttribute("data-auf")) {
      var id = b.getAttribute("data-auf");
      if (Z.offen === id) { Z.offen = null; return zeichnen(); }
      return oeffnen(id);
    }
    if (b.hasAttribute("data-bearbeiten")) {
      var d = Z.detail[b.getAttribute("data-bearbeiten")];
      return neuesFormular({ call_id: d.call_id, modus: "bestand", booking_uid: d.booking_uid || "", contact_id: d.contact_id || "",
        stattgefunden_am: lokal(d.stattgefunden_am), titel: d.titel || "", transkript: d.transkript, zusammenfassung: d.zusammenfassung || "", aufnahme_zugestimmt: true });
    }
    if (b.hasAttribute("data-loeschen")) {
      if (!confirm("Dieses Gesprächsprotokoll endgültig löschen?")) return;
      var lid = b.getAttribute("data-loeschen");
      api("loeschen", { call_id: lid }).then(function () { delete Z.detail[lid]; Z.offen = null; return liste(); }).catch(fehler);
    }
  });

  C.module.calls = { start: start };
})();
