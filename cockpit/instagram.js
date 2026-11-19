/* Cockpit · Instagram – Beiträge und Zahlen aus Buffer, Likes per Einfügen.
   Buffer zeigt, wo Likes fehlen; die Like-Liste wird in Instagram kopiert
   und hier eingefügt. Zuordnung zu Kontakten automatisch nur bei bekanntem
   Instagram-Namen oder eindeutigem Klarnamen – sonst von Hand. */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var Z = { daten: null, beitrag: null, text: "", erkannt: [], meldung: "", filter: "offen", alle: false, suche: null };
  var aktiv = false, suchTimer = null;
  // Bedienelemente, die beim Kopieren aus Instagram mitkommen
  var UI = /^(folgen|follow|following|gefolgt|abonniert|entfernen|remove|gefällt mir|likes?|„gefällt mir“-angaben|suchen|search|nachricht|message|verifiziert|verified|·|•)$/i;

  function zahl(n) { return n == null ? "–" : Number(n).toLocaleString("de-DE"); }
  function tag(d) { return d ? new Date(d).toLocaleDateString("de-DE", { day: "numeric", month: "short", year: "numeric" }) : "–"; }
  function B() { return (Z.daten && Z.daten.beitraege) || []; }
  function P() { return (Z.daten && Z.daten.personen) || []; }

  /* Like-Liste erkennen: Benutzername (ohne Leerzeichen), danach optional der Anzeigename */
  function erkenne(text) {
    var zeilen = String(text || "").split(/\r?\n/).map(function (z) { return z.trim(); })
      .filter(function (z) { return z && !UI.test(z) && !/^profilbild von|'s profile picture$|^profile picture/i.test(z); });
    var aus = [], gesehen = {};
    for (var i = 0; i < zeilen.length; i++) {
      var u = zeilen[i].replace(/^@/, "").replace(/\s*(verifiziert|verified)$/i, "");
      if (!/^[A-Za-z0-9._]{1,30}$/.test(u)) continue;
      var name = zeilen[i + 1] && !/^@?[A-Za-z0-9._]{1,30}$/.test(zeilen[i + 1]) ? zeilen[i + 1] : "";
      if (name) i++;
      var k = u.toLowerCase();
      if (!gesehen[k]) { gesehen[k] = true; aus.push({ benutzername: k, name: name }); }
    }
    return aus;
  }

  function start() { aktiv = true; wurzel.innerHTML = '<div class="laedt">Lädt …</div>'; laden(); }
  function stop() { aktiv = false; }
  function laden() {
    return api("instagram", {}).then(function (d) {
      Z.daten = d;
      var z = document.querySelector('[data-zahl="instagram"]');
      if (z) z.textContent = B().filter(function (b) { return b.beobachtet && b.fehlen > 0 && !b.verworfen; }).length || "";
      if (aktiv) zeichnen();
    }).catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }

  function zeichnen() {
    if (!Z.beitrag || !B().some(function (b) { return b.post_id === Z.beitrag; })) {
      var vor = B().filter(function (b) { return b.beobachtet && b.fehlen > 0 && !b.verworfen; })[0] || B()[0];
      Z.beitrag = vor ? vor.post_id : null;
    }
    var offen = B().filter(function (b) { return b.beobachtet && b.fehlen > 0 && !b.verworfen; });
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Instagram</h1><p class="leise">Beiträge und Zahlen aus Buffer · ' + zahl(Z.daten.follower) + ' Follower erfasst · Likes ab dem 18.11. per Einfügen</p></div></div>' +
      (offen.length ? '<div class="statusleiste"><span class="status status--aus"><i></i>Bei ' + offen.length + (offen.length === 1 ? " Beitrag fehlen" : " Beiträgen fehlen") + " Likes</span></div>" : "") +
      '<section class="karte panel" data-ig-form>' + formular() + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Beiträge</h2><span class="leise">aus Buffer, täglich aktualisiert</span></div>' + beitraege() + "</section>" +
      '<section class="karte panel"><div class="panel-kopf"><h2>Personen</h2>' +
        '<div class="seg" role="group" aria-label="Personen filtern">' + [["offen", "ohne Kontakt"], ["alle", "alle"], ["ignoriert", "ausgeschlossen"]].map(function (f) {
          return '<button type="button" data-ig-filter="' + f[0] + '" aria-pressed="' + (Z.filter === f[0]) + '">' + f[1] + "</button>"; }).join("") + "</div></div>" +
        personen() + "</section>";
  }

  function formular() {
    if (!Z.beitrag) return '<div class="panel-kopf"><h2>Likes einfügen</h2></div><p class="panel-leer">Noch keine Instagram-Beiträge aus Buffer.</p>';
    var b = B().filter(function (x) { return x.post_id === Z.beitrag; })[0];
    return '<div class="panel-kopf"><h2>Likes einfügen</h2><span class="leise">In Instagram auf „Gefällt mir“ klicken → Liste markieren → kopieren → hier einfügen</span></div>' +
      '<label class="feld">Beitrag<select data-ig-beitrag>' + B().map(function (x) {
        return '<option value="' + esc(x.post_id) + '"' + (x.post_id === Z.beitrag ? " selected" : "") + ">" + esc(tag(x.veroeffentlicht) + " · " + x.titel) +
          (x.fehlen && !x.verworfen ? " – " + x.fehlen + " fehlen" : "") + "</option>";
      }).join("") + "</select></label>" +
      (b && b.url ? '<p class="leise nl-mini"><a href="' + esc(b.url) + '" target="_blank" rel="noopener">Beitrag auf Instagram öffnen</a> · laut Buffer ' + zahl(b.likes) + " Likes, erfasst " + zahl(b.erfasst) + "</p>" : "") +
      '<label class="feld">Like-Liste<textarea data-ig-text rows="6" placeholder="benutzername&#10;Anzeigename&#10;Folgen&#10;…">' + esc(Z.text) + "</textarea></label>" +
      '<div data-ig-vorschau>' + vorschau() + "</div>";
  }
  function vorschau() {
    var l = Z.erkannt;
    var bekannt = {}; P().forEach(function (p) { bekannt[p.benutzername] = p; });
    return (l.length ? '<p class="leise">' + l.length + " erkannt: " + l.slice(0, 30).map(function (x) {
        return (bekannt[x.benutzername] ? "" : "<b>") + "@" + esc(x.benutzername) + (x.name ? " (" + esc(x.name) + ")" : "") + (bekannt[x.benutzername] ? "" : "</b>");
      }).join(", ") + (l.length > 30 ? " …" : "") + " <small>· fett = neu</small></p>" : "") +
      (Z.meldung ? '<p class="fehler ok">' + esc(Z.meldung) + "</p>" : "") +
      '<div class="knoepfe"><button type="button" class="knopf knopf--primaer" data-ig-speichern' + (l.length ? "" : " disabled") + ">Likes übernehmen</button></div>";
  }

  function beitraege() {
    var l = Z.alle ? B() : B().filter(function (b) { return b.beobachtet; });
    var mehr = B().length - B().filter(function (b) { return b.beobachtet; }).length;
    var um = mehr ? '<p class="li-mehr"><button type="button" class="li-link" data-ig-alle>' + (Z.alle ? "nur letzte 30 Tage und erfasste" : "alle " + B().length + " Beiträge zeigen (" + mehr + " ältere)") + "</button></p>" : "";
    if (!l.length) return '<p class="panel-leer">Keine Beiträge in den letzten 30 Tagen.</p>' + um;
    return '<ul class="li-beitraege">' + l.map(function (b) {
      var soll = b.likes || 0, anteil = soll ? Math.min(100, Math.round(b.erfasst / soll * 100)) : 0;
      return '<li class="li-b"><div class="li-b-text"><span class="li-b-meta">' + tag(b.veroeffentlicht) + "</span>" +
          (b.url ? '<a class="li-b-titel" href="' + esc(b.url) + '" target="_blank" rel="noopener">' + esc(b.titel) + "</a>" : '<span class="li-b-titel">' + esc(b.titel) + "</span>") + "</div>" +
        '<dl class="li-b-zahlen"><div><dt>Impressionen</dt><dd>' + zahl(b.impressionen) + "</dd></div><div><dt>Likes</dt><dd>" + zahl(b.likes) + "</dd></div>" +
          "<div><dt>Kommentare</dt><dd>" + zahl(b.kommentare) + (b.kommentare_erfasst ? '<span class="leise"> · ' + zahl(b.kommentare_erfasst) + " erfasst</span>" : "") + "</dd></div>" +
          '<div class="li-b-erfasst"><dt>erfasst</dt><dd>' + zahl(b.erfasst) + (soll ? '<span class="leise"> / ' + zahl(soll) + '</span><span class="li-balken" aria-hidden="true"><i style="width:' + anteil + '%"></i></span>' : "") + "</dd></div></dl>" +
        '<div class="li-b-aktionen">' + (b.fehlen > 0 && !b.verworfen ? '<span class="pille pille--verloren">' + b.fehlen + (b.fehlen === 1 ? " fehlt" : " fehlen") + "</span>" +
            '<button type="button" class="li-link" data-ig-verwerfen="' + esc(b.post_id) + '" title="Vorschlag ausblenden – kommt wieder, sobald Buffer neue Likes meldet">verwerfen</button>' : "") +
          '<button type="button" class="knopf knopf--klein" data-ig-einfuegen="' + esc(b.post_id) + '">' + (b.erfasst ? "Nachtragen" : "Einfügen") + "</button></div></li>";
    }).join("") + "</ul>" + um;
  }

  function personen() {
    var l = P().filter(function (p) {
      if (Z.filter === "ignoriert") return p.ignoriert;
      if (p.ignoriert) return false;
      return Z.filter === "offen" ? !p.kontakt : true;
    });
    if (!l.length) return '<p class="panel-leer">Keine Personen in dieser Ansicht.</p>';
    return '<div class="tabelle-scroll"><table class="tabelle li-personen"><thead><tr><th>Person</th><th class="n">Likes</th><th class="n">Kommentare</th><th>Zuletzt</th><th>Kontakt</th></tr></thead><tbody>' +
      l.map(function (p) {
        return "<tr><td><b>@" + esc(p.benutzername) + "</b>" + (p.follower ? ' <span class="pille">Follower</span>' : "") + (p.name ? '<small class="li-position">' + esc(p.name) + "</small>" : "") + "</td>" +
          '<td class="n"><b>' + zahl(p.likes) + '</b></td><td class="n">' + (p.kommentare ? "<b>" + zahl(p.kommentare) + "</b>" : "–") + "</td>" +
          "<td>" + tag(p.letzte) + '</td><td class="li-kontakt">' + kontaktZelle(p) + "</td></tr>";
      }).join("") + "</tbody></table></div>";
  }
  function kontaktZelle(p) {
    if (p.ignoriert) return '<button type="button" class="knopf" data-ig-was="zurueckholen" data-person="' + p.person_id + '">Zurückholen</button>';
    if (p.kontakt) return '<a href="#kontakte/' + p.kontakt.contact_id + '">' + esc(p.kontakt.name || p.kontakt.email || "Kontakt") + "</a>" +
      ' <button type="button" class="li-link" data-ig-was="loesen" data-person="' + p.person_id + '">lösen</button>';
    if (Z.suche === p.person_id) return '<input type="search" class="suche" data-ig-suche="' + p.person_id + '" placeholder="Kontakt suchen: Name oder E-Mail" autocomplete="off">' +
      '<ul class="treffer" data-ig-treffer></ul><button type="button" class="li-link" data-ig-abbrechen>abbrechen</button>';
    return '<div class="knoepfe"><button type="button" class="knopf" data-ig-was="kontakt_anlegen" data-person="' + p.person_id + '">Kontakt anlegen</button>' +
      '<button type="button" class="knopf" data-ig-suchen="' + p.person_id + '">Zuordnen …</button>' +
      '<button type="button" class="knopf" data-ig-was="ignorieren" data-person="' + p.person_id + '" title="wird erfasst, aber nie zugeordnet">Ausschließen</button></div>';
  }

  wurzel.addEventListener("input", function (e) {
    if (!aktiv) return;
    var t = e.target;
    if (t.hasAttribute("data-ig-text")) {
      Z.text = t.value; Z.erkannt = erkenne(t.value); Z.meldung = "";
      var v = wurzel.querySelector("[data-ig-vorschau]"); if (v) v.innerHTML = vorschau();
    } else if (t.hasAttribute("data-ig-suche")) {
      clearTimeout(suchTimer);
      var person = t.getAttribute("data-ig-suche"), wert = t.value.trim();
      suchTimer = setTimeout(function () {
        api("kontakte", { suche: wert }).then(function (r) {
          var ul = wurzel.querySelector("[data-ig-treffer]"); if (!ul) return;
          ul.innerHTML = r.map(function (k) {
            var n = [k.vorname, k.nachname].filter(Boolean).join(" ");
            return '<li><button type="button" data-ig-was="zuordnen" data-person="' + person + '" data-kontakt="' + k.contact_id + '"><b>' + esc(n || k.email) + "</b><small>" + esc(n ? k.email || "" : "") + "</small></button></li>";
          }).join("") || '<li class="leise">Kein Treffer – dann „Kontakt anlegen“.</li>';
        }).catch(function () {});
      }, 250);
    }
  });
  wurzel.addEventListener("change", function (e) {
    if (!aktiv || !e.target.hasAttribute("data-ig-beitrag")) return;
    Z.beitrag = e.target.value; Z.meldung = "";
    var f = wurzel.querySelector("[data-ig-form]"); if (f) f.innerHTML = formular();
  });
  wurzel.addEventListener("click", function (e) {
    if (!aktiv) return;
    var t;
    if ((t = e.target.closest("[data-ig-filter]"))) { Z.filter = t.getAttribute("data-ig-filter"); return zeichnen(); }
    if (e.target.closest("[data-ig-alle]")) { Z.alle = !Z.alle; return zeichnen(); }
    if ((t = e.target.closest("[data-ig-verwerfen]"))) {
      t.disabled = true;
      return api("instagram_verwerfen", { post_id: t.getAttribute("data-ig-verwerfen") }).then(laden).catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
    if ((t = e.target.closest("[data-ig-einfuegen]"))) {
      Z.beitrag = t.getAttribute("data-ig-einfuegen"); Z.meldung = ""; zeichnen();
      var ta = wurzel.querySelector("[data-ig-text]"); if (ta) { ta.scrollIntoView({ block: "center" }); ta.focus(); }
      return;
    }
    if (e.target.closest("[data-ig-speichern]")) {
      var b = e.target.closest("[data-ig-speichern]"); b.disabled = true;
      return api("instagram_erfassen", { post_id: Z.beitrag, personen: Z.erkannt }).then(function (r) {
        Z.meldung = r.neu_likes + " neue Likes gespeichert" + (r.gesamt > r.neu_likes ? ", " + (r.gesamt - r.neu_likes) + " waren schon erfasst" : "") +
          (r.neu_personen ? " · " + r.neu_personen + " neue Personen" : "") + (r.zugeordnet ? " · " + r.zugeordnet + " Kontakten zugeordnet" : "");
        Z.text = ""; Z.erkannt = [];
        return laden();
      }).catch(function (err) { b.disabled = false; Z.meldung = "Fehler: " + err.message; var v = wurzel.querySelector("[data-ig-vorschau]"); if (v) v.innerHTML = vorschau(); });
    }
    if ((t = e.target.closest("[data-ig-suchen]"))) {
      Z.suche = t.getAttribute("data-ig-suchen"); zeichnen();
      var s = wurzel.querySelector("[data-ig-suche]"); if (s) s.focus();
      return;
    }
    if (e.target.closest("[data-ig-abbrechen]")) { Z.suche = null; return zeichnen(); }
    if ((t = e.target.closest("[data-ig-was]"))) {
      t.disabled = true; Z.suche = null;
      return api("instagram_person", { person_id: t.getAttribute("data-person"), was: t.getAttribute("data-ig-was"), contact_id: t.getAttribute("data-kontakt") || null })
        .then(laden).catch(function (err) { t.disabled = false; t.textContent = "Fehler: " + err.message; });
    }
  });

  C.module.instagram = { start: start, stop: stop, erkenne: erkenne };
})();
