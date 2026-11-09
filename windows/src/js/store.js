// Det användaren gör: biblioteket, läspositioner, inställningar, sparade ord och dolda synonympar.
// Två egna SQLite-filer i appens datamapp (bibliotek.sqlite och anvandarord.sqlite), aldrig ordboken.
// Synken (fas 6, sync.js) läser och skriver läspositioner och sparade ord här.

import { userDb } from './backend.js';
import { hiddenKey } from './lookup.js';
import { isStopWord } from './review.js';

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
  const [id, title, author, format, ext, fileName, size, added, opened, position, progress, cover, positionUpdated,
    sha256, missing, modified] = row;
  let parsed = null;
  try {
    parsed = position ? JSON.parse(position) : null;
  } catch {
    parsed = null;
  }
  return { id, title, author, format, ext, fileName, size, added, opened, position: parsed, progress, cover, positionUpdated,
    sha256: sha256 || '', missing: Boolean(missing), modified: modified ?? 0 };
}

// Bokens id och kontrollsumma (G3). id är ett eget id (UUID) som aldrig ändras, sha256 är SHA-256 av filens
// innehåll. Bokfilen heter <sha256>.<ext> i Böcker, och synken skickar sha256 som book_id (docs/SYNK.md).
// En bok från före G3 som inte flyttats har tom sha256, och då är id:t kontrollsumman.
export const contentId = (book) => book.sha256 || book.id;

/** Alla böcker, även de som tagits bort ur biblioteket (missing), för matchningen när en fil läggs till. */
export async function bookRegistry() {
  const rows = await read('books_registry');
  return rows.map(bookFromRow);
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
  await write('book_add', [book.id, book.title, book.author ?? '', book.format, book.ext, book.fileName, book.size, now(),
    book.cover ?? '', book.sha256, book.modified ?? 0]);
}

/** Boken tas bort ur biblioteket, men raden, markeringarna och läspositionen finns kvar (G3), så att de
 *  kommer tillbaka om samma bok eller en ny version av den läggs till igen. */
export async function markBookMissing(id) {
  await write('book_missing', [id]);
}

/** En ny fil för en bok som behåller sitt id (Behåll markeringarna): ny kontrollsumma, titel och omslag. */
export async function setBookFile(id, book) {
  await write('book_new_file', [book.sha256, book.title, book.author ?? '', book.format, book.ext, book.fileName, book.size,
    book.modified ?? 0, book.cover ?? '', id]);
}

/** Samma fil som en bok som tagits bort läggs till igen: boken kommer tillbaka med allt. */
export async function restoreBook(id, fileName, modified) {
  await write('book_restore', [fileName, modified ?? 0, id]);
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
// (App/Annotations/AnnotationStore.swift) och som synken i docs/SYNK.md: book är bokens id (G3, ett UUID),
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

// Frågor i marginalen (K6) och AI-frågorna (K6b, docs/AI-FRAGOR.md). Samma tabeller som iPaden:
// question_answers (steg 10 plus my_answer och feedback) och ai_questions (steg 13), book är bokens id (G3).
// Frågefilen som valts med Välj frågefil ligger i question_files.

const parseJSON = (text, fallback) => {
  try {
    return text ? JSON.parse(text) : fallback;
  } catch {
    return fallback;
  }
};

/** Hur det gått på bokens frågor: Map från frågans id till { status, answered, updated, myAnswer, feedback }. */
export async function questionAnswers(book) {
  const rows = await read('question_answers_of_book', [book]);
  return new Map(rows.map(([question, status, answered, updated, myAnswer, feedback]) =>
    [question, { status, answered, updated, myAnswer: myAnswer ?? '', feedback: parseJSON(feedback, null) }]));
}

/** Kan, Osäker eller Kan inte ('kan', 'osaker', 'kan_inte', som QuestionStatus på iPaden). */
export async function setQuestionStatus(book, question, status) {
  await write('question_status_set', [book, question, status, now()]);
}

/** Det skrivna svaret, sparat när rutan stängs. */
export async function setQuestionMyAnswer(book, question, myAnswer) {
  await write('question_my_answer_set', [book, question, now(), myAnswer]);
}

/** Jämförs svar (JSON) med svaret det gällde. */
export async function setQuestionFeedback(book, question, myAnswer, feedback) {
  await write('question_feedback_set', [book, question, now(), myAnswer, JSON.stringify(feedback)]);
}

/** Bokens AI-frågor: [{ chapter, part, chapterTitle, model, created, summary, concepts, questions }]. */
export async function aiQuestions(book) {
  const rows = await read('ai_questions_of_book', [book]);
  return rows.map(([chapter, part, chapterTitle, model, created, summary, concepts, questions]) => ({
    chapter, part, chapterTitle: chapterTitle ?? '', model: model ?? '', created: created ?? 0, summary: summary ?? '',
    concepts: parseJSON(concepts, []), questions: parseJSON(questions, []),
  }));
}

/** Sparar en del av ett kapitel. Ett för kort kapitel sparas med tom lista, så att det inte skickas igen. */
export async function saveAiQuestions(book, { chapter, part, chapterTitle, model, summary, concepts, questions }) {
  await write('ai_questions_save', [book, chapter, part, chapterTitle ?? '', model ?? '', now(), summary ?? '',
    JSON.stringify(concepts ?? []), JSON.stringify(questions ?? [])]);
}

/** Tar bort ett kapitels AI-frågor (Gör nya frågor till kapitlet). */
export async function deleteAiQuestions(book, chapter) {
  await write('ai_questions_delete_chapter', [book, chapter]);
}

/** Andra böcker med AI-frågor, de senast lästa först: [{ book, title, summaries, concepts }]. */
export async function otherBooksWithQuestions(book) {
  const rows = await read('ai_questions_other_books', [book]);
  const books = new Map();
  for (const [id, title, , , summary, concepts] of rows) {
    if (!books.has(id)) books.set(id, { book: id, title, summaries: [], concepts: [] });
    const entry = books.get(id);
    if (summary) entry.summaries.push(summary);
    for (const concept of parseJSON(concepts, [])) if (!entry.concepts.includes(concept)) entry.concepts.push(concept);
  }
  return [...books.values()];
}

/** Frågefilen som valts för boken: { name, json } eller null. */
export async function questionFile(book) {
  const rows = await read('question_file_of_book', [book]);
  return rows.length ? { name: rows[0][0], json: rows[0][1] } : null;
}

export async function saveQuestionFile(book, name, json) {
  await write('question_file_save', [book, name, json, now()]);
}

export async function deleteQuestionFile(book) {
  await write('question_file_delete', [book]);
}

// Sparade ord

/** Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen, boken och sidan
 *  byts mot de senaste. uuid sätts första gången och ändras aldrig. Ett borttaget ord blir sparat igen.
 *  U6: småord (att, det, och, the, of) sparas aldrig, som på iPaden. */
export async function saveWord({ word, lemma, language, sentence, book, page, bookId }) {
  if (isStopWord(word, language)) return;
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
