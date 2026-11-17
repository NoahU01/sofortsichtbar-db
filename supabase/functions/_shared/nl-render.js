/* Newsletter-Renderer – EINE Quelle für Cockpit-Vorschau und Versand.
   Diese Datei liegt identisch unter cockpit/nl-render.js und
   supabase/functions/_shared/nl-render.js (ein Test prüft das).

   Inhalt (vereinfachtes Markdown):
     # Überschrift            ## Zwischenüberschrift
     Absätze durch Leerzeile; einfacher Zeilenumbruch bleibt erhalten
     - Aufzählung             ---  Trennlinie
     **fett**  *kursiv*  [Linktext](https://…)
     [[Button-Text | https://…]]
     {{vorname}} {{nachname}} {{name}} {{titel}} {{firma}} {{position}} {{email}}
     {{anrede}}  → „Hallo Max“ bzw. „Hallo zusammen“
     {{feld|Ersatz}} → Ersatz, wenn das Feld leer ist

   nlRender.render(newsletter, kontakt, optionen) → { html, text, links, betreff }
     newsletter: { betreff, vorschautext, inhalt, klicks_messen, utm, utm_kampagne }
     optionen:   { token, basis }   ohne token = Vorschau (Links direkt, Abmelden ohne Ziel) */
(function (g) {
  "use strict";

  var BASIS = "https://www.sofortsichtbar.de";
  var LILA = "#8324b9";
  var FELDER = ["vorname", "nachname", "name", "titel", "firma", "position", "email", "anrede"];

  function esc(s) {
    return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function sicher(url) {
    url = String(url || "").trim();
    return /^(https?:\/\/|mailto:)/i.test(url) ? url : null;
  }
  function slug(s) {
    return String(s || "newsletter").toLowerCase().replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss")
      .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "newsletter";
  }

  function werte(k) {
    k = k || {};
    var name = [k.vorname, k.nachname].filter(Boolean).join(" ");
    return {
      vorname: k.vorname || "", nachname: k.nachname || "", name: name, titel: k.titel || "", firma: k.firma || "",
      position: k.position || "", email: k.email || "",
      anrede: k.vorname ? "Hallo " + k.vorname : "Hallo zusammen"
    };
  }
  function platzhalter(text, w) {
    return text.replace(/\{\{\s*([a-zäöü]+)\s*(?:\|([^}]*))?\}\}/gi, function (m, feld, ersatz) {
      feld = feld.toLowerCase();
      if (FELDER.indexOf(feld) < 0) return m;
      var v = w[feld];
      return v ? v : (ersatz != null ? ersatz.trim() : "");
    });
  }

  // Link-Ziel mit UTM (nur für eigene Seiten)
  function ziel(url, nl) {
    if (!nl.utm || !/^https?:\/\/([a-z0-9-]+\.)*sofortsichtbar\.de(\/|$|\?|#)/i.test(url)) return url;
    var hash = "", i = url.indexOf("#");
    if (i >= 0) { hash = url.slice(i); url = url.slice(0, i); }
    var p = "utm_source=newsletter&utm_medium=email&utm_campaign=" + encodeURIComponent(slug(nl.utm_kampagne || nl.titel));
    return url + (url.indexOf("?") >= 0 ? "&" : "?") + p + hash;
  }

  function render(nl, kontakt, opt) {
    nl = nl || {}; opt = opt || {};
    var basis = (opt.basis || BASIS).replace(/\/+$/, "");
    var w = werte(kontakt), links = [];

    function href(url) {
      var z = ziel(url, nl), nr = links.indexOf(z);
      if (nr < 0) { links.push(z); nr = links.length - 1; }
      if (opt.token && nl.klicks_messen) return basis + "/n/" + opt.token + "/" + nr;
      return z;
    }

    // Inline: zuerst Platzhalter einsetzen, dann escapen, dann Formatierung
    function inline(roh) {
      var s = esc(platzhalter(roh, w));
      s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (m, t, u) {
        var url = sicher(u.replace(/&amp;/g, "&"));
        return url ? '<a href="' + esc(href(url)) + '" style="color:' + LILA + ';text-decoration:underline">' + t + "</a>" : t;
      });
      s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
      return s;
    }
    function inlineText(roh) {
      return platzhalter(roh, w).replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (m, t, u) {
        var url = sicher(u); return url ? t + " (" + href(url) + ")" : t;
      }).replace(/\*\*([^*]+)\*\*/g, "$1").replace(/(^|[^*])\*([^*\n]+)\*/g, "$1$2");
    }

    var bloecke = String(nl.inhalt || "").replace(/\r\n?/g, "\n").split(/\n{2,}/);
    var html = [], text = [];
    bloecke.forEach(function (b) {
      var t = b.trim();
      if (!t) return;
      var btn = /^\[\[\s*([^|\]]+?)\s*\|\s*([^\]\s]+)\s*\]\]$/.exec(t);
      if (btn && sicher(btn[2])) {
        var h = href(sicher(btn[2]));
        html.push('<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 22px"><tr><td style="border-radius:8px;background:' + LILA + '">' +
          '<a href="' + esc(h) + '" style="display:inline-block;padding:13px 24px;font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:bold;color:#ffffff;text-decoration:none;border-radius:8px">' +
          esc(platzhalter(btn[1], w)) + "</a></td></tr></table>");
        text.push(platzhalter(btn[1], w) + ": " + h);
        return;
      }
      if (/^-{3,}$/.test(t)) {
        html.push('<hr style="border:0;border-top:1px solid #e6e3ea;margin:26px 0">');
        text.push("――――――――");
        return;
      }
      var hm = /^(#{1,2})\s+(.+)$/.exec(t);
      if (hm && t.indexOf("\n") < 0) {
        var gr = hm[1].length === 1 ? 24 : 19;
        html.push('<h' + hm[1].length + ' style="margin:0 0 14px;font-family:Arial,Helvetica,sans-serif;font-size:' + gr + 'px;line-height:1.3;color:#16131a">' + inline(hm[2]) + "</h" + hm[1].length + ">");
        text.push(inlineText(hm[2]).toUpperCase());
        return;
      }
      var zeilen = t.split("\n");
      if (zeilen.every(function (z) { return /^\s*[-•]\s+/.test(z); })) {
        html.push('<ul style="margin:0 0 18px;padding-left:22px">' + zeilen.map(function (z) {
          return '<li style="margin:0 0 6px">' + inline(z.replace(/^\s*[-•]\s+/, "")) + "</li>";
        }).join("") + "</ul>");
        text.push(zeilen.map(function (z) { return "• " + inlineText(z.replace(/^\s*[-•]\s+/, "")); }).join("\n"));
        return;
      }
      html.push('<p style="margin:0 0 18px">' + zeilen.map(inline).join("<br>") + "</p>");
      text.push(zeilen.map(inlineText).join("\n"));
    });

    var abmelden = opt.token ? basis + "/newsletter/abmelden?t=" + encodeURIComponent(opt.token) : basis + "/newsletter/abmelden";
    var vorschau = esc(platzhalter(nl.vorschautext || "", w));
    var betreff = platzhalter(nl.betreff || "", w);

    var dok =
      '<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta name="color-scheme" content="light"><title>' + esc(betreff) + "</title></head>" +
      '<body style="margin:0;padding:0;background:#f3f1f5">' +
      '<div style="display:none;max-height:0;overflow:hidden;opacity:0">' + vorschau + "&#8199;&#65279;&#847;".repeat(30) + "</div>" +
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f3f1f5"><tr><td align="center" style="padding:24px 12px">' +
      '<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px">' +
      '<tr><td style="background:#0e0d0f;border-radius:12px 12px 0 0;padding:20px 32px;font-family:Arial,Helvetica,sans-serif;font-size:20px;font-weight:bold;color:#ffffff;letter-spacing:.2px">' +
      'sofort <span style="color:#b47ed3">sichtbar</span></td></tr>' +
      '<tr><td style="background:#ffffff;padding:32px;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.6;color:#2b2730">' +
      html.join("") + "</td></tr>" +
      '<tr><td style="padding:20px 32px 8px;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.6;color:#7a7480">' +
      "Du bekommst diesen Newsletter von sofort sichtbar. Du kannst ihm jederzeit widersprechen: " +
      '<a href="' + esc(abmelden) + '" style="color:#7a7480;text-decoration:underline">Newsletter abbestellen</a>.<br>' +
      "empiria GmbH · Kapellengasse 6 · 74564 Crailsheim · HRB 750146, Amtsgericht Ulm · vertreten durch Daniel Ströbel<br>" +
      '<a href="' + basis + '/impressum" style="color:#7a7480">Impressum</a> · <a href="' + basis + '/datenschutzerklarung" style="color:#7a7480">Datenschutz</a>' +
      "</td></tr></table></td></tr></table></body></html>";

    var txt = text.join("\n\n") +
      "\n\n--\nDu bekommst diesen Newsletter von sofort sichtbar. Abbestellen: " + abmelden +
      "\nempiria GmbH · Kapellengasse 6 · 74564 Crailsheim · HRB 750146, Amtsgericht Ulm · vertreten durch Daniel Ströbel" +
      "\nImpressum: " + basis + "/impressum · Datenschutz: " + basis + "/datenschutzerklarung";

    return { html: dok, text: txt, links: links, betreff: betreff, abmelden: abmelden };
  }

  g.nlRender = { render: render, platzhalter: platzhalter, slug: slug, FELDER: FELDER };
})(typeof window !== "undefined" ? window : globalThis);
