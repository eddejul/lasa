// Det användaren gör: biblioteket, läspositioner, inställningar, sparade ord och dolda synonympar.
// Två egna SQLite-filer i appens datamapp (bibliotek.sqlite och anvandarord.sqlite), aldrig ordboken.
// Synken (fas 6, sync.js) läser och skriver läspositioner och sparade ord här.

import { userDb } from './backend.js';
import { hiddenKey } from './lookup.js';

// Frågorna har namn: SQL:en finns i src-tauri/statements.json och körs bara av Rust-delen (W12). Tabellerna
// skapas och nya kolumner läggs till när appen startar. Samma kolumner som saved_words i
// App/Dictionary/UserWords.swift, plus uuid och book_id för synken, deleted för borttagna ord och
// repetitionen (due, interval, ease, reps, lapses, review_updated, review_introduced).
const read = userDb.read;
const write = userDb.write;

const now = () => Date.now() / 1000;

export async function openStore() {
  await loadHiddenPairs();
  await loadSettings();
}

// Inställningar

export const settings = { theme: 'white', font: 'original', size: 2 };

async function loadSettings() {
  for (const [key, value] of await read('settings_all')) {
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
    await write('setting_delete', [key]);
    return;
  }
  await write('setting_set', [key, JSON.stringify(value)]);
}

// Biblioteket

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
  const rows = await read('books_list');
  return rows.map(bookFromRow);
}

export async function getBook(id) {
  const rows = await read('book_get', [id]);
  return rows.length ? bookFromRow(rows[0]) : null;
}

export async function addBook(book) {
  await write('book_add', [book.id, book.title, book.author ?? '', book.format, book.ext, book.fileName, book.size, now(), book.cover ?? '']);
}

export async function removeBook(id) {
  await write('book_remove', [id]);
}

export async function markOpened(id) {
  await write('book_opened', [now(), id]);
}

/** Läsaren har flyttat sig i boken. Ändringstiden blir nu, så att synken skickar positionen. */
export async function savePosition(id, position, progress) {
  await write('book_position', [JSON.stringify(position), Math.max(0, Math.min(1, progress || 0)), now(), id]);
}

/** En nyare position från synken. Gäller nästa gång boken öppnas (en öppen bok hoppar inte). */
export async function applySyncedPosition(id, position, updated) {
  await write('book_synced_position', [JSON.stringify(position), updated, id]);
}

// Markeringar, anteckningar och bokmärken (W1). Samma tabeller och fält som markeringar.sqlite på iPaden
// (App/Annotations/AnnotationStore.swift) och som synken i docs/SYNK.md: book är bokens id (SHA-256),
// section och ett teckenintervall (start, length) i UTF-16, och text. Inget raderas: borttaget får
// deleted = 1 och ny ändringstid, så att en framtida synk kan föra borttagningen vidare.

export const HIGHLIGHT_COLORS = ['yellow', 'green', 'blue', 'pink'];

function highlightFromRow([id, book, section, start, length, text, color, note, created, updated]) {
  return { id, book, section, start, length, text, color: HIGHLIGHT_COLORS.includes(color) ? color : 'yellow', note, created, updated };
}

/** Bokens markeringar i läsordning. */
export async function bookHighlights(book) {
  const rows = await read('highlights_of_book', [book]);
  return rows.map(highlightFromRow);
}

/** Sparar en markering (ny eller ändrad). updated blir nu. */
export async function saveHighlight(highlight) {
  const time = now();
  const row = { ...highlight, created: highlight.created ?? time, updated: time };
  await write('highlight_save', [row.id, row.book, row.section, row.start, row.length, row.text, row.color, row.note ?? '', row.created, row.updated]);
  return row;
}

export async function deleteHighlight(id) {
  await write('highlight_delete', [now(), id]);
}

/** Bokens bokmärken i läsordning. */
export async function bookBookmarks(book) {
  const rows = await read('bookmarks_of_book', [book]);
  return rows.map(([id, bookId, section, progression, label, created, updated]) =>
    ({ id, book: bookId, section, progression, label, created, updated }));
}

export async function addBookmark({ book, section, progression, label }) {
  const time = now();
  const bookmark = { id: crypto.randomUUID().toLowerCase(), book, section, progression, label, created: time, updated: time };
  await write('bookmark_add', [bookmark.id, book, section, progression, label, time, time]);
  return bookmark;
}

export async function deleteBookmark(id) {
  await write('bookmark_delete', [now(), id]);
}

// Sparade ord

/** Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen, boken och sidan
 *  byts mot de senaste. uuid sätts första gången och ändras aldrig. Ett borttaget ord blir sparat igen. */
export async function saveWord({ word, lemma, language, sentence, book, page, bookId }) {
  const time = now();
  await write('word_save', [word, lemma, language, sentence, book, page, time, time, crypto.randomUUID(), bookId ?? '']);
}

export async function savedWords() {
  const rows = await read('words_saved');
  return rows.map(([id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId]) =>
    ({ id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId }));
}

/** Ett borttaget ord raderas inte: det märks som borttaget med ny ändringstid, så att synken kan ta bort
 *  det på iPaden också. Repetitionen följer inte med ett borttaget ord. */
export async function deleteSavedWord(id) {
  await write('word_delete_by_id', [now(), id]);
}

export async function unsaveWord(lemma, language) {
  await write('word_delete_by_lemma', [now(), lemma, language]);
}

export async function isSaved(lemma, language) {
  return (await read('word_is_saved', [lemma, language])).length > 0;
}

/** Alla ord för synken, även borttagna. */
export async function wordsForSync() {
  const rows = await read('words_for_sync');
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
  await write('word_synced', [word.word, word.lemma, word.language, word.sentence, word.book, word.page, word.lookups, word.created, word.updated,
    crypto.randomUUID(), word.deleted ? 1 : 0, word.due ?? null, word.interval ?? null, word.ease ?? null,
    word.reps ?? null, word.lapses ?? null, word.reviewUpdated ?? null, introduced]);
}

// Repetitionen (W5, schemat i review.js)

/** Sparade ord med repetitionen, senast ändrade först (samma ordning som på iPaden). */
export async function reviewWords() {
  const rows = await read('words_for_review');
  return rows.map(([id, word, lemma, language, sentence, book, page, updated, due, interval, ease, reps, lapses, introduced]) =>
    ({ id, word, lemma, language, sentence, book, page, updated, due, interval, ease, reps, lapses, introduced }));
}

/** Sparar hur det gick. Repetitionens ändringstid blir nu, så att synken skickar den till iPaden. */
export async function recordReview(lemma, language, { due, interval, ease, reps, lapses }) {
  const time = now();
  await write('word_review', [due, interval, ease, reps, lapses, time, time, lemma, language]);
}

// Fel synonym

/** Dolda par som nycklar (hiddenKey i lookup.js), och som lista för Om ordboken. */
export const hidden = { keys: new Set(), list: [] };

async function loadHiddenPairs() {
  const rows = await read('hidden_pairs_all');
  hidden.list = rows.map(([language, lemma, synonym]) => ({ language, lemma, synonym }));
  hidden.keys = new Set(rows.map(([language, lemma, synonym]) => hiddenKey(language, lemma, synonym)));
}

export async function hidePair(language, lemma, synonym) {
  await write('hidden_pair_add', [language, lemma, synonym, now()]);
  await loadHiddenPairs();
}

export async function unhidePair(language, lemma, synonym) {
  await write('hidden_pair_remove', [language, lemma, synonym]);
  await loadHiddenPairs();
}
