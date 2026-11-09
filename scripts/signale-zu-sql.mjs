#!/usr/bin/env node
/**
 * Erzeugt aus daten/signale.csv die SQL-Zeilen für scoring.signals.
 *
 *   node scripts/signale-zu-sql.mjs > /tmp/werte.sql
 *
 * Die CSV ist die gepflegte Quelle. Änderungen an Gewichten laufen später
 * als neue Migration (dieses Script erneut ausführen, Upsert-Block einfügen),
 * nie per Klick in prod.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const pfad = join(dirname(fileURLToPath(import.meta.url)), "..", "daten", "signale.csv");
const text = readFileSync(pfad, "utf8").replace(/^﻿/, "");

/** Minimaler CSV-Parser: Kommas, Anführungszeichen, "" als Escape. */
function parse(csv) {
  const zeilen = [];
  let feld = "", zeile = [], inQuote = false;
  for (let i = 0; i < csv.length; i++) {
    const c = csv[i];
    if (inQuote) {
      if (c === '"' && csv[i + 1] === '"') { feld += '"'; i++; }
      else if (c === '"') inQuote = false;
      else feld += c;
    } else if (c === '"') inQuote = true;
    else if (c === ",") { zeile.push(feld); feld = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && csv[i + 1] === "\n") i++;
      zeile.push(feld); feld = "";
      if (zeile.some((f) => f !== "")) zeilen.push(zeile);
      zeile = [];
    } else feld += c;
  }
  if (feld !== "" || zeile.length) { zeile.push(feld); zeilen.push(zeile); }
  return zeilen;
}

const [kopf, ...daten] = parse(text);
const erwartet = ["Signal-ID", "Kanal", "API-Feld / Event", "Bedeutung", "Ebene", "Typ",
  "Gewicht", "Halbwertszeit (Tage)", "Kern-KPI", "Gilt für", "Hinweis für Agent", "Verfügbar ab"];
if (kopf.join("|") !== erwartet.join("|")) {
  console.error("Unerwarteter CSV-Kopf:\n" + kopf.join(" | "));
  process.exit(1);
}

const q = (s) => (s === "" ? "null" : "'" + s.replace(/'/g, "''") + "'");
const num = (s, id) => {
  if (!/^-?\d+(\.\d+)?$/.test(s)) { console.error(`Keine Zahl in ${id}: "${s}"`); process.exit(1); }
  return s;
};

const werte = daten.map((r) => {
  const [id, kanal, feld, bedeutung, ebene, typ, gewicht, hwz, kern, gilt, hinweis, ab] = r;
  return `  (${[q(id), q(kanal), q(feld), q(bedeutung), q(ebene), q(typ), num(gewicht, id), num(hwz, id),
    kern === "Ja" ? "true" : "false", q(gilt), q(hinweis), q(ab)].join(", ")})`;
});

process.stdout.write(werte.join(",\n") + "\n");
console.error(`${werte.length} Signale`);
