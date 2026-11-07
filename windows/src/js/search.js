// Sök i boken (Ctrl och F): samma vikning av texten som iPaden (FoldedText i App/Annotations/BookSearch.swift),
// så att samma sökning ger samma träffar. Små och stora bokstäver räknas lika, mjuka bindestreck tas bort,
// blanktecken slås ihop till ett mellanslag, och ett ord avstavat vid radslut ("kun-" och "skap") hittas
// som ett ord. Positionerna räknas i UTF-16, som på iPaden.

export const MAX_HITS = 500;
const CONTEXT = 60;

const isLineBreak = (unit) => unit === 0x0a || unit === 0x0d || unit === 0x2028 || unit === 0x2029;
const isSpace = (unit) => unit === 0x20 || unit === 0x09 || unit === 0xa0 || isLineBreak(unit) || unit === 0x0b || unit === 0x0c;
const isHyphen = (unit) => unit === 0x2d || unit === 0x2010 || unit === 0x2011;
const isLowercaseLetter = (text, index) => /\p{Lowercase}/u.test(text[index]);

function lower(unit) {
  if (unit >= 0x41 && unit <= 0x5a) return unit + 32;
  if (unit < 0xc0 || (unit >= 0xd800 && unit <= 0xdfff)) return unit;
  const lowered = String.fromCharCode(unit).toLowerCase();
  return lowered.length === 1 ? lowered.charCodeAt(0) : unit;
}

/** Texten vikt för sökning, och för varje tecken i den var det står i originalet. */
export function foldText(original, { lowercase = true } = {}) {
  const units = [];
  const map = [];
  const length = original.length;
  let index = 0;
  while (index < length) {
    const unit = original.charCodeAt(index);
    if (unit === 0xad) {
      index += 1;
      continue;
    }
    if (isSpace(unit)) {
      if (units.length && units[units.length - 1] !== 0x20) {
        units.push(0x20);
        map.push(index);
      }
      index += 1;
      continue;
    }
    if (isHyphen(unit) && units.length && units[units.length - 1] !== 0x20) {
      // Avstavning vid radslut: streck, blanktecken med en radbrytning, och sedan en liten bokstav.
      let look = index + 1;
      let sawBreak = false;
      while (look < length && isSpace(original.charCodeAt(look))) {
        if (isLineBreak(original.charCodeAt(look))) sawBreak = true;
        look += 1;
      }
      if (sawBreak && look < length && isLowercaseLetter(original, look)) {
        index = look;
        continue;
      }
    }
    units.push(lowercase ? lower(unit) : unit);
    map.push(index);
    index += 1;
  }
  let text = '';
  for (let i = 0; i < units.length; i += 4096) text += String.fromCharCode(...units.slice(i, i + 4096));
  return { text, map };
}

/** Söktexten på samma form, utan mellanslag i början och slutet. */
export function foldQuery(query) {
  return foldText(String(query)).text.trim();
}

/** Alla träffar i en text: [början, slut) i originalet. */
export function findAll(original, needle, limit = MAX_HITS) {
  if (!needle) return [];
  const folded = foldText(original);
  const hits = [];
  let at = folded.text.indexOf(needle);
  while (at >= 0 && hits.length < limit) {
    const start = folded.map[at];
    const end = folded.map[Math.min(at + needle.length - 1, folded.map.length - 1)] + 1;
    hits.push([start, end]);
    at = folded.text.indexOf(needle, at + needle.length);
  }
  return hits;
}

/** Utdraget runt en träff: text före, träffen och text efter, med hopslagna blanktecken. */
export function excerpt(original, start, end) {
  const squeeze = (text) => text.replace(/­/g, '').replace(/\s+/g, ' ');
  const before = squeeze(original.slice(Math.max(0, start - CONTEXT * 2), start));
  const after = squeeze(original.slice(end, end + CONTEXT * 2));
  return {
    pre: (before.length > CONTEXT ? '…' : '') + before.slice(-CONTEXT).trimStart(),
    // Ett ord avstavat vid radslut visas helt i träffen ("kunskap", inte "kun- skap").
    match: squeeze(original.slice(start, end)).replace(/[-‐‑] (?=\p{Lowercase})/gu, ''),
    post: after.slice(0, CONTEXT).trimEnd() + (after.length > CONTEXT ? '…' : ''),
  };
}

/** Låter fönstret rita och ta emot klick mellan omgångarna. */
export const breathe = () => new Promise((resolve) => setTimeout(resolve, 0));
