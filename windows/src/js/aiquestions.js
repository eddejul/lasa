// AI-frågorna (K6b): logiken utan sidor och anrop. Kravet är docs/AI-FRAGOR.md, och facit är
// tools/simtest/ai-fragor/referens.py med fixturen fixtur-1.json (windows/tests/aiquestions.test.mjs). Frågan
// till modellen, Jämförs fråga, schemana, kontrollen och id:na ska bli exakt som där, och som på iPaden.
// Ändras en regel: ändra referens.py, kör om den och rätta båda apparna i samma commit.

import { foldText } from './search.js';

/** Frågetyperna i schemats ordning, med namnet som visas i rutan. */
export const TYPES = [
  ['huvudpoang', 'Huvudpoäng'], ['egna_ord', 'Med egna ord'], ['svar_mening', 'Svår mening'], ['vems_rost', 'Vems röst'],
  ['varfor', 'Varför'], ['uppgift', 'Styckets uppgift'], ['koppling', 'Koppling bakåt'], ['skillnad', 'Skillnad'],
  ['tillampa', 'Tillämpa'], ['falla', 'Fälla'], ['belagg', 'Belägg'], ['kritisk', 'Kritisk'], ['anvand', 'Använd det'],
  ['sammanfatta', 'Sammanfatta'], ['annan_bok', 'Koppling till en annan bok'], ['verkligheten', 'Till verkligheten'],
  ['foljder', 'Följder'], ['gransen', 'Gränsen'], ['overforing', 'Överföring'], ['debatt', 'Debatt'], ['syntes', 'Syntes'],
];
export const TYPE_IDS = TYPES.map(([id]) => id);
export const TYPE_NAMES = Object.fromEntries(TYPES);
/** Öppna typer: inget rätt svar, Jämför ger en kommentar. */
export const OPEN_TYPES = new Set(['kritisk', 'anvand', 'annan_bok', 'verkligheten', 'foljder', 'gransen', 'overforing',
  'debatt', 'syntes']);
const WITHOUT_SOURCE = new Set(['sammanfatta', 'syntes']);
export const WHEN = ['fore', 'efter', 'slut'];
export const DISTANCE = 400;
/** Typen i de sparade svaren. */
export const KIND_QUESTIONS = 'fragor-1';
export const KIND_COMPARE = 'jamfor-1';
/** Kapitel under så många tecken får inga frågor (omslag, innehåll, tack). */
export const MIN_CHAPTER = 1500;
/** Kapitel över så många tecken delas, i delar om ungefär PART_SIZE. */
export const SPLIT_OVER = 40000;
export const PART_SIZE = 36000;

/** Namnet i rutan: typens namn, och för annan_bok "Koppling till <bok>". */
export function typeName(question) {
  if (question?.typ === 'annan_bok' && question.bok) return `Koppling till ${question.bok}`;
  return TYPE_NAMES[question?.typ] ?? 'Fråga';
}

// Typografiska citattecken och streck som raka, ett tecken mot ett (LOSA i referens.py).
const LOOSE = new Map();
for (const c of '‘’‚‛′´`') LOOSE.set(c, "'");
for (const c of '“”„‟″«»') LOOSE.set(c, '"');
for (const c of '–—‒―−') LOOSE.set(c, '-');
const loosen = (text) => {
  let out = '';
  for (const c of text) out += LOOSE.get(c) ?? c;
  return out;
};

/** Vikt som FoldedText och fold i search.js, utan mellanslag i början och slutet (fraga_vikt). */
export function foldedQuery(text) {
  return foldText(String(text ?? '')).text.replace(/^ +| +$/g, '');
}

/** Slutet (index i texten, exklusive) för citatets första träff, eller null. Först strikt, sedan löst. */
export function locate(quote, text) {
  for (const loose of [false, true]) {
    const k = loose ? loosen(text) : text;
    const c = loose ? loosen(quote) : quote;
    const folded = foldText(k);
    const q = foldedQuery(c);
    if (q.length < 2) return null;
    const at = folded.text.indexOf(q);
    if (at >= 0) return folded.map[at + q.length - 1] + 1;
  }
  return null;
}

/** Orden i den vikta texten: följder av bokstäver och siffror. */
export function wordList(text) {
  return foldText(String(text ?? '')).text.match(/[\p{L}\p{N}]+/gu) ?? [];
}

function copied(question, chapterWords, n = 6) {
  const words = wordList(question);
  if (words.length < n) return false;
  const runs = new Set();
  for (let i = 0; i + n <= chapterWords.length; i++) runs.add(chapterWords.slice(i, i + n).join('\u0001'));
  for (let i = 0; i + n <= words.length; i++) if (runs.has(words.slice(i, i + n).join('\u0001'))) return true;
  return false;
}

/** FNV-1a 64 över UTF-8 (som stableHash i BookQuestions.swift). */
export function fnv(text) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash;
}

/** Frågans id: "ai" och base36 av FNV-1a över "<bok>|<kapitel>|<del>|<nar>|<fråga>". */
export function questionId(bookId, chapterKey, part, when, question) {
  return `ai${fnv(`${bookId}|${chapterKey}|${part}|${when}|${question}`).toString(36)}`;
}

// Pythons round() avrundar x,5 till jämnt tal, och antal() ska räkna lika.
function roundHalfEven(x) {
  const floor = Math.floor(x);
  const diff = x - floor;
  if (diff > 0.5) return floor + 1;
  if (diff < 0.5) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}

/** Antalet frågor för en del med `chars` tecken (antal() i referens.py). */
export function count(chars, last = false) {
  const after = Math.min(Math.max(roundHalfEven(chars / 3500), 2), 10);
  const fore = chars >= 8000 ? 2 : 1;
  const links = chars >= 8000 ? 2 : 1;
  return { efter: after, fore, kopplingar: links, slut: 1 + links + (last ? 1 : 0) };
}

/** Antalet för en del: fore bara i kapitlets första del, slut och kopplingarna bara i den sista. */
export function partCount(chars, { firstPart = true, lastPart = true, lastChapter = false } = {}) {
  const tal = count(chars, lastChapter);
  if (!firstPart) tal.fore = 0;
  if (!lastPart) {
    tal.slut = 0;
    tal.kopplingar = 0;
  }
  return tal;
}

/** Taket efter kontrollen. fore och slut är 0 i delar där de inte ska finnas (se rapporten). */
export function capFor(tal) {
  return { fore: tal.fore > 0 ? 2 : 0, efter: tal.efter + 2, slut: tal.slut > 0 ? 4 : 0 };
}

const countText = (n) => (n === 1 ? '1 fråga' : `${n} frågor`);

/** Frågan till modellen, tecken för tecken som bygg_prompt i referens.py.
 *  book { titel, forfattare }, chapter { rubrik, del, delar, text, sista }, earlier [{ rubrik, sammanfattning }],
 *  others [{ titel, sammanfattning, begrepp }], tal som partCount(). */
export function buildPrompt(book, chapter, earlier, others, tal) {
  const author = book.forfattare ? `, av ${book.forfattare}` : '';
  const partLine = chapter.delar > 1 ? ` (del ${chapter.del} av ${chapter.delar})` : '';
  const earlierLines = earlier.slice(-12).map((t) => `- ${t.rubrik}: ${t.sammanfattning}`).join('\n') || 'Inga.';
  const otherLines = others.slice(0, 5).map((b) => {
    let line = `- ${b.titel}: ${b.sammanfattning}`;
    if (b.begrepp?.length) line += ` Begrepp: ${b.begrepp.slice(0, 8).join(', ')}.`;
    return line;
  });
  const otherText = otherLines.join('\n') || 'Inga.';
  const lineB = tal.fore > 0
    ? `b) ${countText(tal.fore)} med "nar": "fore": det viktigaste läsaren ska ha i huvudet medan hen läser. "plats" lämnas tom.`
    : 'b) Inga frågor med "nar": "fore".';
  let lineC = 'c) Inga frågor med "nar": "slut".';
  if (tal.slut > 0) {
    const synthesis = chapter.sista
      ? ' Det här är bokens sista kapitel: lägg till en fråga av typen syntes om hur bokens viktigaste idéer hänger ihop.'
      : '';
    lineC = `c) ${countText(tal.slut)} med "nar": "slut": en av typen sammanfatta, och ${countText(tal.kopplingar)} som kräver `
      + 'större kopplingar än texten, av typerna annan_bok, verkligheten, foljder, gransen, overforing eller debatt. '
      + 'annan_bok och debatt mellan böcker får bara gälla böckerna i listan ovan, med titeln exakt som där i "bok".'
      + `${synthesis} "plats" lämnas tom.`;
  }
  return [
    'Du gör frågor som hjälper en läsare att förstå och minnas en bok. Läsaren svarar ur minnet, med egna ord, efter att '
      + 'ha läst avsnittet.',
    '',
    `Bok: ${book.titel}${author}`,
    `Kapitel: ${chapter.rubrik}${partLine}`,
    '',
    'Tidigare kapitel i boken:',
    earlierLines,
    '',
    'Andra böcker som läsaren har läst:',
    otherText,
    '',
    'Gör så här.',
    '1. "sammanfattning": kapitlets huvudpoäng i högst tre meningar.',
    '2. "begrepp": högst åtta viktiga begrepp eller namn ur kapitlet, skrivna som i texten.',
    '3. "fragor":',
    `a) ${countText(tal.efter)} med "nar": "efter", spridda jämnt över hela texten. Varje fråga gäller ett avsnitt. "plats" `
      + 'är 4 till 10 ord som står ordagrant i avsnittets sista mening, så att frågan visas när avsnittet är läst.',
    lineB,
    lineC,
    '4. Välj typ efter vad avsnittet bär: ett begrepp ger egna_ord eller skillnad, ett argument varfor eller belagg, en '
      + 'återgiven åsikt vems_rost, ett svårt ställe svar_mening. Blanda typerna.',
    '5. Skriv frågan med andra ord än boken. Upprepa aldrig fem ord i rad ur texten.',
    '6. "svar": två eller tre korta kärnpunkter med egna ord, som ett bra svar innehåller. För en öppen fråga ("oppen": '
      + 'true): vad boken säger som läsaren kan ställa sitt svar mot.',
    '7. "kalla": 5 till 30 ord som står ordagrant i texten, där svaret står. Kopiera tecken för tecken, utan att ändra, '
      + 'korta eller översätta. Lämna "kalla" tom bara när svaret inte står i texten.',
    '8. Skriv frågor, svar och sammanfattning på svenska, även när boken är på ett annat språk. "plats", "kalla" och '
      + '"begrepp" står på bokens språk, precis som i texten.',
    '9. Fråga inte efter sidnummer, årtal, namn eller detaljer som inte hjälper förståelsen.',
    '',
    'Kapitlets text:',
    '<text>',
    chapter.text,
    '</text>',
  ].join('\n');
}

/** Frågan när läsarens svar jämförs (bygg_jamfor). Kapitlets text skickas aldrig med. */
export function buildCompare(question, myAnswer) {
  const points = (question.svar ?? []).map((s) => `- ${s}`).join('\n') || '- (inga punkter)';
  const source = question.kalla ? `"${question.kalla}"` : 'Inget citat.';
  const end = question.oppen
    ? 'Frågan är öppen och har inget rätt svar. Skriv i "kommentar" om resonemanget håller och vad boken säger, och '
      + 'lämna "fel" tom om inget strider mot boken. Säg tydligt när något i kommentaren kommer från dig och inte från boken.'
    : 'Lista i "med" det läsaren fick med, i "saknas" det som saknas och i "fel" det som strider mot boken. "kommentar" '
      + 'är en mening.';
  return [
    'Du bedömer en läsares svar på en fråga om en bok. Bedöm innehållet, inte orden: samma sak med andra ord räknas som '
      + 'rätt. Var vänlig och konkret, och skriv på svenska.',
    '',
    `Fråga: ${question.fraga}`,
    'Ett bra svar innehåller:',
    points,
    `Ur boken: ${source}`,
    `Läsarens svar: ${String(myAnswer ?? '').trim()}`,
    '',
    end,
  ].join('\n');
}

export const SCHEMA_QUESTIONS = {
  type: 'object',
  properties: {
    sammanfattning: { type: 'string' },
    begrepp: { type: 'array', items: { type: 'string' } },
    fragor: { type: 'array', items: {
      type: 'object',
      properties: {
        typ: { type: 'string', enum: TYPE_IDS },
        nar: { type: 'string', enum: WHEN },
        fraga: { type: 'string' },
        svar: { type: 'array', items: { type: 'string' } },
        oppen: { type: 'boolean' },
        plats: { type: 'string' },
        kalla: { type: 'string' },
        bok: { type: 'string' },
      },
      required: ['typ', 'nar', 'fraga', 'svar', 'oppen', 'plats', 'kalla'],
    } },
  },
  required: ['sammanfattning', 'begrepp', 'fragor'],
};

export const SCHEMA_COMPARE = {
  type: 'object',
  properties: {
    med: { type: 'array', items: { type: 'string' } },
    saknas: { type: 'array', items: { type: 'string' } },
    fel: { type: 'array', items: { type: 'string' } },
    omdome: { type: 'string', enum: ['bra', 'delvis', 'saknas_mycket'] },
    kommentar: { type: 'string' },
  },
  required: ['med', 'saknas', 'fel', 'omdome', 'kommentar'],
};

const str = (value) => (value === undefined || value === null ? '' : String(value)).trim();
const lines = (value) => {
  const list = Array.isArray(value) ? value : (value === undefined || value === null ? [] : [value]);
  return list.map(str).filter(Boolean);
};

/** Kontrollen (kontrollera i referens.py). answer är modellens svar, text delens text, otherTitles de andra
 *  böckernas titlar och cap taket. Ger { kept, dropped } med kept i visningsordning (fore, efter, slut). */
export function check(answer, text, { bookId, chapterKey, part, otherTitles = [], cap }) {
  const chapterWords = wordList(text);
  const titles = new Set(otherTitles.map(foldedQuery));
  const kept = [];
  const dropped = [];
  const list = Array.isArray(answer?.fragor) ? answer.fragor : [];
  list.forEach((raw, nr) => {
    const f = raw && typeof raw === 'object' ? raw : {};
    const typ = str(f.typ);
    const nar = str(f.nar);
    const fraga = str(f.fraga);
    const svar = lines(f.svar);
    const oppen = Boolean(f.oppen) || OPEN_TYPES.has(typ);
    const plats = str(f.plats);
    let kalla = str(f.kalla);
    const bok = str(f.bok);
    const drop = (orsak) => dropped.push({ nr, fraga, orsak });
    if (!TYPE_IDS.includes(typ) || !WHEN.includes(nar)) return drop('typ');
    if (fraga.length < 8) return drop('fraga');
    if (!svar.length && !oppen) return drop('svar');
    let position = null;
    if (nar === 'efter') {
      position = plats ? locate(plats, text) : null;
      if (position === null) return drop('plats');
    }
    const needsSource = !oppen && !WITHOUT_SOURCE.has(typ);
    if (kalla) {
      if (locate(kalla, text) === null) {
        if (needsSource) return drop('kalla');
        kalla = '';
      }
    } else if (needsSource) {
      return drop('kalla');
    }
    if (copied(fraga, chapterWords)) return drop('kopierad');
    if ((typ === 'annan_bok' || (typ === 'debatt' && bok)) && !titles.has(foldedQuery(bok))) return drop('bok');
    kept.push({ nr, typ, nar, fraga, svar, oppen, plats: nar === 'efter' ? plats : '', kalla, bok, position });
    return undefined;
  });
  // Frågorna i texten i textens ordning, med avstånd.
  const after = kept.filter((f) => f.nar === 'efter').sort((a, b) => a.position - b.position || a.nr - b.nr);
  const keptAfter = [];
  let last = null;
  for (const f of after) {
    if (last !== null && f.position - last < DISTANCE) {
      dropped.push({ nr: f.nr, fraga: f.fraga, orsak: 'avstand' });
      continue;
    }
    keptAfter.push(f);
    last = f.position;
  }
  const order = [...kept.filter((f) => f.nar === 'fore'), ...keptAfter, ...kept.filter((f) => f.nar === 'slut')];
  const counted = { fore: 0, efter: 0, slut: 0 };
  const result = [];
  for (const f of order) {
    if (counted[f.nar] >= cap[f.nar]) {
      dropped.push({ nr: f.nr, fraga: f.fraga, orsak: 'tak' });
      continue;
    }
    counted[f.nar] += 1;
    f.id = questionId(bookId, chapterKey, part, f.nar, f.fraga);
    result.push(f);
  }
  dropped.sort((a, b) => a.nr - b.nr);
  return { kept: result, dropped };
}

/** Raden i konsolen, som "AI-frågor k3: 6 av 13 behölls (plats 1, kalla 1, ...)". */
export function checkSummary(chapterKey, kept, dropped) {
  const counts = new Map();
  for (const { orsak } of dropped) counts.set(orsak, (counts.get(orsak) ?? 0) + 1);
  const total = kept.length + dropped.length;
  const reasons = [...counts].map(([reason, n]) => `${reason} ${n}`).join(', ');
  return `AI-frågor ${chapterKey}: ${kept.length} av ${total} behölls${reasons ? ` (${reasons})` : ''}`;
}

/** Modellens svar med rätt form, eller null (då försöks det en gång till). */
export function validAnswer(answer) {
  if (!answer || typeof answer !== 'object' || !Array.isArray(answer.fragor)) return null;
  return {
    sammanfattning: str(answer.sammanfattning),
    begrepp: lines(answer.begrepp).slice(0, 8),
    fragor: answer.fragor,
  };
}

/** Jämförs svar med rätt form, eller null. */
export function validCompare(answer) {
  if (!answer || typeof answer !== 'object') return null;
  const omdome = ['bra', 'delvis', 'saknas_mycket'].includes(answer.omdome) ? answer.omdome : '';
  const result = { med: lines(answer.med), saknas: lines(answer.saknas), fel: lines(answer.fel), omdome,
    kommentar: str(answer.kommentar) };
  if (!result.kommentar && !result.med.length && !result.saknas.length && !result.fel.length) return null;
  return result;
}

/** Kapitlets nyckel: k<plats från 0> för EPUB och text, p<första>-<sista> (från 1) för PDF. */
export const chapterKeyFor = (chapter) => (chapter.pages ? `p${chapter.pages[0] + 1}-${chapter.pages[1] + 1}` : `k${chapter.index}`);

/** Var en lång text delas: [{ start, end }]. Över SPLIT_OVER tecken blir det ceil(längd / PART_SIZE) lika
 *  stora delar, vid närmaste tomma rad, annars radbrytning, annars mellanslag. */
export function splitParts(text) {
  const length = text.length;
  if (length <= SPLIT_OVER) return [{ start: 0, end: length }];
  const parts = Math.ceil(length / PART_SIZE);
  const size = length / parts;
  const cuts = [0];
  for (let i = 1; i < parts; i++) {
    const ideal = Math.round(i * size);
    const low = Math.max(cuts[cuts.length - 1] + 1, Math.round(ideal - size / 2));
    const high = Math.min(length - 1, Math.round(ideal + size / 2));
    let cut = null;
    for (const separator of ['\n\n', '\n', ' ']) {
      let best = null;
      let at = text.indexOf(separator, low);
      while (at >= 0 && at <= high) {
        const after = at + separator.length;
        if (best === null || Math.abs(after - ideal) < Math.abs(best - ideal)) best = after;
        if (at > ideal) break;
        at = text.indexOf(separator, at + 1);
      }
      if (best !== null) {
        cut = best;
        break;
      }
    }
    cuts.push(cut ?? ideal);
  }
  cuts.push(length);
  const result = [];
  for (let i = 0; i + 1 < cuts.length; i++) if (cuts[i + 1] > cuts[i]) result.push({ start: cuts[i], end: cuts[i + 1] });
  return result;
}
