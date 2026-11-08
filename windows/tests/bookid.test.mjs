// G3 på Windows: matchningen när en fil läggs till (bookmatch.js, samma regler som BookMatcher i
// App/Library/BookRegistry.swift) och flytten från kontrollsumman till bokens eget id (moves i
// src-tauri/statements.json), prövad mot en SQLite-databas i minnet med samma start som appen.
//   node --test windows/tests/bookid.test.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { isSimilar, matchFile, normalizedTitle, uniqueName } from '../src/js/bookmatch.js';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const statements = JSON.parse(readFileSync(here('../src-tauri/statements.json'), 'utf8'));
const library = statements.databases.bibliotek;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = (letter) => letter.repeat(64);

// Matchningen

const book = (fields) => ({ id: crypto.randomUUID(), sha256: '', fileName: 'Bok.pdf', missing: false, ...fields });

test('normalizedTitle och isSimilar som på iPaden', () => {
  assert.equal(normalizedTitle('Retorik (OCR) 2'), 'retorik');
  assert.equal(normalizedTitle('Retorik v2 ny version'), 'retorik');
  assert.equal(normalizedTitle('Kapitel 3 Topik'), 'kapitel topik');
  assert.ok(isSimilar({ fileName: 'Retorik.pdf' }, 'Retorik (OCR) 2.pdf'));
  assert.ok(isSimilar({ fileName: 'Lindqvist kopia.pdf' }, 'lindqvist FINAL.pdf'));
  assert.ok(!isSimilar({ fileName: 'Retorik.pdf' }, 'Retorik.epub'), 'annan filtyp');
  assert.ok(!isSimilar({ fileName: 'Retorik.pdf' }, 'Topik.pdf'));
  assert.ok(!isSimilar({ fileName: 'Ab.pdf' }, 'Abc.pdf'), 'korta titlar måste vara lika');
});

test('samma innehåll läggs inte till igen, oavsett namn', () => {
  const old = book({ sha256: hash('a') });
  assert.deepEqual(matchFile({ name: 'Annat namn.pdf', sha256: hash('a') }, [old]), { kind: 'exists', book: old });
  // En bok från före flytten har kontrollsumman som id.
  const legacy = book({ id: hash('b') });
  assert.equal(matchFile({ name: 'X.pdf', sha256: hash('b') }, [legacy]).kind, 'exists');
});

test('upptaget namn med nytt innehåll ger frågan Ersätt eller Behåll båda', () => {
  const old = book({ sha256: hash('a'), fileName: 'Retorik.pdf' });
  assert.deepEqual(matchFile({ name: 'retorik.PDF', sha256: hash('c') }, [old]), { kind: 'nameTaken', book: old });
  assert.equal(uniqueName('Retorik.pdf', [old]), 'Retorik 2.pdf');
  assert.equal(uniqueName('Retorik.pdf', [old, book({ fileName: 'Retorik 2.pdf', missing: true })]), 'Retorik 3.pdf');
});

test('en borttagen bok kommer tillbaka på innehållet, och en ny version på namnet', () => {
  const gone = book({ sha256: hash('a'), fileName: 'Retorik.pdf', missing: true });
  assert.deepEqual(matchFile({ name: 'Omdöpt.pdf', sha256: hash('a') }, [gone]), { kind: 'restore', book: gone });
  assert.deepEqual(matchFile({ name: 'Retorik.pdf', sha256: hash('d') }, [gone]), { kind: 'newVersion', book: gone });
  assert.deepEqual(matchFile({ name: 'Retorik (OCR) 2.pdf', sha256: hash('d') }, [gone]), { kind: 'newVersion', book: gone });
  assert.equal(matchFile({ name: 'Topik.pdf', sha256: hash('d') }, [gone]).kind, 'new');
  // En bok som finns kvar med liknande namn är en annan bok (som en kopia på iPaden).
  const present = book({ sha256: hash('a'), fileName: 'Retorik.pdf' });
  assert.equal(matchFile({ name: 'Retorik (OCR).pdf', sha256: hash('d') }, [present]).kind, 'new');
  // En bok som finns går före en borttagen med samma namn.
  assert.equal(matchFile({ name: 'Retorik.pdf', sha256: hash('d') }, [gone, present]).kind, 'nameTaken');
});

// Flytten

function startDatabase(db) {
  // Som migrate och run_moves i main.rs (och Backend i dev/server.py).
  db.exec(library.schema.join('\n'));
  for (const [table, columns] of Object.entries(library.columns)) {
    const existing = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
    for (const [name, definition] of columns) {
      if (!existing.has(name)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${definition}`);
    }
  }
  let moved = 0;
  for (const move of library.moves) {
    const pending = Object.values(db.prepare(move.pending).get())[0];
    if (!pending) continue;
    db.exec('BEGIN IMMEDIATE');
    try {
      for (const step of move.steps) db.exec(step);
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
    moved += 1;
  }
  return moved;
}

/** En databas som från version 0.7.0: books utan sha256, id är kontrollsumman. */
function oldDatabase() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL DEFAULT '', format TEXT NOT NULL,
    ext TEXT NOT NULL, file_name TEXT NOT NULL, size INTEGER NOT NULL, added REAL NOT NULL, opened REAL NOT NULL DEFAULT 0,
    position TEXT NOT NULL DEFAULT '', progress REAL NOT NULL DEFAULT 0, cover TEXT NOT NULL DEFAULT '', position_updated REAL)`);
  db.exec(library.schema.join('\n').replace(/CREATE TABLE IF NOT EXISTS meta[\s\S]*$/, ''));
  const addBook = db.prepare(`INSERT INTO books (id, title, format, ext, file_name, size, added, position, progress, position_updated)
    VALUES (?, ?, 'pdf', 'pdf', ?, 100, ?, ?, 0.5, 1700000000)`);
  addBook.run(hash('a'), 'Retorik', 'Retorik.pdf', 1, '{"page":41}');
  addBook.run(hash('b'), 'Topik', 'Topik.pdf', 2, '{"page":3}');
  const mark = db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated)
    VALUES (?, ?, 5, 0, 7, 'Kunskap', 'yellow', ?, 10, 20)`);
  mark.run('m1', hash('a'), 'anteckning');
  mark.run('m2', hash('a'), '');
  mark.run('m3', hash('b'), '');
  mark.run('m4', hash('f'), ''); // en bok som inte finns längre
  db.prepare(`INSERT INTO bookmarks (id, book, section, progression, label, created, updated)
    VALUES ('b1', ?, 5, 0, 'Sida 6', 10, 30)`).run(hash('a'));
  return db;
}

test('flytten ger varje bok ett eget id och flyttar markeringar och bokmärken, utan att ändringstiden rörs', () => {
  const db = oldDatabase();
  assert.equal(startDatabase(db), 2, 'G3 och de borttagna böckerna');
  const books = db.prepare('SELECT id, sha256, position, missing FROM books WHERE missing = 0 ORDER BY added').all();
  assert.deepEqual(books.map((row) => row.sha256), [hash('a'), hash('b')]);
  assert.ok(books.every((row) => UUID.test(row.id)), JSON.stringify(books));
  assert.notEqual(books[0].id, books[1].id);
  assert.equal(books[0].position, '{"page":41}', 'läspositionen följer med');
  const marks = Object.fromEntries(db.prepare('SELECT id, book, updated FROM highlights').all().map((row) => [row.id, row]));
  assert.equal(marks.m1.book, books[0].id);
  assert.equal(marks.m2.book, books[0].id);
  assert.equal(marks.m3.book, books[1].id);
  // Fynd 5: en bok som tagits bort i 0.7.0 (raden borta, markeringen kvar under kontrollsumman) får en
  // borttagen bokrad med eget id, och markeringen flyttas dit.
  const gone = db.prepare('SELECT id, sha256, missing, ext, file_name FROM books WHERE missing = 1').all();
  assert.equal(gone.length, 1, JSON.stringify(gone));
  assert.deepEqual([gone[0].sha256, gone[0].missing, gone[0].ext, gone[0].file_name], [hash('f'), 1, '', '']);
  assert.ok(UUID.test(gone[0].id) && !books.some((row) => row.id === gone[0].id));
  assert.equal(marks.m4.book, gone[0].id, 'markeringen för den borttagna boken hänger på dess nya id');
  assert.equal(marks.m4.updated, 20, 'ändringstiden är orörd');
  assert.equal(marks.m1.updated, 20, 'ändringstiden är orörd');
  const bookmark = db.prepare('SELECT book, updated FROM bookmarks').get();
  assert.deepEqual([bookmark.book, bookmark.updated], [books[0].id, 30]);
  assert.equal(db.prepare("SELECT value FROM meta WHERE key = 'legacy_book_keys_moved'").get().value, '1');
  assert.equal(db.prepare("SELECT value FROM meta WHERE key = 'legacy_removed_books_moved'").get().value, '1');

  // En andra start ändrar ingenting.
  const before = JSON.stringify([db.prepare('SELECT * FROM books').all(), db.prepare('SELECT * FROM highlights').all(),
    db.prepare('SELECT * FROM bookmarks').all()]);
  assert.equal(startDatabase(db), 0);
  assert.equal(JSON.stringify([db.prepare('SELECT * FROM books').all(), db.prepare('SELECT * FROM highlights').all(),
    db.prepare('SELECT * FROM bookmarks').all()]), before);
});

/** Bokregistrets rader som bookFromRow i store.js gör dem (för matchFile). */
const registry = (db) => db.prepare('SELECT id, sha256, file_name, missing, ext FROM books').all()
  .map((row) => ({ id: row.id, sha256: row.sha256, fileName: row.file_name, missing: Boolean(row.missing), ext: row.ext }));

/** En databas där G3 redan är gjord (version 0.8.0), med en markering och ett bokmärke för en bok som togs
 *  bort i 0.7.0 och därför står kvar under kontrollsumman. */
function movedDatabase() {
  const db = oldDatabase();
  db.exec("DELETE FROM highlights WHERE id = 'm4'");
  const [g3] = library.moves;
  db.exec(library.schema.join('\n'));
  for (const [table, columns] of Object.entries(library.columns)) {
    const existing = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
    for (const [name, definition] of columns) if (!existing.has(name)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${definition}`);
  }
  for (const step of g3.steps) db.exec(step);
  db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated)
    VALUES ('m7', ?, 2, 0, 5, 'Ethos', 'green', 'gammal', 40, 50)`).run(hash('e'));
  db.prepare(`INSERT INTO bookmarks (id, book, section, progression, label, created, updated)
    VALUES ('b7', ?, 2, 0, 'Sida 3', 30, 60)`).run(hash('e'));
  return db;
}

test('fynd 5: steget körs en gång även när G3 redan är gjord, och samma fil ger restore', () => {
  const db = movedDatabase();
  assert.equal(db.prepare("SELECT value FROM meta WHERE key = 'legacy_book_keys_moved'").get().value, '1');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM meta WHERE key = 'legacy_removed_books_moved'").get().n, 0);
  assert.equal(startDatabase(db), 1, 'bara steget för de borttagna böckerna');
  const gone = db.prepare('SELECT id, sha256, missing, added FROM books WHERE sha256 = ?').get(hash('e'));
  assert.ok(gone && UUID.test(gone.id) && gone.missing === 1, JSON.stringify(gone));
  assert.equal(gone.added, 30, 'added är den tidigaste markeringen eller bokmärket');
  assert.deepEqual({ ...db.prepare("SELECT book, updated FROM highlights WHERE id = 'm7'").get() }, { book: gone.id, updated: 50 });
  assert.deepEqual({ ...db.prepare("SELECT book, updated FROM bookmarks WHERE id = 'b7'").get() }, { book: gone.id, updated: 60 });
  // Samma fil läggs till igen, med samma eller ett annat namn: den känns igen på innehållet.
  for (const name of ['Ethos.pdf', 'Annat namn.pdf']) {
    const match = matchFile({ name, sha256: hash('e') }, registry(db));
    assert.equal(match.kind, 'restore', name);
    assert.equal(match.book.id, gone.id);
    assert.equal(match.book.ext, '', 'library.js ger den då filens titel, filtyp och namn');
  }
  // Den borttagna raden blir aldrig en ny version av en annan fil (tomt filnamn, ingen filtyp).
  assert.equal(matchFile({ name: '.pdf', sha256: hash('9') }, registry(db)).kind, 'new');
  assert.equal(matchFile({ name: 'Borttagen bok.pdf', sha256: hash('9') }, registry(db)).kind, 'new');
  // En tredje start ändrar ingenting.
  const before = JSON.stringify([db.prepare('SELECT * FROM books').all(), db.prepare('SELECT * FROM highlights').all()]);
  assert.equal(startDatabase(db), 0);
  assert.equal(JSON.stringify([db.prepare('SELECT * FROM books').all(), db.prepare('SELECT * FROM highlights').all()]), before);
});

test('fynd 5: finns boken redan (lagd till igen i 0.8.0) flyttas markeringarna dit, ingen ny rad', () => {
  const db = movedDatabase();
  const id = crypto.randomUUID();
  db.prepare(`INSERT INTO books (id, title, format, ext, file_name, size, added, sha256) VALUES (?, 'Ethos', 'pdf', 'pdf', 'Ethos.pdf', 9, 99, ?)`)
    .run(id, hash('e'));
  assert.equal(startDatabase(db), 1);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM books WHERE sha256 = ?').get(hash('e')).n, 1);
  assert.equal(db.prepare("SELECT book FROM highlights WHERE id = 'm7'").get().book, id);
  assert.equal(db.prepare("SELECT book FROM bookmarks WHERE id = 'b7'").get().book, id);
});

test('fynd 5: rader under ett id som inte finns rörs inte, bara kontrollsummor räknas', () => {
  const db = movedDatabase();
  const lost = crypto.randomUUID();
  db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, created, updated)
    VALUES ('m8', ?, 0, 0, 1, 'x', 'blue', 1, 2)`).run(lost);
  db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, created, updated)
    VALUES ('m9', ?, 0, 0, 1, 'x', 'blue', 1, 2)`).run('G'.repeat(64));
  startDatabase(db);
  assert.equal(db.prepare("SELECT book FROM highlights WHERE id = 'm8'").get().book, lost);
  assert.equal(db.prepare("SELECT book FROM highlights WHERE id = 'm9'").get().book, 'G'.repeat(64));
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM books WHERE missing = 1').get().n, 1, 'bara kontrollsumman e');
  assert.equal(startDatabase(db), 0);
});

test('flytten går att köra om när en äldre version lagt till en bok efteråt', () => {
  const db = oldDatabase();
  startDatabase(db);
  const first = db.prepare('SELECT id FROM books WHERE sha256 = ?').get(hash('a')).id;
  // Version 0.7.0 kör igen och lägger till en bok med kontrollsumman som id (sha256 blir tom).
  db.prepare(`INSERT INTO books (id, title, format, ext, file_name, size, added) VALUES (?, 'Ny', 'pdf', 'pdf', 'Ny.pdf', 1, 3)`)
    .run(hash('c'));
  db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, created, updated)
    VALUES ('m5', ?, 0, 0, 1, 'x', 'blue', 1, 2)`).run(hash('c'));
  db.prepare(`INSERT INTO highlights (id, book, section, start, length, text, color, created, updated)
    VALUES ('m6', ?, 0, 0, 1, 'y', 'blue', 1, 2)`).run(first);
  assert.equal(startDatabase(db), 1);
  const added = db.prepare('SELECT id, sha256 FROM books WHERE sha256 = ?').get(hash('c'));
  assert.ok(UUID.test(added.id));
  assert.equal(db.prepare("SELECT book FROM highlights WHERE id = 'm5'").get().book, added.id);
  assert.equal(db.prepare("SELECT book FROM highlights WHERE id = 'm6'").get().book, first, 'redan flyttade rörs inte');
  assert.equal(db.prepare('SELECT id FROM books WHERE sha256 = ?').get(hash('a')).id, first, 'redan flyttade böcker behåller id:t');
});

test('en tom databas behöver ingen flytt', () => {
  const db = new DatabaseSync(':memory:');
  assert.equal(startDatabase(db), 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM meta').get().n, 0);
});

test('flyttens steg ändrar bara rader, de tar aldrig bort något', () => {
  for (const move of library.moves) {
    assert.match(move.pending, /^SELECT /);
    for (const step of move.steps) {
      assert.match(step, /^(UPDATE|INSERT) /, step);
      assert.ok(!/\b(DELETE|DROP|ALTER)\b/.test(step), step);
    }
  }
});
