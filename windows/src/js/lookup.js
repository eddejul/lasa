// Uppslag i ordboksdatabasen, på samma sätt som tools/dictionary/lookup.py.
//
// Logiken finns i tre kopior: tools/dictionary/lookup.py (testrapporten), App/Dictionary/WordDictionary.swift
// (iPaden) och den här filen (Windows-appen). Ändras en av dem ska de andra ändras i samma commit.
// windows/tests/parity.mjs kör den här filen och lookup.py över hela testlistan och jämför svaren.
//
// Databasen nås genom ett objekt med en metod all(sql, params), som ger raderna som listor
// (en lista per rad, kolumnerna i frågans ordning). I appen går frågorna till Rust, i provningen
// till en lokal server eller till node:sqlite.

export const SV_POS_NAMES = {
  nn: 'substantiv', vb: 'verb', av: 'adjektiv', ab: 'adverb', pp: 'preposition',
  pn: 'pronomen', kn: 'konjunktion', sn: 'subjunktion', in: 'interjektion',
  nl: 'räkneord', al: 'artikel', ie: 'infinitivmärke',
};
export const EN_POS_NAMES = {
  n: 'substantiv', v: 'verb', a: 'adjektiv', r: 'adverb', pp: 'preposition',
  pn: 'pronomen', kn: 'konjunktion', in: 'interjektion', rg: 'räkneord',
  article: 'artikel', abbrev: 'förkortning', pc: 'particip', ie: 'infinitivmärke',
};
// Ordklasser i den ordning de visas när ett ord kan vara flera.
const SV_POS_ORDER = ['vb', 'nn', 'av', 'ab', 'pp', 'kn', 'sn', 'pn', 'nl', 'in', 'al', 'ie'];
const EN_POS_ORDER = ['v', 'n', 'a', 'r'];

// Reglerna för engelska böjningar, som WordNets morphy. [ändelse, ersättning, ordklass]
const EN_RULES = [
  ['s', '', 'n'], ['ses', 's', 'n'], ['xes', 'x', 'n'], ['zes', 'z', 'n'], ['ches', 'ch', 'n'],
  ['shes', 'sh', 'n'], ['men', 'man', 'n'], ['ies', 'y', 'n'],
  ['s', '', 'v'], ['ies', 'y', 'v'], ['es', 'e', 'v'], ['es', '', 'v'], ['ed', 'e', 'v'],
  ['ed', '', 'v'], ['ing', 'e', 'v'], ['ing', '', 'v'],
  ['er', '', 'a'], ['est', '', 'a'], ['er', 'e', 'a'], ['est', 'e', 'a'], ['ier', 'y', 'a'], ['iest', 'y', 'a'],
];

export const SCHEMA_VERSION = 2;
export const MAX_SENSES = 8;
export const MAX_SYNONYMS = 12;
export const MAX_TRANSLATIONS = 6;
// Så många synonymer visas direkt. Resten finns bakom ett klick.
export const TOP_SYNONYMS = 5;
// Ord under den här vanligheten (Zipf, wordfreq) märks som ovanliga och visas sist.
export const RARE_ZIPF = 2.0;
// Hur mycket vanligheten väger mot Synlex-betyget när svenska synonymer sorteras.
const SV_FREQ_WEIGHT = 0.5;
// Översättningar ur Folkets svensk-engelska del (omvända) har rank från och med det här.
const REVERSED_RANK = 500;
// Engelska ord utan egen översättning lånar den från en synonym i någon av de första betydelserna.
const BORROW_SENSES = 3;

const ALNUM_START = /^[^\p{L}\p{N}]+/u;
const ALNUM_END = /[^\p{L}\p{N}]+$/u;

/** Samma som normalize() i lookup.py: NFKC, raka apostrofer, utan mjukt bindestreck, gemener,
 *  och utan skiljetecken runt ordet (men kvar inne i det, som i e-post och don't). */
export function normalize(word) {
  let text = String(word).normalize('NFKC').replaceAll('’', "'").replaceAll('­', '');
  text = text.trim().toLowerCase();
  return text.replace(ALNUM_START, '').replace(ALNUM_END, '');
}

/** Jämför två listor som Python jämför tupler: element för element. */
function compareKeys(a, b) {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const x = a[i];
    const y = b[i];
    if (x === y) continue;
    if (typeof x === 'boolean' || typeof x === 'number') {
      return Number(x) < Number(y) ? -1 : 1;
    }
    return x < y ? -1 : 1;
  }
  return a.length - b.length;
}

function sortBy(items, key) {
  return items
    .map((item, index) => ({ item, key: key(item), index }))
    .sort((p, q) => compareKeys(p.key, q.key) || p.index - q.index)
    .map((pair) => pair.item);
}

/** Ordning för betydelserna. Par utan känd betydelse (tom sense_id) kommer sist. */
function senseNumber(senseId) {
  const at = senseId.lastIndexOf('..');
  if (at < 0) return 10000;
  const tail = senseId.slice(at + 2).trim();
  if (!/^[+-]?\d+$/.test(tail)) return 10000;
  return parseInt(tail, 10);
}

/** Vanliga först (sorterade), ovanliga sist. */
function ordered(synonyms, key) {
  const common = sortBy(synonyms.filter((s) => s.freq >= RARE_ZIPF), key);
  const rare = sortBy(synonyms.filter((s) => s.freq < RARE_ZIPF), key);
  return common.concat(rare);
}

const svSynonymKey = (s) => [-(s.score + SV_FREQ_WEIGHT * s.freq), s.word];
const enSynonymKey = (s) => [-s.freq, s.word];

/** Nyckeln för ett dolt synonympar. */
export function hiddenKey(language, lemma, synonym) {
  return `${language}\u0000${lemma}\u0000${synonym}`;
}

const chars = (text) => Array.from(text);

export class Dictionary {
  /** db: { all(sql, params) -> Promise<Array<Array>> } */
  constructor(db) {
    this.db = db;
    this.cache = new Map();
  }

  /** Frågorna ger alltid samma svar (ordboken ändras aldrig), så de sparas en stund. */
  async rows(sql, params) {
    const key = sql + '\u0001' + JSON.stringify(params);
    const hit = this.cache.get(key);
    if (hit) return hit;
    const result = await this.db.all(sql, params);
    if (this.cache.size > 4000) this.cache.clear();
    this.cache.set(key, result);
    return result;
  }

  async meta() {
    const rows = await this.rows('SELECT key, value FROM meta', []);
    return Object.fromEntries(rows);
  }

  // Svenska

  async svLemmas(key) {
    return this.rows('SELECT lemma, pos FROM sv_forms WHERE form = ?', [key]);
  }

  async svEntry(lemma, pos, hidden = new Set()) {
    const synonyms = new Map();
    for (const [senseId, synonym, score, freq] of await this.rows(
      'SELECT sense_id, synonym, score, freq FROM sv_synonyms WHERE lemma = ? AND pos = ?', [lemma, pos])) {
      if (hidden.has(hiddenKey('sv', lemma, synonym))) continue;
      if (!synonyms.has(senseId)) synonyms.set(senseId, []);
      synonyms.get(senseId).push({ word: synonym, score, freq });
    }
    const definitions = new Map();
    const loose = []; // definitioner utan känd betydelse
    for (const [senseId, definition] of await this.rows(
      'SELECT sense_id, definition FROM sv_definitions WHERE lemma = ? AND pos = ? ORDER BY rank', [lemma, pos])) {
      if (senseId && !definitions.has(senseId)) definitions.set(senseId, definition);
      else if (!senseId && !loose.includes(definition)) loose.push(definition);
    }

    // Betydelser med nummer först (synonymer och definition ihop), sedan lösa definitioner,
    // sist synonymer utan känd betydelse. Lika nummer sorteras på id, så att ordningen alltid är densamma.
    const ids = new Set([...synonyms.keys(), ...definitions.keys()].filter((s) => s));
    const numbered = sortBy([...ids], (id) => [senseNumber(id), id]);
    const senses = [];
    for (const senseId of numbered) {
      const list = ordered(synonyms.get(senseId) ?? [], svSynonymKey);
      senses.push({ id: senseId, definition: definitions.get(senseId) ?? null, synonyms: list.slice(0, MAX_SYNONYMS) });
    }
    loose.forEach((definition, index) => {
      // En lös definition på ett ord med en enda betydelse hör till den.
      if (senses.length === 1 && !senses[0].definition) {
        senses[0].definition = definition;
        return;
      }
      senses.push({ id: `definition..${index}`, definition, synonyms: [] });
    });
    if (synonyms.get('')?.length) {
      senses.push({ id: '', definition: null, synonyms: ordered(synonyms.get(''), svSynonymKey).slice(0, MAX_SYNONYMS) });
    }
    return {
      lemma, pos, posName: SV_POS_NAMES[pos] ?? '',
      senses: senses.slice(0, MAX_SENSES), translations: [], via: null,
    };
  }

  async lookupSv(word, hidden = new Set()) {
    const key = normalize(word);
    if (!key) return null;
    let lemmas = await this.svLemmas(key);
    let compound = null;
    if (!lemmas.length) {
      compound = await this.splitCompound(key);
      if (compound) lemmas = await this.svLemmas(compound[1]);
    }
    if (!lemmas.length) return null;
    const entries = [];
    for (const [lemma, pos] of lemmas) entries.push(await this.svEntry(lemma, pos, hidden));
    // Ord med innehåll först, sedan grundformen själv, sedan flest synonymer (ett mått på
    // hur vanlig ordklassen är), sedan ordklassernas fasta ordning.
    const sorted = sortBy(entries, (entry) => [
      entry.senses.length === 0,
      normalize(entry.lemma) !== key,
      -entry.senses.reduce((sum, sense) => sum + sense.synonyms.length, 0),
      SV_POS_ORDER.includes(entry.pos) ? SV_POS_ORDER.indexOf(entry.pos) : 99,
      entry.lemma,
    ]);
    return { language: 'sv', word, key, compound, entries: sorted };
  }

  /** Sammansatta ord som inte finns i SALDO, som kurslitteraturläsning: kurslitteratur + läsning.
   *  Efterledet bestämmer betydelsen. Det längsta efterledet som finns, med ett förled som också
   *  finns (eventuellt med foge-s), vinner. */
  async splitCompound(key) {
    const letters = chars(key);
    if (letters.length < 7) return null;
    for (let split = 3; split < letters.length - 3; split++) {
      const head = letters.slice(0, split).join('');
      const tail = letters.slice(split).join('');
      if (!(await this.svLemmas(tail)).length) continue;
      if ((await this.svLemmas(head)).length) return [head, tail];
      if (head.endsWith('s') && chars(head).length > 3 && (await this.svLemmas(chars(head).slice(0, -1).join(''))).length) {
        return [head, tail];
      }
    }
    return null;
  }

  // Engelska

  async enForms(key) {
    return this.rows('SELECT lemma, pos FROM en_forms WHERE form = ?', [key]);
  }

  /** [grundform, ordklass] för en engelsk form: först formtabellen, sedan reglerna. */
  async enCandidates(key) {
    const found = [];
    const add = (rows, pos = null) => {
      for (const [lemma, rowPos] of rows) {
        if (pos && rowPos !== pos) continue;
        if (!found.some(([l, p]) => l === lemma && p === rowPos)) found.push([lemma, rowPos]);
      }
    };
    add(await this.enForms(key));
    const baseKey = key.endsWith("'s") ? chars(key).slice(0, -2).join('') : key;
    if (baseKey !== key) add(await this.enForms(baseKey));
    const baseChars = chars(baseKey);
    for (const [suffix, replacement, pos] of EN_RULES) {
      if (!baseKey.endsWith(suffix) || baseChars.length <= suffix.length + 1) continue;
      const stem = baseChars.slice(0, baseChars.length - suffix.length).join('') + replacement;
      let rows = await this.enForms(stem);
      const stemChars = chars(stem);
      const last = stemChars[stemChars.length - 1];
      if (!rows.some((r) => r[1] === pos) && !replacement && stemChars.length > 2
          && last === stemChars[stemChars.length - 2] && !'aeiouy'.includes(last)) {
        // stopped, stopping, bigger: dubbelteckning. Bara om formen utan den inte redan finns (filled).
        rows = await this.enForms(stemChars.slice(0, -1).join(''));
      }
      add(rows, pos);
    }
    return found;
  }

  /** Folkets egna översättningar först. Finns inga används de omvända (svensk-engelska delen). */
  async enTranslations(lemma, pos) {
    const rows = await this.rows(
      'SELECT sv, comment, rank FROM en_sv WHERE en_lemma = ? AND pos = ? ORDER BY rank', [normalize(lemma), pos]);
    const direct = rows.filter((r) => r[2] < REVERSED_RANK).map(([sv, comment]) => ({ text: sv, comment }));
    const chosen = direct.length ? direct
      : rows.filter((r) => r[2] >= REVERSED_RANK).map(([sv, comment]) => ({ text: sv, comment }));
    const seen = new Set();
    const unique = [];
    for (const translation of chosen) {
      if (seen.has(translation.text)) continue;
      seen.add(translation.text);
      unique.push(translation);
    }
    return unique.slice(0, MAX_TRANSLATIONS);
  }

  async enEntry(lemma, pos, hidden = new Set()) {
    const senses = [];
    const rows = await this.rows(
      'SELECT s.synset_id, d.definition FROM en_senses s JOIN en_synsets d ON d.synset_id = s.synset_id '
      + 'WHERE s.lemma = ? AND s.pos = ? ORDER BY s.rank', [lemma, pos]);
    for (const [synsetId, definition] of rows.slice(0, MAX_SENSES)) {
      const members = (await this.rows(
        'SELECT lemma, freq FROM en_synset_members WHERE synset_id = ? ORDER BY rank', [synsetId]))
        .filter(([m]) => m.toLowerCase() !== lemma.toLowerCase() && !hidden.has(hiddenKey('en', lemma, m)))
        .map(([m, f]) => ({ word: m, score: null, freq: f }));
      senses.push({ id: synsetId, definition, synonyms: ordered(members, enSynonymKey).slice(0, MAX_SYNONYMS) });
    }

    let translations = await this.enTranslations(lemma, pos);
    let via = null;
    if (!translations.length) {
      // Lånad översättning: exceedingly saknas i Folkets lexikon, men extremely (samma betydelse) finns.
      search: for (const sense of senses.slice(0, BORROW_SENSES)) {
        for (const member of sense.synonyms) {
          const borrowed = await this.enTranslations(member.word, pos);
          if (borrowed.length) {
            translations = borrowed.slice(0, 4);
            via = member.word;
            break search;
          }
        }
      }
    }
    return { lemma, pos, posName: EN_POS_NAMES[pos] ?? '', senses, translations, via };
  }

  async lookupEn(word, hidden = new Set(), preferredPos = null) {
    const key = normalize(word);
    if (!key) return null;
    const candidates = await this.enCandidates(key);
    if (!candidates.length) return null;
    let entries = [];
    for (const [lemma, pos] of candidates) entries.push(await this.enEntry(lemma, pos, hidden));
    const withContent = entries.filter((e) => e.senses.length || e.translations.length);
    if (withContent.length) entries = withContent;
    const sorted = sortBy(entries, (entry) => [
      preferredPos ? entry.pos !== preferredPos : false,
      !entry.senses.length && !entry.translations.length,
      !entry.translations.length,
      normalize(entry.lemma) !== key,
      EN_POS_ORDER.includes(entry.pos) ? EN_POS_ORDER.indexOf(entry.pos) : 99,
      entry.lemma,
    ]);
    return { language: 'en', word, key, compound: null, entries: sorted };
  }

  /** Vilka språk ordet finns i: [svenska, engelska]. */
  async has(word) {
    const key = normalize(word);
    return [(await this.svLemmas(key)).length > 0, (await this.enCandidates(key)).length > 0];
  }

  /** Slår upp ett ord ur texten. Finns det bara i ett språk blir det det språket, finns det i båda
   *  avgör meningen (guess), och oavgjort blir svenska. Samma flöde som WordDictionary.lookup på iPaden.
   *  Svaret säger också om ordet finns i det andra språket, så att rutan kan erbjuda ett byte. */
  async lookup(word, { sentence = '', language = null, hidden = new Set(), guess = null, preferredPos = null } = {}) {
    const key = normalize(word);
    if (!key) return null;
    const [inSwedish, inEnglish] = await this.has(word);
    let chosen = language;
    if (!chosen) {
      if (inSwedish && inEnglish) chosen = guess ? guess(sentence) : 'sv';
      else if (inEnglish) chosen = 'en';
      else chosen = 'sv';
    }
    const result = chosen === 'en' ? await this.lookupEn(word, hidden, preferredPos) : await this.lookupSv(word, hidden);
    if (!result) return null;
    result.otherLanguageAvailable = chosen === 'en' ? inSwedish : inEnglish;
    return result;
  }

  async counts() {
    const one = async (sql) => (await this.db.all(sql, []))[0]?.[0] ?? 0;
    return {
      swedishWords: await one('SELECT COUNT(DISTINCT lemma) FROM sv_forms'),
      swedishPairs: await one('SELECT COUNT(*) FROM sv_synonyms'),
      swedishDefinitions: await one('SELECT COUNT(*) FROM sv_definitions'),
      englishWords: await one('SELECT COUNT(DISTINCT lemma) FROM en_senses'),
      translations: await one('SELECT COUNT(*) FROM en_sv'),
    };
  }
}
