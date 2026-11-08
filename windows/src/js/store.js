// Det användaren gör: biblioteket, läspositioner, inställningar, sparade ord och dolda synonympar.
// Två egna SQLite-filer i appens datamapp (bibliotek.sqlite och anvandarord.sqlite), aldrig ordboken.
// Synken (fas 6, sync.js) läser och skriver läspositioner och sparade ord här.

import { userDb } from './backend.js';
import { hiddenKey } from './lookup.js';

const words = userDb('ord');
const library = userDb('bibliotek');

// Samma kolumner som saved_words i App/Dictionary/UserWords.swift, plus uuid och book_id för synken.
// deleted: borttaget ord som synken ska skicka vidare. due, interval, ease, reps, lapses och
// review_updated är repetitionen från iPaden. Windows repeterar inte, men skickar dem vidare oförändrade.
const WORDS_SCHEMA = `
CREATE TABLE IF NOT EXISTS saved_words (
  id INTEGER PRIMARY KEY,
  word TEXT NOT NULL,
  lemma TEXT NOT NULL,
  language TEXT NOT NULL,
  sentence TEXT NOT NULL,
  book TEXT NOT NULL,
  page INTEGER NOT NULL,
  lookups INTEGER NOT NULL DEFAULT 1,
  created REAL NOT NULL,
  updated REAL NOT NULL,
  uuid TEXT NOT NULL DEFAULT '',
  book_id TEXT NOT NULL DEFAULT '',
  UNIQUE (lemma, language)
);
CREATE TABLE IF NOT EXISTS hidden_pairs (
  language TEXT NOT NULL,
  lemma TEXT NOT NULL,
  synonym TEXT NOT NULL,
  created REAL NOT NULL,
  PRIMARY KEY (language, lemma, synonym)
);
`;
const WORD_COLUMNS = [
  ['deleted', 'INTEGER NOT NULL DEFAULT 0'],
  ['due', 'REAL'],
  ['interval', 'REAL'],
  ['ease', 'REAL'],
  ['reps', 'INTEGER'],
  ['lapses', 'INTEGER'],
  ['review_updated', 'REAL'],
  // När ordet repeterades första gången (för högst 20 nya ord om dagen). Bara på den här datorn.
  ['review_introduced', 'REAL'],
];

const LIBRARY_SCHEMA = `
CREATE TABLE IF NOT EXISTS books (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT NOT NULL DEFAULT '',
  format TEXT NOT NULL,
  ext TEXT NOT NULL,
  file_name TEXT NOT NULL,
  size INTEGER NOT NULL,
  added REAL NOT NULL,
  opened REAL NOT NULL DEFAULT 0,
  position TEXT NOT NULL DEFAULT '',
  progress REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS highlights (
  id TEXT PRIMARY KEY,
  book TEXT NOT NULL,
  section INTEGER NOT NULL,
  start INTEGER NOT NULL,
  length INTEGER NOT NULL,
  text TEXT NOT NULL,
  color TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created REAL NOT NULL,
  updated REAL NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS highlights_book ON highlights (book, section);
CREATE TABLE IF NOT EXISTS bookmarks (
  id TEXT PRIMARY KEY,
  book TEXT NOT NULL,
  section INTEGER NOT NULL,
  progression REAL NOT NULL,
  label TEXT NOT NULL,
  created REAL NOT NULL,
  updated REAL NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS bookmarks_book ON bookmarks (book, section);
`;
// position_updated: när läspositionen senast flyttades av läsaren eller kom från synken (sekunder).
const BOOK_COLUMNS_ADDED = [
  ['cover', "TEXT NOT NULL DEFAULT ''"],
  ['position_updated', 'REAL'],
];

const now = () => Date.now() / 1000;

/** Lägger till kolumner som saknas, så att en databas från en tidigare version fungerar. */
async function ensureColumns(db, table, columns) {
  const existing = new Set((await db.all(`PRAGMA table_info(${table})`)).map((row) => row[1]));
  for (const [name, definition] of columns) {
    if (!existing.has(name)) await db.run(`ALTER TABLE ${table} ADD COLUMN ${name} ${definition}`);
  }
}

export async function openStore() {
  await words.batch(WORDS_SCHEMA);
  await library.batch(LIBRARY_SCHEMA);
  await ensureColumns(words, 'saved_words', WORD_COLUMNS);
  await ensureColumns(library, 'books', BOOK_COLUMNS_ADDED);
  await loadHiddenPairs();
  await loadSettings();
}

// Inställningar

export const settings = { theme: 'white', font: 'original', size: 2 };

async function loadSettings() {
  for (const [key, value] of await library.all('SELECT key, value FROM settings')) {
    try {
      settings[key] = JSON.parse(value);
    } catch {
      // en trasig rad hoppas över
    }
  }
}

export async function setSetting(key, value) {
  settings[key] = value;
  if (value === undefined || value === null) {
    delete settings[key];
    await library.run('DELETE FROM settings WHERE key = ?', [key]);
    return;
  }
  await library.run('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, JSON.stringify(value)]);
}

// Biblioteket

const BOOK_COLUMNS = 'id, title, author, format, ext, file_name, size, added, opened, position, progress, cover, position_updated';

function bookFromRow(row) {
  const [id, title, author, format, ext, fileName, size, added, opened, position, progress, cover, positionUpdated] = row;
  let parsed = null;
  try {
    parsed = position ? JSON.parse(position) : null;
  } catch {
    parsed = null;
  }
  return { id, title, author, format, ext, fileName, size, added, opened, position: parsed, progress, cover, positionUpdated };
}

export async function listBooks() {
  const rows = await library.all(`SELECT ${BOOK_COLUMNS} FROM books ORDER BY CASE WHEN opened > 0 THEN opened ELSE added END DESC`);
  return rows.map(bookFromRow);
}

export async function getBook(id) {
  const rows = await library.all(`SELECT ${BOOK_COLUMNS} FROM books WHERE id = ?`, [id]);
  return rows.length ? bookFromRow(rows[0]) : null;
}

export async function addBook(book) {
  await library.run(`INSERT INTO books (id, title, author, format, ext, file_name, size, added, cover)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  [book.id, book.title, book.author ?? '', book.format, book.ext, book.fileName, book.size, now(), book.cover ?? '']);
}

export async function removeBook(id) {
  await library.run('DELETE FROM books WHERE id = ?', [id]);
}

export async function markOpened(id) {
  await library.run('UPDATE books SET opened = ? WHERE id = ?', [now(), id]);
}

/** Läsaren har flyttat sig i boken. Ändringstiden blir nu, så att synken skickar positionen. */
export async function savePosition(id, position, progress) {
  await library.run('UPDATE books SET position = ?, progress = ?, position_updated = ? WHERE id = ?',
    [JSON.stringify(position), Math.max(0, Math.min(1, progress || 0)), now(), id]);
}

/** En nyare position från synken. Gäller nästa gång boken öppnas (en öppen bok hoppar inte). */
export async function applySyncedPosition(id, position, updated) {
  await library.run('UPDATE books SET position = ?, position_updated = ? WHERE id = ?',
    [JSON.stringify(position), updated, id]);
}

// Markeringar, anteckningar och bokmärken (W1). Samma tabeller och fält som markeringar.sqlite på iPaden
// (App/Annotations/AnnotationStore.swift) och som synken i docs/SYNK.md: book är bokens id (SHA-256),
// section och ett teckenintervall (start, length) i UTF-16, och text. Inget raderas: borttaget får
// deleted = 1 och ny ändringstid, så att en framtida synk kan föra borttagningen vidare.

export const HIGHLIGHT_COLORS = ['yellow', 'green', 'blue', 'pink'];
const HIGHLIGHT_COLUMNS = 'id, book, section, start, length, text, color, note, created, updated';

function highlightFromRow([id, book, section, start, length, text, color, note, created, updated]) {
  return { id, book, section, start, length, text, color: HIGHLIGHT_COLORS.includes(color) ? color : 'yellow', note, created, updated };
}

/** Bokens markeringar i läsordning. */
export async function bookHighlights(book) {
  const rows = await library.all(`SELECT ${HIGHLIGHT_COLUMNS} FROM highlights WHERE book = ? AND deleted = 0
    ORDER BY section, start`, [book]);
  return rows.map(highlightFromRow);
}

/** Sparar en markering (ny eller ändrad). updated blir nu. */
export async function saveHighlight(highlight) {
  const time = now();
  const row = { ...highlight, created: highlight.created ?? time, updated: time };
  await library.run(`INSERT OR REPLACE INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`,
  [row.id, row.book, row.section, row.start, row.length, row.text, row.color, row.note ?? '', row.created, row.updated]);
  return row;
}

export async function deleteHighlight(id) {
  await library.run('UPDATE highlights SET deleted = 1, updated = ? WHERE id = ?', [now(), id]);
}

/** Bokens bokmärken i läsordning. */
export async function bookBookmarks(book) {
  const rows = await library.all(`SELECT id, book, section, progression, label, created, updated FROM bookmarks
    WHERE book = ? AND deleted = 0 ORDER BY section, progression`, [book]);
  return rows.map(([id, bookId, section, progression, label, created, updated]) =>
    ({ id, book: bookId, section, progression, label, created, updated }));
}

export async function addBookmark({ book, section, progression, label }) {
  const time = now();
  const bookmark = { id: crypto.randomUUID().toLowerCase(), book, section, progression, label, created: time, updated: time };
  await library.run(`INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
    VALUES (?, ?, ?, ?, ?, ?, ?, 0)`, [bookmark.id, book, section, progression, label, time, time]);
  return bookmark;
}

export async function deleteBookmark(id) {
  await library.run('UPDATE bookmarks SET deleted = 1, updated = ? WHERE id = ?', [now(), id]);
}

// Sparade ord

/** Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen, boken och sidan
 *  byts mot de senaste. uuid sätts första gången och ändras aldrig. Ett borttaget ord blir sparat igen. */
export async function saveWord({ word, lemma, language, sentence, book, page, bookId }) {
  const time = now();
  await words.run(`INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated, uuid, book_id)
    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
    ON CONFLICT (lemma, language) DO UPDATE SET
      word = excluded.word, sentence = excluded.sentence, book = excluded.book, page = excluded.page,
      book_id = excluded.book_id, lookups = CASE WHEN deleted THEN 1 ELSE lookups + 1 END,
      created = CASE WHEN deleted THEN excluded.created ELSE created END,
      deleted = 0, updated = excluded.updated`,
  [word, lemma, language, sentence, book, page, time, time, crypto.randomUUID(), bookId ?? '']);
}

export async function savedWords() {
  const rows = await words.all(`SELECT id, word, lemma, language, sentence, book, page, lookups, updated, uuid, book_id
    FROM saved_words WHERE deleted = 0 ORDER BY updated DESC`);
  return rows.map(([id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId]) =>
    ({ id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId }));
}

/** Ett borttaget ord raderas inte: det märks som borttaget med ny ändringstid, så att synken kan ta bort
 *  det på iPaden också. Repetitionen följer inte med ett borttaget ord. */
const TOMBSTONE = `UPDATE saved_words SET deleted = 1, updated = ?, due = NULL, interval = NULL, ease = NULL,
  reps = NULL, lapses = NULL, review_updated = NULL, review_introduced = NULL`;

export async function deleteSavedWord(id) {
  await words.run(`${TOMBSTONE} WHERE id = ?`, [now(), id]);
}

export async function unsaveWord(lemma, language) {
  await words.run(`${TOMBSTONE} WHERE lemma = ? AND language = ?`, [now(), lemma, language]);
}

export async function isSaved(lemma, language) {
  return (await words.all('SELECT 1 FROM saved_words WHERE lemma = ? AND language = ? AND deleted = 0', [lemma, language])).length > 0;
}

const SYNC_WORD_COLUMNS = `lemma, language, word, sentence, book, page, lookups, created, updated, deleted,
  due, interval, ease, reps, lapses, review_updated, uuid, book_id`;

/** Alla ord för synken, även borttagna. */
export async function wordsForSync() {
  const rows = await words.all(`SELECT ${SYNC_WORD_COLUMNS} FROM saved_words`);
  return rows.map(([lemma, language, word, sentence, book, page, lookups, created, updated, deleted,
    due, interval, ease, reps, lapses, reviewUpdated, uuid, bookId]) => ({
    lemma, language, word, sentence, book, page, lookups, created, updated, deleted: Boolean(deleted),
    due, interval, ease, reps, lapses, reviewUpdated, uuid, bookId,
  }));
}

/** Skriver ett ord från synken. uuid och book_id behålls om ordet finns, annars får det ett nytt uuid.
 *  Repetitionen räknas som påbörjad när den första gången kom hit (som introduced på iPaden). */
export async function applySyncedWord(word) {
  const introduced = word.due === null || word.due === undefined ? null : (word.reviewUpdated ?? null);
  await words.run(`INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated, uuid, book_id,
      deleted, due, interval, ease, reps, lapses, review_updated, review_introduced)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (lemma, language) DO UPDATE SET
      word = excluded.word, sentence = excluded.sentence, book = excluded.book, page = excluded.page,
      lookups = excluded.lookups, created = excluded.created, updated = excluded.updated, deleted = excluded.deleted,
      due = excluded.due, interval = excluded.interval, ease = excluded.ease, reps = excluded.reps,
      lapses = excluded.lapses, review_updated = excluded.review_updated,
      review_introduced = CASE WHEN excluded.due IS NULL THEN NULL ELSE COALESCE(review_introduced, excluded.review_introduced) END`,
  [word.word, word.lemma, word.language, word.sentence, word.book, word.page, word.lookups, word.created, word.updated,
    crypto.randomUUID(), word.deleted ? 1 : 0, word.due ?? null, word.interval ?? null, word.ease ?? null,
    word.reps ?? null, word.lapses ?? null, word.reviewUpdated ?? null, introduced]);
}

// Repetitionen (W5, schemat i review.js)

/** Sparade ord med repetitionen, senast ändrade först (samma ordning som på iPaden). */
export async function reviewWords() {
  const rows = await words.all(`SELECT id, word, lemma, language, sentence, book, page, updated, due, interval, ease, reps, lapses,
      review_introduced FROM saved_words WHERE deleted = 0 ORDER BY updated DESC`);
  return rows.map(([id, word, lemma, language, sentence, book, page, updated, due, interval, ease, reps, lapses, introduced]) =>
    ({ id, word, lemma, language, sentence, book, page, updated, due, interval, ease, reps, lapses, introduced }));
}

/** Sparar hur det gick. Repetitionens ändringstid blir nu, så att synken skickar den till iPaden. */
export async function recordReview(lemma, language, { due, interval, ease, reps, lapses }) {
  const time = now();
  await words.run(`UPDATE saved_words SET due = ?, interval = ?, ease = ?, reps = ?, lapses = ?, review_updated = ?,
      review_introduced = COALESCE(review_introduced, ?) WHERE lemma = ? AND language = ? AND deleted = 0`,
  [due, interval, ease, reps, lapses, time, time, lemma, language]);
}

// Fel synonym

/** Dolda par som nycklar (hiddenKey i lookup.js), och som lista för Om ordboken. */
export const hidden = { keys: new Set(), list: [] };

async function loadHiddenPairs() {
  const rows = await words.all('SELECT language, lemma, synonym FROM hidden_pairs ORDER BY lemma, synonym');
  hidden.list = rows.map(([language, lemma, synonym]) => ({ language, lemma, synonym }));
  hidden.keys = new Set(rows.map(([language, lemma, synonym]) => hiddenKey(language, lemma, synonym)));
}

export async function hidePair(language, lemma, synonym) {
  await words.run('INSERT OR IGNORE INTO hidden_pairs VALUES (?, ?, ?, ?)', [language, lemma, synonym, now()]);
  await loadHiddenPairs();
}

export async function unhidePair(language, lemma, synonym) {
  await words.run('DELETE FROM hidden_pairs WHERE language = ? AND lemma = ? AND synonym = ?', [language, lemma, synonym]);
  await loadHiddenPairs();
}
