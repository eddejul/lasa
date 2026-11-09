// Synkfilerna på Windows (src/js/syncfile.js) mot iPadens App/Sync/SyncFile.swift (F1, docs/SYNK.md).
//   node --test windows/tests/syncfile.test.mjs
//
// Testet läser formatets version och mappens namn ur Swift-koden, så att en ändring på iPaden som inte görs
// här går sönder. Resten är påhittade filer från två enheter: krockar, borttaget, det som saknas, trasiga,
// tomma och nyare filer.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  FOLDER_NAME, FORMAT, changedRows, changes, decode, emptySnapshot, encode, merge, mergeWord, normalizeWord, wordKey,
} from '../src/js/syncfile.js';

const swift = readFileSync(fileURLToPath(new URL('../../App/Sync/SyncFile.swift', import.meta.url)), 'utf8');
const ipad = { id: 'ipad-1', name: 'iPad', platform: 'ios' };
const windows = { id: 'win-1', name: 'Datorn', platform: 'windows' };
const book = 'a'.repeat(64);

const highlight = (id, updated, extra = {}) => ({ id, bookId: book, section: 1, start: 5, length: 10, text: 'text', color: 'yellow',
  note: '', created: 1000, updated, deleted: false, ...extra });
const word = (lemma, updated, extra = {}) => normalizeWord({ lemma, language: 'sv', word: lemma, sentence: '', book: '', page: 0,
  lookups: 1, created: 1000, updated, deleted: false, ...extra });

function snapshot(device, { highlights = [], words = [], positions = [] } = {}) {
  const result = emptySnapshot(device, 5000);
  for (const item of highlights) result.highlights.set(item.id, item);
  for (const item of words) result.words.set(wordKey(item), item);
  for (const item of positions) result.positions.set(item.bookId, item);
  return result;
}

test('samma version och mapp som iPaden', () => {
  assert.match(swift, new RegExp(`static let format = ${FORMAT}\\b`));
  assert.match(swift, new RegExp(`static let folderName = "${FOLDER_NAME}"`));
});

test('en fil från iPaden läses, och Windows fil läses tillbaka likadan', () => {
  const fromIpad = JSON.stringify({
    format: 1, app: 'Sensus', device: ipad, written_at: '2026-11-09T01:00:00.000Z', framtida: { ignoreras: true },
    positions: [{ book_id: book.toUpperCase(), title: 'Bok', kind: 'reflow', section: 4, progression: 0.25, updated_at: '2030-01-01T10:00:00.123456+00:00' }],
    highlights: [{ id: 'ABC', book_id: book, section: 1, start: 5, length: 12, text: 'från iPaden', color: 'pink', note: 'n',
      created_at: '2030-01-01T10:00:00Z', updated_at: '2030-01-01T10:00:00.5+00:00', deleted: false }],
    bookmarks: [{ id: 'b1', book_id: book, section: 2, progression: 0.5, label: 'Märke', created_at: '2030-01-01T10:00:00Z',
      updated_at: '2030-01-01T10:00:00Z', deleted: true }],
    saved_words: [{ lemma: 'bro', language: 'sv', word: 'bron', sentence: 'Bron var hög.', book: 'Bok', page: 3, lookups: 2,
      created_at: '2030-01-01T10:00:00Z', updated_at: '2030-01-01T10:00:00Z', deleted: false, due: 1794000000.5, interval: 3,
      ease: 2.5, reps: 2, lapses: 1, review_updated_at: '2030-01-01T11:00:00.250Z' }],
  });
  const { snapshot: read, error } = decode(fromIpad);
  assert.equal(error, undefined);
  assert.equal(read.positions.get(book).section, 4);
  assert.equal(read.positions.get(book).updated * 1000, Date.parse('2030-01-01T10:00:00.123Z'));
  assert.equal(read.highlights.get('abc').text, 'från iPaden');
  assert.equal(read.bookmarks.get('b1').deleted, true);
  assert.equal(read.words.get('sv|bro').interval, 3);
  assert.equal(read.skippedRows, 0);
  const again = decode(encode(read)).snapshot;
  assert.equal(changedRows(read, again), 0, 'samma rader efter en runda genom filen');
  assert.deepEqual([...again.words.values()], [...read.words.values()]);
});

test('trasiga, tomma, okända och nyare filer läses inte', () => {
  assert.equal(decode('').error, 'empty');
  assert.equal(decode('inte json').error, 'notJSON');
  assert.equal(decode('{"format": 1, "device": {"id": "halv').error, 'notJSON');
  assert.equal(decode('[]').error, 'notJSON');
  assert.equal(decode('{"positions": []}').error, 'notSensus');
  assert.equal(decode('{"format": 1, "device": {"name": "utan id"}}').error, 'notSensus');
  assert.equal(decode('{"format": 2, "device": {"id": "x"}}').error, 'newerFormat');
});

test('udda filer läses som på iPaden (granskning 6, L7)', () => {
  const good = { format: 1, device: windows, written_at: '2026-11-09T01:00:00.000Z',
    positions: [{ book_id: book, kind: 'pdf', section: 3, progression: 0, updated_at: '2026-11-09T01:00:00.000Z' }] };
  // Formatet som text är ingen synkfil.
  assert.equal(decode(JSON.stringify({ ...good, format: '1' })).error, 'notSensus');
  // En fil med BOM läses.
  assert.equal(decode('\ufeff' + JSON.stringify(good)).snapshot.positions.size, 1);
  // En tid utan tidszon, eller ett datum utan klockslag, hoppas över som en rad som inte går att läsa.
  for (const updated of ['2026-11-09T01:00:00', '2026-11-09', '2026-11-09 01:00:00Z']) {
    const read = decode(JSON.stringify({ ...good, positions: [{ ...good.positions[0], updated_at: updated }] })).snapshot;
    assert.equal(read.positions.size, 0, updated);
    assert.equal(read.skippedRows, 1, updated);
  }
  // Z, +00:00 och långa bråkdelar går bra.
  for (const updated of ['2026-11-09T01:00:00Z', '2026-11-09T02:00:00+01:00', '2026-11-09T01:00:00.123456Z']) {
    const read = decode(JSON.stringify({ ...good, positions: [{ ...good.positions[0], updated_at: updated }] })).snapshot;
    assert.equal(read.positions.size, 1, updated);
  }
});

test('rader som inte går att läsa hoppas över, resten används', () => {
  const content = JSON.stringify({
    format: 1, device: windows,
    positions: [{ book_id: book, kind: 'bild', section: 3, updated_at: '2030-01-01T10:00:00Z' }],
    highlights: [{ id: '', book_id: 'x' }, 'inte en rad', { id: 'h1', book_id: book, section: 0, start: 1, length: 2,
      updated_at: '2030-01-01T10:00:00Z', deleted: 1 }],
    bookmarks: { fel: 'typ' },
    saved_words: [{ lemma: 'ord', language: 'de', updated_at: '2030-01-01T10:00:00Z' }],
  });
  const { snapshot: read } = decode(content);
  assert.equal(read.positions.size, 0);
  assert.equal(read.highlights.size, 1);
  assert.equal(read.highlights.get('h1').deleted, true);
  assert.equal(read.skippedRows, 5);
});

test('den nyaste vinner, och vid lika tid den lokala', () => {
  const local = snapshot(ipad, { highlights: [highlight('a', 2000, { note: 'ny lokal' }), highlight('b', 2000, { note: 'lokal' }),
    highlight('c', 2000, { note: 'lika' })] });
  const remote = snapshot(windows, { highlights: [highlight('a', 1000, { note: 'gammal' }), highlight('b', 3000, { note: 'nyare' }),
    highlight('c', 2000.0004, { note: 'lika i millisekunder' })] });
  const merged = merge([local, remote], ipad, 9000);
  assert.equal(merged.highlights.get('a').note, 'ny lokal');
  assert.equal(merged.highlights.get('b').note, 'nyare');
  assert.equal(merged.highlights.get('c').note, 'lika');
  assert.deepEqual(changes(local, merged).highlights.map((h) => h.id), ['b']);
});

test('borttaget och det som saknas', () => {
  const local = snapshot(ipad, { highlights: [highlight('kvar', 5000), highlight('tas bort', 2000), highlight('lever', 4000)] });
  const remote = snapshot(windows, { highlights: [highlight('tas bort', 3000, { deleted: true }), highlight('lever', 1000, { deleted: true })] });
  const merged = merge([local, remote], ipad, 9000);
  assert.equal(merged.highlights.get('tas bort').deleted, true);
  assert.equal(merged.highlights.get('lever').deleted, false);
  assert.equal(merged.highlights.get('kvar').deleted, false);
  const unchanged = merge([local, emptySnapshot(windows, 9000)], ipad, 9000);
  const empty = changes(local, unchanged);
  assert.equal(empty.highlights.length + empty.positions.length + empty.words.length, 0, 'en tom fil ändrar ingenting');
});

test('ordet och repetitionen var för sig, och borttaget utan repetition', () => {
  const local = snapshot(ipad, { words: [word('ord', 3000, { due: 2000, interval: 1, reviewUpdated: 1000 })] });
  const remote = snapshot(windows, { words: [word('ord', 2000, { due: 2000, interval: 7, reviewUpdated: 4000 })] });
  const merged = merge([local, remote], ipad, 9000).words.get('sv|ord');
  assert.equal(merged.updated, 3000);
  assert.equal(merged.interval, 7);
  assert.equal(merged.reviewUpdated, 4000);
  const deleted = snapshot(windows, { words: [word('ord', 5000, { deleted: true })] });
  const gone = merge([local, remote, deleted], ipad, 9000).words.get('sv|ord');
  assert.equal(gone.deleted, true);
  assert.equal(gone.reviewUpdated, null);
  assert.equal(gone.due, null);
  assert.equal(mergeWord(word('ord', 6000, { due: 1, reviewUpdated: 6000 }), word('ord', 5000, { deleted: true })).deleted, false);
});

test('tre enheter ger samma svar i alla ordningar', () => {
  const a = snapshot(ipad, { highlights: [highlight('x', 1000, { note: 'a' })] });
  const b = snapshot(windows, { highlights: [highlight('x', 3000, { note: 'b' })] });
  const c = snapshot({ id: 'c', name: '', platform: 'ios' }, { highlights: [highlight('x', 2000, { note: 'c' })] });
  for (const order of [[a, b, c], [a, c, b], [c, a, b]]) {
    assert.equal(merge(order, ipad, 1).highlights.get('x').note, 'b');
  }
});
