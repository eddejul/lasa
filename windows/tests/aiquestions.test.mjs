// AI-frågornas logik på Windows (src/js/aiquestions.js) mot det gemensamma facit,
// tools/simtest/ai-fragor/fixtur-1.json (byggd av referens.py). iPadens XCTest läser samma fil.
//   node --test windows/tests/aiquestions.test.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  SCHEMA_COMPARE, SCHEMA_QUESTIONS, buildCompare, buildPrompt, capFor, check, checkSummary, count, locate, partCount,
  questionId, splitParts, typeName,
} from '../src/js/aiquestions.js';

const fixture = JSON.parse(readFileSync(fileURLToPath(new URL('../../tools/simtest/ai-fragor/fixtur-1.json', import.meta.url)), 'utf8'));
const { bok, kapitel } = fixture;

test('antalet och taket för fixturens kapitel', () => {
  const tal = count(kapitel.text.length, kapitel.sista);
  assert.deepEqual(tal, fixture.antal);
  assert.deepEqual(capFor(tal), fixture.tak);
  // Pythons round(): 2,5 blir 2 och 3,5 blir 4.
  assert.equal(count(8750).efter, 2);
  assert.equal(count(12250).efter, 4);
  assert.equal(count(100000).efter, 10);
  assert.equal(count(1000).efter, 2);
  assert.deepEqual(partCount(9000, { firstPart: false, lastPart: false }), { efter: 3, fore: 0, kopplingar: 0, slut: 0 });
  assert.equal(count(9000, true).slut, 4);
});

test('frågan till modellen är exakt fixturens', () => {
  const prompt = buildPrompt(bok, kapitel, fixture.tidigare, fixture.andraBocker, fixture.antal);
  assert.equal(prompt, fixture.prompt);
});

test('frågan i en senare del och i bokens sista kapitel', () => {
  const later = buildPrompt(bok, { ...kapitel, del: 2, delar: 3 }, [], [], partCount(9000, { firstPart: false, lastPart: false }));
  assert.match(later, /Kapitel: Slingan \(del 2 av 3\)/);
  assert.match(later, /b\) Inga frågor med "nar": "fore"\./);
  assert.match(later, /c\) Inga frågor med "nar": "slut"\./);
  assert.match(later, /Tidigare kapitel i boken:\nInga\.\n/);
  const last = buildPrompt(bok, { ...kapitel, sista: true }, [], [], count(9000, true));
  assert.match(last, /c\) 4 frågor med "nar": "slut".*Det här är bokens sista kapitel: lägg till en fråga av typen syntes/);
});

test('schemana är fixturens', () => {
  assert.deepEqual(SCHEMA_QUESTIONS, fixture.schemaFragor);
  assert.deepEqual(SCHEMA_COMPARE, fixture.schemaJamfor);
});

test('kontrollen behåller och slänger som fixturen, med id och plats', () => {
  const { kept, dropped } = check(fixture.svar, kapitel.text, {
    bookId: bok.id, chapterKey: kapitel.nyckel, part: kapitel.del, otherTitles: fixture.andraBocker.map((b) => b.titel),
    cap: fixture.tak,
  });
  const pick = (f) => ({ id: f.id, nr: f.nr, typ: f.typ, nar: f.nar, fraga: f.fraga, kalla: f.kalla, oppen: f.oppen, position: f.position });
  assert.deepEqual(kept.map(pick), fixture.vantat.behalls);
  assert.deepEqual(dropped, fixture.vantat.slangs);
  assert.equal(checkSummary('k3', kept, dropped),
    'AI-frågor k3: 6 av 13 behölls (plats 1, kalla 1, kopierad 1, avstand 1, bok 1, typ 1, svar 1)');
  // Platsen i fråga 5 är slutet av träffen, i originaltexten.
  const f5 = kept.find((f) => f.nr === 5);
  assert.equal(kapitel.text.slice(f5.position - 'människan'.length, f5.position), 'människan');
});

test('Jämförs frågor är fixturens', () => {
  const { kept } = check(fixture.svar, kapitel.text, {
    bookId: bok.id, chapterKey: kapitel.nyckel, part: kapitel.del, otherTitles: fixture.andraBocker.map((b) => b.titel),
    cap: fixture.tak,
  });
  for (const { nr, mittSvar, prompt } of fixture.jamfor) {
    const question = kept.find((f) => f.nr === nr);
    assert.equal(buildCompare(question, mittSvar), prompt, `Jämför för fråga ${nr}`);
  }
});

test('id:t är FNV-1a i base36 och hittandet tål typografiska tecken', () => {
  assert.equal(questionId(bok.id, 'k3', 1, 'fore', fixture.vantat.behalls[0].fraga), fixture.vantat.behalls[0].id);
  assert.equal(locate('men "byta ut beteendet" i mitten', kapitel.text) > 0, true);
  assert.equal(locate('x', kapitel.text), null);
  assert.equal(locate('kun skap', 'Det är kun-\nskap.'), null);
  assert.equal(locate('kunskap', 'Det är kun-\nskap.'), 'Det är kun-\nskap'.length);
});

test('typens namn i rutan', () => {
  assert.equal(typeName({ typ: 'svar_mening' }), 'Svår mening');
  assert.equal(typeName({ typ: 'annan_bok', bok: 'Atomvanor' }), 'Koppling till Atomvanor');
  assert.equal(typeName({ typ: 'overforing' }), 'Överföring');
});

test('långa kapitel delas vid tomma rader i lika stora delar', () => {
  const paragraph = `${'ord '.repeat(240).trim()}.`;
  const text = Array.from({ length: 100 }, () => paragraph).join('\n\n');
  assert.ok(text.length > 90000);
  const parts = splitParts(text);
  assert.equal(parts.length, Math.ceil(text.length / 36000));
  assert.equal(parts[0].start, 0);
  assert.equal(parts[parts.length - 1].end, text.length);
  for (let i = 1; i < parts.length; i++) {
    assert.equal(parts[i].start, parts[i - 1].end);
    assert.equal(text.slice(parts[i].start - 2, parts[i].start), '\n\n');
  }
  const sizes = parts.map((p) => p.end - p.start);
  assert.ok(Math.max(...sizes) - Math.min(...sizes) < 2000, `ojämna delar ${sizes}`);
  assert.deepEqual(splitParts('kort'), [{ start: 0, end: 4 }]);
  const noBreaks = 'a '.repeat(30000);
  assert.equal(splitParts(noBreaks).length, 2);
});
