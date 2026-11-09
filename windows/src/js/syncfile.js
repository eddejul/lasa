// Synkfilerna (F1): formatet och sammanslagningen, samma som App/Sync/SyncFile.swift på iPaden. Formatet står i
// docs/SYNK.md. Ren logik utan filer och databaser, så att den går att pröva med node (tests/syncfile.test.mjs).
//
// En fil per enhet i mappen "Sensus synk". Filen är enhetens hela sammanslagna bild, och borttaget är rader med
// deleted. Den nyaste ändringen vinner rad för rad, i hela millisekunder, och vid lika tid vinner det som redan
// finns (den lokala bilden läggs först). En rad som saknas i en fil tar aldrig bort något.

export const FORMAT = 1;
export const FOLDER_NAME = 'Sensus synk';

// Tider

/** Sekunder sedan 1970 som ISO 8601 i UTC med millisekunder, till exempel 2026-11-07T18:35:07.123Z. */
export function isoTime(seconds) {
  return new Date(Math.round(seconds * 1000)).toISOString();
}

/** Läser en tid. Längre bråkdelar och +00:00 kortas till millisekunder. Som iPadens ISO8601DateFormatter krävs
 * datum, klockslag och tidszon (Z eller +hh:mm), annars null (granskning 6, L7: en tid utan tidszon lästes förut
 * som lokal tid här men hoppades över på iPaden). */
export function parseTime(value) {
  if (typeof value !== 'string' || !value) return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  const text = value.replace(/(T\d{2}:\d{2}:\d{2})\.(\d+)/, (_, time, digits) => `${time}.${(digits + '000').slice(0, 3)}`);
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms / 1000;
}

const ms = (seconds) => Math.round(seconds * 1000);

/** Sant om a är nyare än b, räknat i hela millisekunder. Allt är nyare än inget. */
export function newer(a, b) {
  if (a === null || a === undefined) return false;
  if (b === null || b === undefined) return true;
  return ms(a) > ms(b);
}

// Tolkning, som i Swift: tal och text med siffror godtas, annat ger null.

function int(value) {
  if (typeof value === 'number' || typeof value === 'boolean') {
    const number = Number(value);
    return Number.isFinite(number) && Math.abs(number) < 1e12 ? Math.trunc(number) : null;
  }
  if (typeof value === 'string' && /^-?\d+$/.test(value)) return Number(value);
  return null;
}

function num(value) {
  if (typeof value === 'number' || typeof value === 'boolean') {
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  }
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value);
  return null;
}

const bool = (value) => value === true || value === 1;
const text = (value, fallback = '') => (typeof value === 'string' ? value : fallback);
const clamp01 = (value) => Math.min(Math.max(value, 0), 1);
/** Andelar med sex decimaler, så att samma värde alltid skrivs likadant. */
export const rounded = (value) => Math.round(value * 1e6) / 1e6;

export const wordKey = (word) => `${word.language}|${word.lemma}`;

// Raderna

export function positionFromRow(row) {
  const book = typeof row.book_id === 'string' ? row.book_id.toLowerCase() : '';
  const updated = parseTime(row.updated_at);
  const section = int(row.section);
  if (!book || (row.kind !== 'pdf' && row.kind !== 'reflow') || updated === null || section === null || section < 0) return null;
  return { bookId: book, title: text(row.title), kind: row.kind, section, progression: rounded(clamp01(num(row.progression) ?? 0)), updated };
}

export function highlightFromRow(row) {
  const id = typeof row.id === 'string' ? row.id.toLowerCase() : '';
  const book = typeof row.book_id === 'string' ? row.book_id.toLowerCase() : '';
  const updated = parseTime(row.updated_at);
  const section = int(row.section);
  const start = int(row.start);
  const length = int(row.length);
  if (!id || !book || updated === null || section === null || section < 0 || start === null || start < 0
    || length === null || length < 0) return null;
  return { id, bookId: book, section, start, length, text: text(row.text), color: text(row.color, 'yellow'), note: text(row.note),
    created: parseTime(row.created_at) ?? updated, updated, deleted: bool(row.deleted) };
}

export function bookmarkFromRow(row) {
  const id = typeof row.id === 'string' ? row.id.toLowerCase() : '';
  const book = typeof row.book_id === 'string' ? row.book_id.toLowerCase() : '';
  const updated = parseTime(row.updated_at);
  const section = int(row.section);
  if (!id || !book || updated === null || section === null || section < 0) return null;
  return { id, bookId: book, section, progression: rounded(clamp01(num(row.progression) ?? 0)), label: text(row.label),
    created: parseTime(row.created_at) ?? updated, updated, deleted: bool(row.deleted) };
}

const REVIEW_FIELDS = ['due', 'interval', 'ease', 'reps', 'lapses', 'reviewUpdated'];

function clearReview(word) {
  for (const field of REVIEW_FIELDS) word[field] = null;
  return word;
}

/** Ett ord som synken jämför det: repetitionen finns bara när ordet lever och har due och en tid. */
export function normalizeWord(word) {
  const result = {
    lemma: word.lemma, language: word.language, word: text(word.word, word.lemma), sentence: text(word.sentence),
    book: text(word.book), page: int(word.page) ?? 0, lookups: Math.max(int(word.lookups) ?? 1, 1),
    created: num(word.created) ?? num(word.updated) ?? 0, updated: num(word.updated) ?? 0, deleted: Boolean(word.deleted),
    due: null, interval: null, ease: null, reps: null, lapses: null, reviewUpdated: null,
  };
  if (!result.deleted && num(word.reviewUpdated) !== null && num(word.due) !== null) {
    result.due = Math.round(num(word.due) * 1000) / 1000;
    result.interval = rounded(num(word.interval) ?? 0);
    result.ease = rounded(num(word.ease) ?? 2.5);
    result.reps = int(word.reps) ?? 0;
    result.lapses = int(word.lapses) ?? 0;
    result.reviewUpdated = num(word.reviewUpdated);
  }
  return result;
}

export function wordFromRow(row) {
  const updated = parseTime(row.updated_at);
  if (typeof row.lemma !== 'string' || !row.lemma || (row.language !== 'sv' && row.language !== 'en') || updated === null) return null;
  return normalizeWord({
    lemma: row.lemma, language: row.language, word: row.word, sentence: row.sentence, book: row.book, page: row.page,
    lookups: row.lookups, created: parseTime(row.created_at) ?? updated, updated, deleted: bool(row.deleted),
    due: row.due, interval: row.interval, ease: row.ease, reps: row.reps, lapses: row.lapses,
    reviewUpdated: parseTime(row.review_updated_at),
  });
}

export const positionRow = (p) => ({ book_id: p.bookId, title: p.title, kind: p.kind, section: p.section,
  progression: rounded(p.progression), updated_at: isoTime(p.updated) });

export const highlightRow = (h) => ({ id: h.id, book_id: h.bookId, section: h.section, start: h.start, length: h.length,
  text: h.text, color: h.color, note: h.note, created_at: isoTime(h.created), updated_at: isoTime(h.updated), deleted: Boolean(h.deleted) });

export const bookmarkRow = (b) => ({ id: b.id, book_id: b.bookId, section: b.section, progression: rounded(b.progression),
  label: b.label, created_at: isoTime(b.created), updated_at: isoTime(b.updated), deleted: Boolean(b.deleted) });

export function wordRow(w) {
  const review = !w.deleted && w.reviewUpdated !== null && w.reviewUpdated !== undefined && w.due !== null && w.due !== undefined;
  return {
    lemma: w.lemma, language: w.language, word: w.word, sentence: w.sentence, book: w.book, page: w.page, lookups: w.lookups,
    created_at: isoTime(w.created), updated_at: isoTime(w.updated), deleted: Boolean(w.deleted),
    due: review ? Math.round(w.due * 1000) / 1000 : null, interval: review ? rounded(w.interval ?? 0) : null,
    ease: review ? rounded(w.ease ?? 2.5) : null,
    reps: review ? (w.reps ?? 0) : null, lapses: review ? (w.lapses ?? 0) : null,
    review_updated_at: review ? isoTime(w.reviewUpdated) : null,
  };
}

// Bilderna

export function emptySnapshot(device, written) {
  return { device, written, positions: new Map(), highlights: new Map(), bookmarks: new Map(), words: new Map(), skippedRows: 0 };
}

export const rowCount = (s) => s.positions.size + s.highlights.size + s.bookmarks.size + s.words.size;

/** `incoming` om den är nyare än `existing`, annars `existing`. */
export function newest(existing, incoming) {
  if (!existing) return incoming;
  return newer(incoming.updated, existing.updated) ? incoming : existing;
}

/** Ett ord ur två bilder: ordet från den med nyast updated, repetitionen från den med nyast reviewUpdated. */
export function mergeWord(existing, incoming) {
  if (!existing) return incoming.deleted ? clearReview({ ...incoming }) : { ...incoming };
  const wordFromIncoming = newer(incoming.updated, existing.updated);
  const reviewFromIncoming = newer(incoming.reviewUpdated, existing.reviewUpdated);
  const reviewFromExisting = !reviewFromIncoming && newer(existing.reviewUpdated, incoming.reviewUpdated);
  const merged = { ...(wordFromIncoming ? incoming : existing) };
  const source = reviewFromIncoming ? incoming : (reviewFromExisting ? existing : merged);
  if (merged.deleted) return clearReview(merged);
  for (const field of REVIEW_FIELDS) merged[field] = source[field] ?? null;
  return merged;
}

/** Läser en synkfil. Ger { snapshot } eller { error } ('empty', 'notJSON', 'notSensus', 'newerFormat'). */
export function decode(content) {
  if (typeof content !== 'string' || content.length === 0) return { error: 'empty' };
  // L7: en fil med BOM läses som på iPaden.
  if (content.charCodeAt(0) === 0xfeff) content = content.slice(1);
  if (content.length === 0) return { error: 'empty' };
  let root;
  try {
    root = JSON.parse(content);
  } catch {
    return { error: 'notJSON' };
  }
  if (!root || typeof root !== 'object' || Array.isArray(root)) return { error: 'notJSON' };
  // L7: formatet ska vara ett tal, som på iPaden (NSNumber). Text som "1" är ingen synkfil.
  const format = typeof root.format === 'string' ? null : int(root.format);
  const device = root.device;
  if (format === null || format < 1 || !device || typeof device !== 'object' || typeof device.id !== 'string' || !device.id) {
    return { error: 'notSensus' };
  }
  if (format > FORMAT) return { error: 'newerFormat', format };
  const snapshot = emptySnapshot({ id: device.id, name: text(device.name), platform: text(device.platform) },
    parseTime(root.written_at) ?? 0);
  const list = (value) => {
    if (value === undefined || value === null) return [];
    if (!Array.isArray(value)) {
      snapshot.skippedRows += 1;
      return [];
    }
    return value.filter((item) => {
      const ok = item !== null && typeof item === 'object' && !Array.isArray(item);
      if (!ok) snapshot.skippedRows += 1;
      return ok;
    });
  };
  const add = (rows, parse, map, key) => {
    for (const row of rows) {
      const value = parse(row);
      if (!value) {
        snapshot.skippedRows += 1;
        continue;
      }
      map.set(key(value), newest(map.get(key(value)), value));
    }
  };
  add(list(root.positions), positionFromRow, snapshot.positions, (p) => p.bookId);
  add(list(root.highlights), highlightFromRow, snapshot.highlights, (h) => h.id);
  add(list(root.bookmarks), bookmarkFromRow, snapshot.bookmarks, (b) => b.id);
  for (const row of list(root.saved_words)) {
    const word = wordFromRow(row);
    if (!word) {
      snapshot.skippedRows += 1;
      continue;
    }
    snapshot.words.set(wordKey(word), mergeWord(snapshot.words.get(wordKey(word)), word));
  }
  return { snapshot };
}

const sortedValues = (map) => [...map.keys()].sort().map((key) => map.get(key));

export function encode(snapshot) {
  return JSON.stringify({
    format: FORMAT,
    app: 'Sensus',
    device: { id: snapshot.device.id, name: snapshot.device.name, platform: snapshot.device.platform },
    written_at: isoTime(snapshot.written),
    positions: sortedValues(snapshot.positions).map(positionRow),
    highlights: sortedValues(snapshot.highlights).map(highlightRow),
    bookmarks: sortedValues(snapshot.bookmarks).map(bookmarkRow),
    saved_words: sortedValues(snapshot.words).map(wordRow),
  });
}

/** Slår ihop bilderna. Den första vinner vid lika tid. En rad finns med om den finns i någon av bilderna. */
export function merge(snapshots, device, written) {
  const result = emptySnapshot(device, written);
  for (const snapshot of snapshots) {
    for (const [key, value] of snapshot.positions) result.positions.set(key, newest(result.positions.get(key), value));
    for (const [key, value] of snapshot.highlights) result.highlights.set(key, newest(result.highlights.get(key), value));
    for (const [key, value] of snapshot.bookmarks) result.bookmarks.set(key, newest(result.bookmarks.get(key), value));
    for (const [key, value] of snapshot.words) result.words.set(key, mergeWord(result.words.get(key), value));
  }
  return result;
}

/** Det som ska sparas här: rader i den sammanslagna bilden som är nyare än de lokala. */
export function changes(local, merged) {
  const result = { positions: [], highlights: [], bookmarks: [], words: [] };
  for (const value of sortedValues(merged.positions)) {
    if (newer(value.updated, local.positions.get(value.bookId)?.updated)) result.positions.push(value);
  }
  for (const value of sortedValues(merged.highlights)) {
    if (newer(value.updated, local.highlights.get(value.id)?.updated)) result.highlights.push(value);
  }
  for (const value of sortedValues(merged.bookmarks)) {
    if (newer(value.updated, local.bookmarks.get(value.id)?.updated)) result.bookmarks.push(value);
  }
  for (const value of sortedValues(merged.words)) {
    const mine = local.words.get(wordKey(value));
    if (newer(value.updated, mine?.updated) || (!value.deleted && newer(value.reviewUpdated, mine?.reviewUpdated))) {
      result.words.push(value);
    }
  }
  return result;
}

/** Hur många rader som är nya eller ändrade jämfört med förra versionen av filen, jämförda som de skrivs. */
export function changedRows(old, next) {
  if (!old) return rowCount(next);
  let count = 0;
  const compare = (a, b, row) => {
    for (const [key, value] of a) {
      const before = b.get(key);
      if (!before || JSON.stringify(row(value)) !== JSON.stringify(row(before))) count += 1;
    }
  };
  compare(next.positions, old.positions, positionRow);
  compare(next.highlights, old.highlights, highlightRow);
  compare(next.bookmarks, old.bookmarks, bookmarkRow);
  compare(next.words, old.words, wordRow);
  return count;
}

export const ERROR_TEXT = {
  empty: 'filen är tom',
  notJSON: 'filen går inte att läsa (trasig eller halvt hämtad)',
  notSensus: 'filen är inte en synkfil från Sensus',
  newerFormat: 'filen är från en nyare version av Sensus',
};
