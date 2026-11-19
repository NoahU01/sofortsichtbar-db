/* Cockpit · Listen – alle Listen (= Tags) ansehen, anlegen, löschen.
   Eine Liste öffnen zeigt ihre Kontakte; dafür übernimmt die Kontaktliste
   im Listenmodus (gleiche Tabelle, Auswahl, Entfernen, Auflösen). */
(function () {
  "use strict";
  var C = window.cockpit, api = C.api, esc = C.esc, wurzel = C.main;
  var aktiv = false, delegiert = false, listen = [], meldung = "";

  function zahl(n) { return Number(n || 0).toLocaleString("de-DE"); }
  function start(arg) {
    aktiv = true; delegiert = false;
    if (arg) { delegiert = true; return C.module.kontakte.start("liste:" + arg); }
    wurzel.innerHTML = '<div class="laedt">Lädt …</div>';
    laden();
  }
  function stop() { aktiv = false; if (delegiert) C.module.kontakte.stop(); delegiert = false; }
  function laden() {
    return api("listen", {}).then(function (l) { listen = l || []; if (aktiv && !delegiert) zeichnen(); })
      .catch(function (e) { if (aktiv) wurzel.innerHTML = '<div class="karte leer">Fehler: ' + esc(e.message) + "</div>"; });
  }
  function zeichnen() {
    wurzel.innerHTML =
      '<div class="kopf"><div><h1>Listen</h1><p class="leise">Kontakte gruppieren – für Newsletter, Kampagnen oder zum Wiederfinden. Kontakte kommen über Kontakte → anhaken → „Zu Liste hinzufügen“ dazu.</p></div></div>' +
      '<section class="karte panel"><div class="panel-kopf"><h2>Neue Liste</h2></div>' +
        '<div class="ls-neu"><label class="feld">Name<input data-ls-name maxlength="60" placeholder="z. B. Messe Köln 2027"></label>' +
        '<button type="button" class="knopf knopf--primaer" data-ls-anlegen>Anlegen</button></div>' +
        (meldung ? '<p class="fehler ok">' + esc(meldung) + "</p>" : "") + "</section>" +
      (listen.length ? '<div class="karte tabelle-rahmen"><table class="tabelle tabelle--klick ls-tabelle"><thead><tr><th>Liste</th><th class="n">Kontakte</th><th class="n">dürfen Newsletter</th><th><span class="sr">Aktionen</span></th></tr></thead><tbody>' +
        listen.map(function (l) {
          return '<tr data-ls-oeffnen="' + esc(l.liste) + '" tabindex="0"><td><b>' + esc(l.liste.replace(/_/g, " ")) + "</b></td>" +
            '<td class="n">' + zahl(l.kontakte) + '</td><td class="n">' + zahl(l.erlaubt) + "</td>" +
            '<td class="ls-aktion"><button type="button" class="li-link li-link--gefahr" data-ls-loeschen="' + esc(l.liste) + '">löschen</button></td></tr>';
        }).join("") + "</tbody></table></div>"
        : '<div class="karte leer">Noch keine Listen.</div>');
  }

  wurzel.addEventListener("click", function (e) {
    if (!aktiv || delegiert) return;
    var t;
    if (e.target.closest("[data-ls-anlegen]")) {
      var f = wurzel.querySelector("[data-ls-name]"), n = (f.value || "").trim();
      if (!n) return f.focus();
      return api("tag_anlegen", { name: n }).then(function (name) { meldung = "Liste „" + name + "“ angelegt."; return laden(); })
        .catch(function (err) { meldung = "Fehler: " + err.message; zeichnen(); });
    }
    if ((t = e.target.closest("[data-ls-loeschen]"))) {
      var l = t.getAttribute("data-ls-loeschen");
      if (!confirm("Liste „" + l + "“ löschen? Die Kontakte selbst bleiben erhalten, nur die Zuordnung zur Liste wird entfernt.")) return;
      return api("liste_loeschen", { liste: l }).then(function (k) { meldung = "Liste „" + l + "“ gelöscht (" + k + " Kontakte waren darin)."; return laden(); })
        .catch(function (err) { meldung = "Fehler: " + err.message; zeichnen(); });
    }
    if ((t = e.target.closest("tr[data-ls-oeffnen]"))) return C.oeffne("listen", encodeURIComponent(t.getAttribute("data-ls-oeffnen")));
  });
  wurzel.addEventListener("keydown", function (e) {
    if (!aktiv || delegiert) return;
    if (e.key === "Enter" && e.target.hasAttribute && e.target.hasAttribute("data-ls-name")) { var b = wurzel.querySelector("[data-ls-anlegen]"); if (b) b.click(); }
    var t = e.key === "Enter" && e.target.closest && e.target.closest("tr[data-ls-oeffnen]");
    if (t) C.oeffne("listen", encodeURIComponent(t.getAttribute("data-ls-oeffnen")));
  });

  C.module.listen = { start: start, stop: stop };
})();
