/* Cockpit · Newsletter – verfassen, testen, senden, auswerten; Listen hochladen.
   Absender ist Daniel (über Amazon SES). Empfänger sind nur Kontakte mit
   Newsletter-Erlaubnis. Vorschau und Versand nutzen denselben Renderer
   (nl-render.js), die Vorschau zeigt also genau die verschickte Mail. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main, R = window.nlRender;
  var Z = { ansicht: "uebersicht", daten: null, nl: null, detail: null, zielgruppe: null, beispielAn: true, breite: "desktop",
            liste: { text: "", name: "", grundlage: "", bestaetigt: false, erkannt: null, meldung: "" }, test: "", meldung: "" };
  var aktiv = false, timer = null, zgTimer = null, vorschauTimer = null;

  var STATUS = { entwurf: "Entwurf", wird_gesendet: "Wird gesendet", gesendet: "Gesendet", abgebrochen: "Abgebrochen" };
  var EMPF = { wartet: "wartet", in_arbeit: "wird gesendet", gesendet: "gesendet", zugestellt: "zugestellt", fehler: "Fehler",
               bounce: "unzustellbar", beschwerde: "Spam-Beschwerde", uebersprungen: "übersprungen" };
  var VORLAGE = "{{anrede}},\n\n# Überschrift\n\nHier steht der erste Absatz. **Wichtiges fett**, Links so: [unsere Preise](https://sofortsichtbar.de/pricing).\n\n" +
    "- erster Punkt\n- zweiter Punkt\n\n[[Termin buchen | https://sofortsichtbar.de/kontakt]]\n\nViele Grüße\nDaniel Ströbel\nsofort sichtbar";

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function quote(a, b) { return b ? Math.round((a / b) * 100) + " %" : "–"; }
  function wann(d) { return d ? new Date(d).toLocaleString("de-DE", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }) : "–"; }
  function kachel(t, w, h) { return '<div class="kachel karte"><span class="flabel">' + esc(t) + '</span><b class="kachel-wert">' + w + "</b>" + (h ? "<small>" + esc(h) + "</small>" : "") + "</div>"; }
  function fehler(e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; }
  function konto() { var k = document.querySelector("[data-konto]"); return k ? k.textContent.trim() : ""; }

  function start(arg) {
    aktiv = true; clearInterval(timer);
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    if (!arg) return uebersicht();
    if (arg === "liste") return listeAnsicht();
    if (arg === "neu") { Z.nl = neuerEntwurf(); Z.detail = null; Z.meldung = ""; return api("newsletter_uebersicht", {}).then(function (d) { Z.daten = d; editor(); }).catch(fehler); }
    oeffnen(arg);
  }
  function stop() { aktiv = false; clearInterval(timer); }

  function neuerEntwurf() {
    return { newsletter_id: null, titel: "", betreff: "", vorschautext: "", inhalt: VORLAGE, listen: [], klicks_messen: true, utm: true, utm_kampagne: "", status: "entwurf" };
  }

  /* ---------- Versandstatus ---------- */
  function statusZeile(s) {
    if (!s) return '<span class="status status--aus"><i></i>Versand noch nicht eingerichtet: SES-Zugang fehlt (scripts/ses-einrichten.sh)</span>';
    if (s.fehler) return '<span class="status status--fehler" title="' + esc(s.fehler) + '"><i></i>SES nicht erreichbar · ' + wann(s.geprueft) + "</span>";
    if (!s.produktion) return '<span class="status status--aus"><i></i>SES im Testmodus: nur an bestätigte Adressen, bis AWS den Produktionszugriff freigibt</span>';
    return '<span class="status status--ok"><i></i>Versand freigegeben · ' + zahl(s.gesendet_24h) + " von " + zahl(s.max_24h) + " Mails in 24 h genutzt</span>";
  }

  /* ---------- Übersicht ---------- */
  function uebersicht() {
    Z.ansicht = "uebersicht";
    return api("newsletter_uebersicht", {}).then(function (d) {
      Z.daten = d; if (!aktiv) return;
      wurzel.innerHTML =
        '<div class="kopf"><div><h1>Newsletter</h1><p class="leise">Absender Daniel Ströbel · nur an Kontakte mit Newsletter-Erlaubnis</p></div>' +
          '<div class="knoepfe"><a class="knopf" href="#newsletter/liste">Liste hochladen</a><a class="knopf knopf--primaer" href="#newsletter/neu">Neuer Newsletter</a></div></div>' +
        '<div class="statusleiste">' + statusZeile(d.status) + "</div>" +
        '<section class="karte panel"><div class="panel-kopf"><h2>Newsletter</h2></div>' +
          (d.newsletter.length ? '<div class="tabelle-scroll"><table class="tabelle tabelle--klick"><thead><tr><th>Newsletter</th><th>Status</th><th class="n">Empfänger</th><th class="n">Klicker</th><th class="n">Abmeldungen</th><th>Datum</th></tr></thead><tbody>' +
            d.newsletter.map(function (n) {
              return '<tr data-nl="' + n.newsletter_id + '" tabindex="0"><td><b>' + esc(n.titel) + '</b><small class="leise li-position">' + esc(n.betreff || "ohne Betreff") + "</small></td>" +
                '<td><span class="pille' + (n.status === "gesendet" ? " pille--gut" : n.status === "wird_gesendet" ? " pille--mql" : "") + '">' + STATUS[n.status] + "</span></td>" +
                '<td class="n">' + (n.status === "entwurf" ? "–" : zahl(n.empfaenger)) + '</td><td class="n">' + (n.status === "entwurf" ? "–" : zahl(n.klicker) + ' <small class="leise">' + quote(n.klicker, n.versendet) + "</small>") +
                '</td><td class="n">' + (n.status === "entwurf" ? "–" : zahl(n.abmeldungen)) + "</td><td>" + wann(n.gesendet_am || n.freigegeben_am || n.updated_at) + "</td></tr>";
            }).join("") + "</tbody></table></div>"
            : '<p class="panel-leer">Noch kein Newsletter. Oben rechts „Neuer Newsletter“.</p>') + "</section>" +
        '<section class="karte panel"><div class="panel-kopf"><h2>Empfänger</h2><span class="leise">' + zahl(d.erlaubt_gesamt) + " Kontakte mit Newsletter-Erlaubnis · " +
          zahl(d.gesperrt) + " gesperrt (abgemeldet, unzustellbar, Beschwerde)</span></div>" +
          (d.listen.length ? '<table class="tabelle"><thead><tr><th>Liste (Tag)</th><th class="n">Kontakte</th><th class="n">mit Erlaubnis</th></tr></thead><tbody>' +
            d.listen.map(function (l) { return "<tr><td>" + esc(l.liste) + '</td><td class="n">' + zahl(l.kontakte) + '</td><td class="n">' + zahl(l.erlaubt) + "</td></tr>"; }).join("") + "</tbody></table>"
            : '<p class="panel-leer">Noch keine Listen.</p>') + "</section>";
    }).catch(fehler);
  }

  function oeffnen(id) {
    return api("newsletter", { newsletter_id: id }).then(function (d) {
      if (!aktiv) return;
      if (!d) { wurzel.innerHTML = '<div class="karte leer">Newsletter nicht gefunden. <a href="#newsletter">Zur Übersicht</a></div>'; return; }
      Z.detail = d; Z.nl = d.newsletter;
      if (Z.nl.status === "entwurf") return api("newsletter_uebersicht", {}).then(function (u) { Z.daten = u; editor(); });
      auswertung();
    }).catch(fehler);
  }

  /* ---------- Editor ---------- */
  function editor() {
    Z.ansicht = "editor";
    var n = Z.nl, listen = (Z.daten && Z.daten.listen) || [];
    if (!Z.test) Z.test = konto();
    wurzel.innerHTML =
      '<p class="zurueck"><a href="#newsletter">← Alle Newsletter</a></p>' +
      '<div class="kopf"><div><h1>' + esc(n.titel || "Neuer Newsletter") + '</h1><p class="leise">Entwurf' + (n.updated_at ? " · gespeichert " + wann(n.updated_at) : " · noch nicht gespeichert") + "</p></div>" +
        '<div class="statusleiste nl-status">' + statusZeile(Z.daten && Z.daten.status) + "</div></div>" +
      '<div class="nl-raster">' +
        '<div class="nl-links">' +
          '<section class="karte panel"><div class="panel-kopf"><h2>Mail</h2></div>' +
            '<label class="feld">Interner Titel <small>nur im Cockpit sichtbar</small><input data-f="titel" value="' + esc(n.titel) + '" placeholder="z. B. Newsletter November"></label>' +
            '<label class="feld">Betreff<input data-f="betreff" value="' + esc(n.betreff) + '" maxlength="300" placeholder="z. B. {{vorname|Hallo}}, drei Ideen für mehr Sichtbarkeit"></label>' +
            '<label class="feld">Vorschauzeile <small>erscheint im Posteingang hinter dem Betreff</small><input data-f="vorschautext" value="' + esc(n.vorschautext) + '" maxlength="300"></label>' +
          "</section>" +
          '<section class="karte panel"><div class="panel-kopf"><h2>Inhalt</h2><span class="leise">Vorschau rechts aktualisiert sich beim Tippen</span></div>' +
            '<div class="nl-werkzeug" role="toolbar" aria-label="Formatieren">' +
              '<button type="button" data-w="h1" title="Überschrift">Überschrift</button><button type="button" data-w="h2" title="Zwischenüberschrift">Zwischen­überschrift</button>' +
              '<button type="button" data-w="fett"><b>F</b></button><button type="button" data-w="kursiv"><i>K</i></button>' +
              '<button type="button" data-w="link">Link</button><button type="button" data-w="button">Button</button>' +
              '<button type="button" data-w="liste">Liste</button><button type="button" data-w="linie">Linie</button>' +
              '<select data-platzhalter aria-label="Platzhalter einfügen"><option value="">Platzhalter …</option>' +
                [["anrede", "Anrede (Hallo Max / Hallo zusammen)"], ["vorname|", "Vorname"], ["nachname", "Nachname"], ["name", "Vor- und Nachname"], ["titel", "Titel"], ["firma", "Firma"], ["position", "Position"]]
                  .map(function (p) { return '<option value="' + p[0] + '">' + esc(p[1]) + "</option>"; }).join("") + "</select>" +
            "</div>" +
            '<textarea class="nl-text" data-f="inhalt" rows="20" spellcheck="true">' + esc(n.inhalt) + "</textarea>" +
            '<details class="nl-hilfe"><summary>So funktioniert die Formatierung</summary><ul>' +
              "<li><code># Text</code> Überschrift, <code>## Text</code> Zwischenüberschrift</li><li>Leerzeile = neuer Absatz</li>" +
              "<li><code>**fett**</code>, <code>*kursiv*</code>, <code>[Linktext](https://…)</code></li><li><code>[[Button-Text | https://…]]</code> großer Button</li>" +
              "<li><code>- Punkt</code> Aufzählung, <code>---</code> Trennlinie</li>" +
              "<li><code>{{vorname}}</code> usw. werden je Empfänger ersetzt; <code>{{vorname|zusammen}}</code> setzt „zusammen“ ein, wenn der Vorname fehlt</li>" +
              "<li>Abmeldelink und Impressum stehen automatisch unter jeder Mail</li></ul></details>" +
          "</section>" +
          '<section class="karte panel"><div class="panel-kopf"><h2>Zielgruppe</h2><span class="leise" data-zg>…</span></div>' +
            (listen.length ? '<div class="nl-listen">' + listen.map(function (l) {
              return '<label class="nl-liste' + (l.erlaubt ? "" : " nl-liste--leer") + '"><input type="checkbox" data-liste="' + esc(l.liste) + '"' + (n.listen.indexOf(l.liste) >= 0 ? " checked" : "") + (l.erlaubt ? "" : " disabled") + "> " +
                esc(l.liste) + ' <small class="leise">' + zahl(l.erlaubt) + "</small></label>";
            }).join("") + "</div>" : "") +
            '<p class="leise nl-klein">Keine Liste gewählt = alle Kontakte mit Newsletter-Erlaubnis. Kontakte ohne Erlaubnis oder auf der Sperrliste bekommen nie etwas.</p>' +
          "</section>" +
          '<section class="karte panel"><div class="panel-kopf"><h2>Messung</h2></div>' +
            '<label class="nl-schalter"><input type="checkbox" data-f="klicks_messen"' + (n.klicks_messen ? " checked" : "") + "> Klicks pro Person messen <small class=\"leise\">über sofortsichtbar.de/n/… – Klicks landen als Signal in der Kontakt-Timeline</small></label>" +
            '<label class="nl-schalter"><input type="checkbox" data-f="utm"' + (n.utm ? " checked" : "") + "> UTM-Parameter an Links zu sofortsichtbar.de <small class=\"leise\">Website-Besuche werden dem Newsletter zugeordnet</small></label>" +
            '<label class="feld nl-kampagne"' + (n.utm ? "" : " hidden") + '>Kampagnenname (utm_campaign)<input data-f="utm_kampagne" value="' + esc(n.utm_kampagne || "") + '" placeholder="' + esc(R.slug(n.titel || "newsletter")) + '"></label>' +
            '<label class="nl-schalter nl-aus"><input type="checkbox" disabled> Öffnungen messen <small class="leise">aus – ein Zählpixel bräuchte eine Einwilligung (§ 25 TDDDG)</small></label>' +
          "</section>" +
          '<section class="karte panel"><div class="panel-kopf"><h2>Testen und senden</h2></div>' +
            '<div class="nl-test"><label class="feld">Test an <small>bis zu 5 Adressen, mit Komma getrennt</small><input data-test value="' + esc(Z.test) + '"></label>' +
              '<button type="button" class="knopf" data-aktion="test">Test senden</button></div>' +
            (Z.detail && Z.detail.tests && Z.detail.tests.length ? '<ul class="nl-tests">' + Z.detail.tests.map(function (t) {
              return "<li>" + esc(t.email) + ' · <span class="' + (t.status === "fehler" ? "li-warnung" : "leise") + '">' + esc(EMPF[t.status] || t.status) + (t.fehler ? ": " + esc(t.fehler.slice(0, 160)) : "") + "</span> · " + wann(t.zeit) + "</li>";
            }).join("") + "</ul>" : "") +
            '<p class="fehler" data-meldung>' + esc(Z.meldung) + "</p>" +
            '<div class="knoepfe"><button type="button" class="knopf" data-aktion="speichern">Speichern</button>' +
              '<button type="button" class="knopf knopf--primaer" data-aktion="senden-frage">Senden …</button>' +
              (n.newsletter_id ? '<button type="button" class="knopf knopf--gefahr" data-aktion="loeschen">Entwurf löschen</button>' : "") + "</div>" +
            '<div class="nl-bestaetigen" data-bestaetigen hidden></div>' +
          "</section>" +
        "</div>" +
        '<div class="nl-rechts"><section class="karte panel nl-vorschau-karte"><div class="panel-kopf"><h2>Vorschau</h2>' +
          '<div class="seg" role="group" aria-label="Breite"><button type="button" data-breite="desktop" aria-pressed="' + (Z.breite === "desktop") + '">Desktop</button><button type="button" data-breite="mobil" aria-pressed="' + (Z.breite === "mobil") + '">Handy</button></div>' +
          '<div class="seg" role="group" aria-label="Daten"><button type="button" data-bsp="1" aria-pressed="' + Z.beispielAn + '">mit Beispielkontakt</button><button type="button" data-bsp="0" aria-pressed="' + !Z.beispielAn + '">ohne Namen</button></div></div>' +
          '<div class="nl-postfach" data-postfach></div>' +
          '<div class="nl-rahmen nl-rahmen--' + Z.breite + '"><iframe title="Vorschau der Mail" data-vorschau sandbox="allow-popups allow-popups-to-escape-sandbox"></iframe></div>' +
          '<p class="leise nl-klein" data-links></p>' +
        "</section></div>" +
      "</div>";
    vorschau(); zielgruppe();
  }

  function felder() {
    var n = Z.nl;
    wurzel.querySelectorAll("[data-f]").forEach(function (el) {
      var f = el.getAttribute("data-f");
      n[f] = el.type === "checkbox" ? el.checked : el.value;
    });
    n.listen = [].slice.call(wurzel.querySelectorAll("[data-liste]:checked")).map(function (el) { return el.getAttribute("data-liste"); });
    var t = wurzel.querySelector("[data-test]"); if (t) Z.test = t.value;
  }

  function beispiel() {
    if (!Z.beispielAn) return {};
    return (Z.zielgruppe && Z.zielgruppe.beispiel) || { vorname: "Max", nachname: "Mustermann", firma: "Muster Versicherungsmakler GmbH", position: "Geschäftsführer" };
  }
  function vorschau() {
    var n = Z.nl, r = R.render(n, beispiel(), {});
    var f = wurzel.querySelector("[data-vorschau]"); if (f) f.srcdoc = r.html;
    var p = wurzel.querySelector("[data-postfach]");
    if (p) p.innerHTML = '<b>Daniel Ströbel</b> <span class="leise">&lt;daniel.stroebel@sofortsichtbar.de&gt;</span><br><span>' + esc(r.betreff || "(kein Betreff)") + '</span> <span class="leise">– ' + esc(R.platzhalter(n.vorschautext || "", {}) || "") + "</span>";
    var l = wurzel.querySelector("[data-links]");
    if (l) l.textContent = r.links.length ? r.links.length + (r.links.length === 1 ? " Link" : " Links") + (n.klicks_messen ? " – Klicks werden je Person gemessen" : " – ohne Klickmessung") : "Keine Links im Inhalt.";
  }
  function zielgruppe() {
    var el = wurzel.querySelector("[data-zg]"); if (el) el.textContent = "…";
    return api("newsletter_zielgruppe", { listen: Z.nl.listen }).then(function (z) {
      Z.zielgruppe = z;
      var e = wurzel.querySelector("[data-zg]"); if (e) e.textContent = zahl(z.anzahl) + (z.anzahl === 1 ? " Empfänger" : " Empfänger");
      vorschau();
    }).catch(function () {});
  }

  function speichern() {
    felder();
    var m = wurzel.querySelector("[data-meldung]");
    return api("newsletter_speichern", { newsletter: Z.nl }).then(function (id) {
      var neu = !Z.nl.newsletter_id;
      Z.nl.newsletter_id = id; Z.nl.updated_at = new Date().toISOString();
      if (neu) history.replaceState(null, "", "#newsletter/" + id);
      if (m) { m.textContent = "Gespeichert."; m.classList.add("ok"); }
      return id;
    }).catch(function (e) { if (m) { m.textContent = e.message; m.classList.remove("ok"); } throw e; });
  }

  function einfuegen(vor, nach, platz) {
    var ta = wurzel.querySelector("[data-f=inhalt]"); if (!ta) return;
    var a = ta.selectionStart, b = ta.selectionEnd, auswahl = b > a, sel = ta.value.slice(a, b) || platz || "";
    ta.value = ta.value.slice(0, a) + vor + sel + nach + ta.value.slice(b);
    ta.focus();
    if (auswahl) { ta.selectionStart = ta.selectionEnd = a + vor.length + sel.length + nach.length; }   // markierter Text: Cursor dahinter
    else { ta.selectionStart = a + vor.length; ta.selectionEnd = a + vor.length + sel.length; }         // Platzhaltertext markieren zum Überschreiben
    ta.dispatchEvent(new Event("input", { bubbles: true }));
  }
  function ansEnde() { var ta = wurzel.querySelector("[data-f=inhalt]"); if (ta) ta.selectionStart = ta.selectionEnd; }
  function block(text) {
    var ta = wurzel.querySelector("[data-f=inhalt]"); if (!ta) return;
    ansEnde();
    var a = ta.selectionStart, v = ta.value.slice(0, a), vorlauf = !v || /\n\n$/.test(v) ? "" : /\n$/.test(v) ? "\n" : "\n\n";
    einfuegen(vorlauf + text + "\n\n", "", "");
  }

  /* ---------- Auswertung ---------- */
  function auswertung() {
    Z.ansicht = "auswertung";
    var d = Z.detail, n = d.newsletter, z = d.zahlen;
    var laeuft = n.status === "wird_gesendet";
    wurzel.innerHTML =
      '<p class="zurueck"><a href="#newsletter">← Alle Newsletter</a></p>' +
      '<div class="kopf"><div><h1>' + esc(n.titel) + '</h1><p class="leise">' + esc(STATUS[n.status]) + " · Betreff „" + esc(n.betreff) + "“ · freigegeben " + wann(n.freigegeben_am) +
        (n.freigegeben_von ? " von " + esc(n.freigegeben_von) : "") + (n.gesendet_am ? " · fertig " + wann(n.gesendet_am) : "") + "</p></div>" +
        (laeuft ? '<button type="button" class="knopf knopf--gefahr" data-aktion="abbrechen">Versand stoppen</button>' : "") + "</div>" +
      (laeuft ? '<div class="statusleiste"><span class="status status--ok"><i></i>' + zahl(z.wartet) + " von " + zahl(z.empfaenger) + " noch in der Warteschlange · aktualisiert sich alle 10 Sekunden</span></div>" : "") +
      '<div class="kacheln">' +
        kachel("Empfänger", zahl(z.empfaenger)) +
        kachel("Versendet", zahl(z.versendet), z.fehler ? zahl(z.fehler) + " mit Fehler" : "") +
        kachel("Zugestellt", zahl(z.zugestellt), z.versendet ? quote(z.zugestellt, z.versendet) + " der versendeten" : "") +
        kachel("Klicker", zahl(z.klicker), quote(z.klicker, z.versendet) + " · " + zahl(z.klicks) + " Klicks") +
        kachel("Abmeldungen", zahl(z.abmeldungen), quote(z.abmeldungen, z.versendet)) +
        kachel("Unzustellbar", zahl(z.bounces), z.beschwerden ? zahl(z.beschwerden) + " Spam-Beschwerden" : "keine Beschwerden") +
      "</div>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Links</h2><span class="leise">' + (n.klicks_messen ? "Klicks ohne Link-Scanner der Mailprogramme" : "Klickmessung war aus") + "</span></div>" +
        (d.links.length ? '<div class="tabelle-scroll"><table class="tabelle"><thead><tr><th>Ziel</th><th class="n">Personen</th><th class="n">Klicks</th></tr></thead><tbody>' +
          d.links.map(function (l) { return '<tr><td><span class="pfad">' + esc(l.url.replace(/[?&]utm_[^&#]*/g, "").replace(/\?$/, "")) + '</span></td><td class="n">' + zahl(l.personen) + '</td><td class="n">' + zahl(l.klicks) + "</td></tr>"; }).join("") +
          "</tbody></table></div>" : '<p class="panel-leer">Keine Links.</p>') + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Empfänger</h2><span class="leise">wer geklickt hat, steht oben</span></div>' +
        '<div class="tabelle-scroll"><table class="tabelle"><thead><tr><th>Person</th><th>Status</th><th class="n">Klicks</th><th>Gesendet</th></tr></thead><tbody>' +
        d.empfaenger.map(function (e) {
          var wer = e.contact_id ? '<a href="#kontakte/' + e.contact_id + '">' + esc(e.name || e.email) + "</a>" : esc(e.email);
          return "<tr><td>" + wer + (e.name ? '<small class="leise li-position">' + esc(e.email) + "</small>" : "") + "</td>" +
            '<td><span class="pille' + (e.status === "zugestellt" ? " pille--gut" : /fehler|bounce|beschwerde/.test(e.status) ? " pille--verloren" : "") + '"' + (e.fehler ? ' title="' + esc(e.fehler) + '"' : "") + ">" +
            esc(EMPF[e.status] || e.status) + "</span>" + (e.abgemeldet ? ' <span class="pille pille--verloren">abgemeldet</span>' : "") + "</td>" +
            '<td class="n">' + (e.klicks ? "<b>" + zahl(e.klicks) + "</b>" : "–") + "</td><td>" + wann(e.gesendet_am) + "</td></tr>";
        }).join("") + "</tbody></table></div></section>" +
      '<details class="karte panel nl-inhalt"><summary>Inhalt ansehen</summary><div class="nl-rahmen nl-rahmen--desktop"><iframe title="Versendete Mail" data-vorschau sandbox="allow-popups allow-popups-to-escape-sandbox"></iframe></div></details>';
    var f = wurzel.querySelector("[data-vorschau]"); if (f) f.srcdoc = R.render(n, { vorname: "Max", nachname: "Mustermann" }, {}).html;
    clearInterval(timer);
    if (laeuft) timer = setInterval(function () { if (aktiv && Z.ansicht === "auswertung") oeffnen(n.newsletter_id); }, 10000);
  }

  /* ---------- Liste hochladen ---------- */
  function erkenneListe(text) {
    var zeilen = String(text || "").split(/\r?\n/).map(function (z) { return z.trim(); }).filter(Boolean);
    if (!zeilen.length) return null;
    var tr = zeilen[0].indexOf("\t") >= 0 ? "\t" : zeilen[0].indexOf(";") >= 0 ? ";" : ",";
    var kopf = zeilen[0].split(tr).map(function (k) { return k.trim().toLowerCase().replace(/^"|"$/g, ""); });
    var mailRe = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
    function sp(re) { for (var i = 0; i < kopf.length; i++) if (re.test(kopf[i])) return i; return -1; }
    var s = { email: sp(/mail/), vorname: sp(/^(vorname|first)/), nachname: sp(/^(nachname|last|surname|familienname)/), name: sp(/^(name|vollständiger name|full name|kontakt)$/), firma: sp(/(firma|unternehmen|company|organisation)/) };
    var daten = zeilen.slice(1);
    if (s.email < 0) {
      // ohne Kopfzeile: erste Spalte mit E-Mail
      if (mailRe.test(zeilen[0].split(tr)[0].trim())) { s = { email: 0, vorname: -1, nachname: -1, name: kopf.length > 1 ? 1 : -1, firma: -1 }; daten = zeilen; }
      else return { fehlt: "Spalte „E-Mail“" };
    }
    var gesehen = {}, personen = [], ungueltig = 0, doppelt = 0;
    daten.forEach(function (z) {
      var c = z.split(tr).map(function (x) { return x.trim().replace(/^"|"$/g, ""); });
      var m = (c[s.email] || "").toLowerCase();
      if (!mailRe.test(m)) { ungueltig++; return; }
      if (gesehen[m]) { doppelt++; return; }
      gesehen[m] = true;
      personen.push({ email: m, vorname: s.vorname >= 0 ? c[s.vorname] || "" : "", nachname: s.nachname >= 0 ? c[s.nachname] || "" : "",
                      name: s.name >= 0 ? c[s.name] || "" : "", firma: s.firma >= 0 ? c[s.firma] || "" : "" });
    });
    return { personen: personen, ungueltig: ungueltig, doppelt: doppelt, spalten: s };
  }

  function listeAnsicht() {
    Z.ansicht = "liste";
    return api("newsletter_uebersicht", {}).then(function (d) {
      Z.daten = d; if (!aktiv) return;
      var L = Z.liste;
      wurzel.innerHTML =
        '<p class="zurueck"><a href="#newsletter">← Newsletter</a></p>' +
        '<div class="kopf"><div><h1>Liste hochladen</h1><p class="leise">Personen werden Kontakte mit Tag = Listenname und Newsletter-Erlaubnis</p></div></div>' +
        '<section class="karte panel">' +
          '<div class="li-form">' +
            '<label class="feld">Name der Liste <small>wird als Tag gesetzt, z. B. „bestandskunden“</small><input data-l="name" list="nl-listen" value="' + esc(L.name) + '">' +
              '<datalist id="nl-listen">' + d.listen.map(function (l) { return '<option value="' + esc(l.liste) + '">'; }).join("") + "</datalist></label>" +
            '<label class="feld">Grundlage für den Newsletter<select data-l="grundlage"><option value="">– bitte wählen –</option>' +
              '<option value="bestandskunde"' + (L.grundlage === "bestandskunde" ? " selected" : "") + ">Bestandskunden (§ 7 Abs. 3 UWG)</option>" +
              '<option value="einwilligung"' + (L.grundlage === "einwilligung" ? " selected" : "") + ">Einwilligung (z. B. Double-Opt-in)</option></select></label>" +
          "</div>" +
          '<label class="feld">Personen <small>in Excel die Tabelle samt Kopfzeile markieren (E-Mail, Vorname, Nachname oder Name, Firma), Cmd+C, hier Cmd+V – oder einfach eine E-Mail-Adresse pro Zeile</small>' +
            '<textarea data-l="text" rows="8" placeholder="E-Mail → Vorname → Nachname → Firma">' + esc(L.text) + "</textarea></label>" +
          '<div data-l-vorschau>' + listeVorschau() + "</div>" +
          '<label class="nl-schalter nl-bestaetigung"><input type="checkbox" data-l="bestaetigt"' + (L.bestaetigt ? " checked" : "") + '> <span data-l-hinweis>' + bestaetigungsText() + "</span></label>" +
          '<div data-l-knopf>' + listeKnopf() + "</div>" +
        "</section>";
    }).catch(fehler);
  }
  function listeVorschau() {
    var L = Z.liste, e = L.erkannt;
    var info = !L.text.trim() ? '<span class="leise">' + (L.meldung ? "" : "Noch nichts eingefügt.") + "</span>"
      : e.fehlt ? '<span class="li-warnung">Nicht erkannt – es fehlt: ' + esc(e.fehlt) + "</span>"
      : "<b>" + e.personen.length + " Personen erkannt</b>" + (e.ungueltig ? " · " + e.ungueltig + " ohne gültige E-Mail (werden übersprungen)" : "") + (e.doppelt ? " · " + e.doppelt + " doppelt" : "");
    return (e && e.personen && e.personen.length ? '<div class="tabelle-scroll"><table class="tabelle nl-liste-vorschau"><thead><tr><th>E-Mail</th><th>Name</th><th>Firma</th></tr></thead><tbody>' +
        e.personen.slice(0, 8).map(function (p) { return "<tr><td>" + esc(p.email) + "</td><td>" + esc(p.name || [p.vorname, p.nachname].filter(Boolean).join(" ")) + "</td><td>" + esc(p.firma) + "</td></tr>"; }).join("") +
        (e.personen.length > 8 ? '<tr><td colspan="3" class="leise">… und ' + (e.personen.length - 8) + " weitere</td></tr>" : "") + "</tbody></table></div>" : "") +
      '<div class="li-vorschau"><div class="li-info">' + info + (L.meldung ? ' <span class="li-ok">' + esc(L.meldung) + "</span>" : "") + "</div></div>";
  }
  function bestaetigungsText() {
    var L = Z.liste;
    return "Ich bestätige, dass für alle Personen dieser Liste die gewählte Grundlage vorliegt" +
      (L.grundlage === "bestandskunde" ? " (E-Mail-Adresse im Rahmen eines Auftrags erhalten, kein Widerspruch, Hinweis auf das Widerspruchsrecht erfolgt)"
        : L.grundlage === "einwilligung" ? " (nachweisbare Einwilligung, z. B. per Double-Opt-in)" : "") + ".";
  }
  function listeKnopf() {
    var L = Z.liste, e = L.erkannt;
    var bereit = e && e.personen && e.personen.length && L.name.trim() && L.grundlage && L.bestaetigt;
    return '<div class="knoepfe nl-liste-knopf"><button type="button" class="knopf knopf--primaer" data-aktion="liste"' + (bereit ? "" : " disabled") + ">Liste übernehmen</button></div>" +
      '<p class="leise nl-klein">Wer sich abgemeldet hat, unzustellbar war oder sich beschwert hat, bekommt dadurch keine Erlaubnis zurück.</p>';
  }
  function listeNeu() {
    var v = wurzel.querySelector("[data-l-vorschau]"); if (v) v.innerHTML = listeVorschau();
    var h = wurzel.querySelector("[data-l-hinweis]"); if (h) h.textContent = bestaetigungsText();
    var k = wurzel.querySelector("[data-l-knopf]"); if (k) k.innerHTML = listeKnopf();
  }

  /* ---------- Bedienung ---------- */
  wurzel.addEventListener("input", function (e) {
    if (!aktiv) return;
    var t = e.target;
    if (Z.ansicht === "editor" && (t.hasAttribute("data-f") || t.hasAttribute("data-test"))) {
      felder();
      clearTimeout(vorschauTimer); vorschauTimer = setTimeout(vorschau, 150);
      if (t.getAttribute("data-f") === "utm") { var k = wurzel.querySelector(".nl-kampagne"); if (k) k.hidden = !t.checked; }
      if (t.getAttribute("data-f") === "titel") { var kf = wurzel.querySelector("[data-f=utm_kampagne]"); if (kf) kf.placeholder = R.slug(t.value || "newsletter"); }
    }
    if (Z.ansicht === "liste" && t.hasAttribute("data-l")) {
      var f = t.getAttribute("data-l");
      Z.liste[f] = t.type === "checkbox" ? t.checked : t.value;
      if (f === "text") Z.liste.erkannt = erkenneListe(t.value);
      Z.liste.meldung = "";
      listeNeu();
    }
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv) return;
    var t = e.target;
    if (Z.ansicht === "editor") {
      if (t.hasAttribute("data-liste")) { felder(); clearTimeout(zgTimer); zgTimer = setTimeout(zielgruppe, 200); }
      if (t.type === "checkbox" && t.hasAttribute("data-f")) { felder(); vorschau(); var k = wurzel.querySelector(".nl-kampagne"); if (k && t.getAttribute("data-f") === "utm") k.hidden = !t.checked; }
      if (t.hasAttribute("data-platzhalter") && t.value) {
        var v = t.value; t.value = "";
        ansEnde();
        einfuegen("{{" + (v.slice(-1) === "|" ? v + "zusammen" : v) + "}}", "", "");
      }
    }
    if (Z.ansicht === "liste" && t.hasAttribute("data-l")) {
      var f = t.getAttribute("data-l");
      Z.liste[f] = t.type === "checkbox" ? t.checked : t.value;
      listeNeu();
    }
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t;
    if ((t = e.target.closest("tr[data-nl]"))) return C.oeffne("newsletter", t.getAttribute("data-nl"));
    if ((t = e.target.closest("[data-w]"))) {
      var w = t.getAttribute("data-w");
      if (w === "h1") return block("# Überschrift");
      if (w === "h2") return block("## Zwischenüberschrift");
      if (w === "fett") return einfuegen("**", "**", "fett");
      if (w === "kursiv") return einfuegen("*", "*", "kursiv");
      if (w === "link") return einfuegen("[", "](https://sofortsichtbar.de)", "Linktext");
      if (w === "button") return block("[[Termin buchen | https://sofortsichtbar.de/kontakt]]");
      if (w === "liste") return block("- erster Punkt\n- zweiter Punkt");
      if (w === "linie") return block("---");
    }
    if ((t = e.target.closest("[data-breite]"))) { Z.breite = t.getAttribute("data-breite"); var rf = wurzel.querySelector(".nl-rahmen"); if (rf) rf.className = "nl-rahmen nl-rahmen--" + Z.breite;
      wurzel.querySelectorAll("[data-breite]").forEach(function (b) { b.setAttribute("aria-pressed", String(b === t)); }); return; }
    if ((t = e.target.closest("[data-bsp]"))) { Z.beispielAn = t.getAttribute("data-bsp") === "1";
      wurzel.querySelectorAll("[data-bsp]").forEach(function (b) { b.setAttribute("aria-pressed", String(b === t)); }); return vorschau(); }
    if (!(t = e.target.closest("[data-aktion]"))) return;
    var a = t.getAttribute("data-aktion"), m = wurzel.querySelector("[data-meldung]");
    function zeig(text, gut) { if (m) { m.textContent = text; m.classList.toggle("ok", !!gut); } }

    if (a === "speichern") return speichern().catch(function () {});
    if (a === "test") {
      felder();
      var mails = Z.test.split(/[,;\s]+/).filter(function (x) { return x.indexOf("@") > 0; });
      if (!mails.length) return zeig("Bitte eine Test-Adresse eintragen.");
      t.disabled = true;
      return speichern().then(function (id) { return api("newsletter_test", { newsletter_id: id, emails: mails }); }).then(function (n) {
        zeig(n + (n === 1 ? " Testmail ist" : " Testmails sind") + " in der Warteschlange und kommen innerhalb einer Minute an. Im SES-Testmodus nur an bestätigte Adressen.", true);
        t.disabled = false;
        return api("newsletter", { newsletter_id: Z.nl.newsletter_id }).then(function (d) { Z.detail = d; });
      }).catch(function (err) { t.disabled = false; zeig(err.message); });
    }
    if (a === "senden-frage") {
      felder();
      var b = wurzel.querySelector("[data-bestaetigen]"), r = R.render(Z.nl, beispiel(), {});
      if (!Z.nl.betreff.trim() || !Z.nl.inhalt.trim()) return zeig("Betreff und Inhalt fehlen.");
      var anz = Z.zielgruppe ? Z.zielgruppe.anzahl : 0;
      if (!anz) return zeig("Keine Empfänger mit Newsletter-Erlaubnis in dieser Zielgruppe.");
      b.hidden = false;
      b.innerHTML = '<p><b>An ' + zahl(anz) + " Empfänger senden?</b><br>Betreff: „" + esc(r.betreff) + "“ · Absender Daniel Ströbel · " +
        (Z.nl.klicks_messen ? "Klicks werden gemessen" : "ohne Klickmessung") + ". Nach dem Senden lässt sich der Newsletter nicht mehr ändern.</p>" +
        '<label class="nl-schalter"><input type="checkbox" data-ok> Ich habe die Testmail geprüft (Text, Links, Platzhalter).</label>' +
        '<div class="knoepfe"><button type="button" class="knopf" data-aktion="senden-nein">Abbrechen</button><button type="button" class="knopf knopf--primaer" data-aktion="senden" disabled>Jetzt senden</button></div>';
      b.querySelector("[data-ok]").addEventListener("change", function (ev) { b.querySelector("[data-aktion=senden]").disabled = !ev.target.checked; });
      return;
    }
    if (a === "senden-nein") { var bb = wurzel.querySelector("[data-bestaetigen]"); bb.hidden = true; bb.innerHTML = ""; return; }
    if (a === "senden") {
      t.disabled = true; t.textContent = "Wird freigegeben …";
      return speichern().then(function (id) { return api("newsletter_senden", { newsletter_id: id, bestaetigt: true }).then(function () { return id; }); })
        .then(function (id) { oeffnen(id); })
        .catch(function (err) { t.disabled = false; t.textContent = "Jetzt senden"; zeig(err.message); });
    }
    if (a === "loeschen") {
      if (!confirm("Entwurf „" + (Z.nl.titel || "ohne Titel") + "“ löschen?")) return;
      return api("newsletter_loeschen", { newsletter_id: Z.nl.newsletter_id }).then(function () { C.oeffne("newsletter"); }).catch(function (err) { zeig(err.message); });
    }
    if (a === "abbrechen") {
      if (!confirm("Versand stoppen? Wer die Mail schon hat, behält sie; alle anderen bekommen sie nicht mehr.")) return;
      return api("newsletter_abbrechen", { newsletter_id: Z.nl.newsletter_id }).then(function () { oeffnen(Z.nl.newsletter_id); }).catch(fehler);
    }
    if (a === "liste") {
      var L = Z.liste;
      t.disabled = true; t.textContent = "Wird übernommen …";
      return api("newsletter_liste", { liste: L.name, grundlage: L.grundlage, bestaetigt: L.bestaetigt, personen: L.erkannt.personen }).then(function (r2) {
        L.meldung = r2.gesamt + " übernommen: " + r2.neu + " neue Kontakte, " + r2.erlaubt_neu + " mit neuer Newsletter-Erlaubnis" +
          (r2.gesperrt ? ", " + r2.gesperrt + " gesperrt (abgemeldet/unzustellbar) – ohne Erlaubnis" : "") + (r2.ungueltig ? ", " + r2.ungueltig + " ungültig" : "");
        L.text = ""; L.erkannt = null; L.bestaetigt = false;
        return listeAnsicht();
      }).catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
  });
  wurzel.addEventListener("keydown", function (e) {
    if (!aktiv || e.key !== "Enter") return;
    var t = e.target.closest("tr[data-nl]"); if (t) C.oeffne("newsletter", t.getAttribute("data-nl"));
  });

  C.module.newsletter = { start: start, stop: stop, erkenneListe: erkenneListe };
})();
