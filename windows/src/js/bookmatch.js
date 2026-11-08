// Vad en fil som läggs till är (G3), samma regler som BookMatcher i App/Library/BookRegistry.swift. På
// iPaden ligger böckerna i en mapp som syns i Filer, och platsen i mappen avgör. Windows-appen kopierar in
// filerna, så där har namnet på filen som läggs till (file_name) platsens roll. Ren logik, testad i
// tests/bookmatch.test.mjs.

const IGNORED = new Set(['ocr', 'ny', 'nya', 'version', 'ver', 'v', 'kopia', 'copy', 'final', 'slutlig']);

const extensionOf = (name) => {
  const ext = String(name).split('.').pop().toLowerCase();
  if (ext === 'markdown') return 'md';
  if (ext === 'htm') return 'html';
  return ext;
};
const stem = (name) => String(name).replace(/\.[^.]+$/, '');
const sameName = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const hashOf = (record) => record.sha256 || record.id;

/** Titeln utan skiftläge, skiljetecken, siffror och ord som "OCR", "ny" och "version" (som normalizedTitle). */
export function normalizedTitle(title) {
  return String(title).toLowerCase()
    .split(/[^\p{L}\p{M}\p{N}]+/u)
    .filter((word) => word && !IGNORED.has(word) && !/^\p{N}+$/u.test(word))
    // "v2", "v3": versionsnummer.
    .filter((word) => !/^v\p{N}+$/u.test(word))
    .join(' ');
}

/** Liknande namn: samma filtyp och samma titel efter normalizedTitle. "Bok.pdf" och "Bok (OCR) 2.pdf". */
export function isSimilar(record, name) {
  if (extensionOf(record.fileName) !== extensionOf(name)) return false;
  const a = normalizedTitle(stem(record.fileName));
  const b = normalizedTitle(stem(name));
  if ([...a].length < 4 || [...b].length < 4) return a === b && a !== '';
  return a === b;
}

/**
 * Vad filen `name` med kontrollsumman `sha256` är, bland bokregistrets rader (även borttagna, missing).
 *  exists      samma innehåll som en bok i biblioteket: ingen ny fil, Boken finns redan
 *  nameTaken   en annan bok i biblioteket heter likadant: Ersätt (med eller utan markeringarna), Behåll båda, Avbryt
 *  restore     samma innehåll som en bok som tagits bort: den kommer tillbaka med sitt id
 *  newVersion  samma eller liknande namn som en bok som tagits bort: Ny version av boken, behåll markeringarna?
 *  new         en ny bok
 */
export function matchFile({ name, sha256 }, records) {
  const present = records.filter((record) => !record.missing);
  const absent = records.filter((record) => record.missing);
  const same = present.find((record) => hashOf(record) === sha256);
  if (same) return { kind: 'exists', book: same };
  const named = present.find((record) => sameName(record.fileName, name));
  if (named) return { kind: 'nameTaken', book: named };
  // Böcker som tagits bort: samma innehåll (helst med samma namn), annars samma eller liknande namn.
  const back = absent.filter((record) => hashOf(record) === sha256)
    .sort((a, b) => Number(sameName(b.fileName, name)) - Number(sameName(a.fileName, name)))[0];
  if (back) return { kind: 'restore', book: back };
  const version = absent.find((record) => sameName(record.fileName, name)) ?? absent.find((record) => isSimilar(record, name));
  if (version) return { kind: 'newVersion', book: version };
  return { kind: 'new' };
}

/** Namnet för Behåll båda: "Bok 2.pdf", "Bok 3.pdf" ... som ingen annan rad har. */
export function uniqueName(name, records) {
  const dot = String(name).lastIndexOf('.');
  const base = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  for (let number = 2; ; number += 1) {
    const candidate = `${base} ${number}${ext}`;
    if (!records.some((record) => sameName(record.fileName, candidate))) return candidate;
  }
}
