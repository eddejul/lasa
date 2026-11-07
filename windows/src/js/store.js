// Det användaren gör: biblioteket, läspositioner, inställningar, sparade ord och dolda synonympar.
// Två egna SQLite-filer i appens datamapp (bibliotek.sqlite och anvandarord.sqlite), aldrig ordboken.

import { userDb } from './backend.js';
import { hiddenKey } from './lookup.js';

const words = userDb('ord');
const library = userDb('bibliotek');

// Samma kolumner som saved_words i App/Dictionary/UserWords.swift, plus uuid och book_id för synken i fas 6.
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
  progress REAL NOT NULL DEFAULT 0,
  cover TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`;

const now = () => Date.now() / 1000;

export async function openStore() {
  await words.batch(WORDS_SCHEMA);
  await library.batch(LIBRARY_SCHEMA);
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
  await library.run('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, JSON.stringify(value)]);
}

// Biblioteket

const BOOK_COLUMNS = 'id, title, author, format, ext, file_name, size, added, opened, position, progress, cover';

function bookFromRow(row) {
  const [id, title, author, format, ext, fileName, size, added, opened, position, progress, cover] = row;
  let parsed = null;
  try {
    parsed = position ? JSON.parse(position) : null;
  } catch {
    parsed = null;
  }
  return { id, title, author, format, ext, fileName, size, added, opened, position: parsed, progress, cover };
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

export async function savePosition(id, position, progress) {
  await library.run('UPDATE books SET position = ?, progress = ? WHERE id = ?',
    [JSON.stringify(position), Math.max(0, Math.min(1, progress || 0)), id]);
}

// Sparade ord

/** Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen, boken och sidan
 *  byts mot de senaste. uuid sätts första gången och ändras aldrig (synken i fas 6). */
export async function saveWord({ word, lemma, language, sentence, book, page, bookId }) {
  const time = now();
  await words.run(`INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated, uuid, book_id)
    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
    ON CONFLICT (lemma, language) DO UPDATE SET
      word = excluded.word, sentence = excluded.sentence, book = excluded.book, page = excluded.page,
      book_id = excluded.book_id, lookups = lookups + 1, updated = excluded.updated`,
  [word, lemma, language, sentence, book, page, time, time, crypto.randomUUID(), bookId ?? '']);
}

export async function savedWords() {
  const rows = await words.all(`SELECT id, word, lemma, language, sentence, book, page, lookups, updated, uuid, book_id
    FROM saved_words ORDER BY updated DESC`);
  return rows.map(([id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId]) =>
    ({ id, word, lemma, language, sentence, book, page, lookups, updated, uuid, bookId }));
}

export async function deleteSavedWord(id) {
  await words.run('DELETE FROM saved_words WHERE id = ?', [id]);
}

export async function unsaveWord(lemma, language) {
  await words.run('DELETE FROM saved_words WHERE lemma = ? AND language = ?', [lemma, language]);
}

export async function isSaved(lemma, language) {
  return (await words.all('SELECT 1 FROM saved_words WHERE lemma = ? AND language = ?', [lemma, language])).length > 0;
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
