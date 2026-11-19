/* Cockpit · Call-Protokoll als Pop-up – ansehen und bearbeiten, ohne die
   Seite zu wechseln. Genutzt von Calls und von der Kontaktkarte:
   cockpit.callPopup(callId, nachAenderung) */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc;
  var dlg = null, aktuell = null, danach = null, suchTimer = null;

  function lokal(d) { var x = d ? new Date(d) : new Date(); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 16); }
  function name(k) { return [k.vorname, k.nachname].filter(Boolean).join(" "); }

  function bauen() {
    dlg = document.createElement("dialog");
    dlg.className = "cp";
    dlg.setAttribute("aria-label", "Call-Protokoll");
    document.body.appendChild(dlg);
    dlg.addEventListener("click", function (e) {
      if (e.target === dlg) return zu();                       // Klick auf den Hintergrund
      var t;
      if (e.target.closest("[data-cp-zu]")) return zu();
      if ((t = e.target.closest("[data-cp-kontakt]"))) {
        aktuell.contact_id = t.getAttribute("data-cp-kontakt"); aktuell.name = t.getAttribute("data-name");
        var f = dlg.querySelector("[data-cp-wer]"); if (f) f.innerHTML = werHtml();
        return;
      }
      if (e.target.closest("[data-cp-kontakt-weg]")) { aktuell.contact_id = null; aktuell.name = ""; dlg.querySelector("[data-cp-wer]").innerHTML = werHtml(); return; }
      if (e.target.closest("[data-cp-loeschen]")) {
        if (!confirm("Call „" + (aktuell.titel || "Gespräch") + "“ endgültig löschen?")) return;
        return api("loeschen", { call_id: aktuell.call_id }).then(function () { zu(); if (danach) danach(); }).catch(meldung);
      }
    });
    dlg.addEventListener("input", function (e) {
      if (!e.target.hasAttribute("data-cp-suche")) return;
      clearTimeout(suchTimer);
      var wert = e.target.value.trim();
      suchTimer = setTimeout(function () {
        api("kontakte", { suche: wert }).then(function (r) {
          var ul = dlg.querySelector("[data-cp-treffer]"); if (!ul) return;
          ul.innerHTML = r.slice(0, 8).map(function (k) {
            return '<li><button type="button" data-cp-kontakt="' + k.contact_id + '" data-name="' + esc(name(k) || k.email) + '"><b>' + esc(name(k) || k.email) + "</b><small>" + esc(name(k) ? k.email || "" : "") + "</small></button></li>";
          }).join("") || '<li class="leise">Kein Treffer.</li>';
        }).catch(function () {});
      }, 250);
    });
    dlg.addEventListener("submit", function (e) {
      e.preventDefault();
      var f = e.target, knopf = f.querySelector('button[type="submit"]');
      knopf.disabled = true; knopf.textContent = "Wird gespeichert …";
      api("speichern", { call: {
        call_id: aktuell.call_id, contact_id: aktuell.contact_id, booking_uid: aktuell.booking_uid || "",
        stattgefunden_am: new Date(f.elements.zeit.value).toISOString(), titel: f.elements.titel.value,
        zusammenfassung: f.elements.zusammenfassung.value, transkript: f.elements.transkript.value, aufnahme_zugestimmt: true
      } }).then(function () { zu(); if (danach) danach(); })
        .catch(function (err) { knopf.disabled = false; knopf.textContent = "Speichern"; meldung(err); });
    });
    dlg.addEventListener("close", function () { aktuell = null; });
  }
  function meldung(err) { var m = dlg && dlg.querySelector("[data-cp-meldung]"); if (m) m.textContent = err.message || String(err); }
  function zu() { if (dlg && dlg.open) dlg.close(); }

  function werHtml() {
    return aktuell.contact_id
      ? '<span class="cp-wer"><a href="#kontakte/' + aktuell.contact_id + '" data-cp-zu>' + esc(aktuell.name || "Kontakt") + '</a> <button type="button" class="li-link" data-cp-kontakt-weg>ändern</button></span>'
      : '<input type="search" class="suche" data-cp-suche placeholder="Kontakt suchen: Name oder E-Mail" autocomplete="off"><ul class="treffer" data-cp-treffer></ul>';
  }

  function zeichnen() {
    var c = aktuell;
    dlg.innerHTML =
      '<form class="cp-form" method="dialog">' +
        '<header class="cp-kopf"><div><p class="cp-ueber">Call-Protokoll' + (c.quelle === "sharepoint" ? " · aus dem Ordner „Protokolle“" : "") + '</p>' +
          '<input class="cp-titel" name="titel" value="' + esc(c.titel || "") + '" placeholder="Titel" aria-label="Titel"></div>' +
          '<button type="button" class="cp-x" data-cp-zu aria-label="Schließen">×</button></header>' +
        '<div class="cp-reihe"><label class="feld">Datum<input type="datetime-local" name="zeit" value="' + lokal(c.stattgefunden_am) + '"></label>' +
          '<div class="feld"><span>Kontakt</span><div data-cp-wer>' + werHtml() + "</div></div></div>" +
        '<label class="feld">Zusammenfassung<textarea name="zusammenfassung" rows="4" placeholder="Kurz das Wichtigste – Bedarf, nächste Schritte">' + esc(c.zusammenfassung || "") + "</textarea></label>" +
        '<label class="feld">Transkript<textarea name="transkript" rows="14" required>' + esc(c.transkript || "") + "</textarea></label>" +
        '<p class="fehler" data-cp-meldung></p>' +
        '<footer class="cp-fuss"><button type="button" class="knopf knopf--gefahr" data-cp-loeschen>Löschen</button>' +
          '<span class="cp-raum"></span><button type="button" class="knopf" data-cp-zu>Schließen</button>' +
          '<button type="submit" class="knopf knopf--primaer">Speichern</button></footer>' +
      "</form>";
  }

  C.callPopup = function (callId, nachAenderung) {
    if (!dlg) bauen();
    danach = nachAenderung || null;
    dlg.innerHTML = '<p class="cp-laedt">Lädt …</p>';
    if (!dlg.open) dlg.showModal();
    return api("call", { call_id: callId }).then(function (d) {
      if (!d) { dlg.innerHTML = '<p class="cp-laedt">Call nicht gefunden. <button type="button" class="li-link" data-cp-zu>Schließen</button></p>'; return; }
      aktuell = d; zeichnen();
      var t = dlg.querySelector(".cp-titel"); if (t) t.focus();
    }).catch(function (e) { dlg.innerHTML = '<p class="cp-laedt">Fehler: ' + esc(e.message) + ' <button type="button" class="li-link" data-cp-zu>Schließen</button></p>'; });
  };
})();
