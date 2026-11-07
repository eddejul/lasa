// Provar ordregler och meningar: node --test windows/tests/
import assert from 'node:assert/strict';
import test from 'node:test';
import { wordInPageText, sentenceAround, reflowCandidates } from '../src/js/wordfind.js';
import { englishPos, guessLanguage } from '../src/js/language.js';
import { normalize } from '../src/js/lookup.js';

const page = 'Första raden. Detta är kun-\nskap om saker, som e-post\noch kurs- och studieplan. Sista\n\nNytt stycke.';

test('avstavat ord över radbrytning, klick på första halvan', () => {
  const found = wordInPageText(page, page.indexOf('kun'));
  assert.deepEqual(found.candidates, ['kunskap', 'kun-skap', 'kun']);
  assert.equal(found.sentence, 'Detta är kunskap om saker, som e-post och kurs- och studieplan.');
  const [start, length] = found.rangeInSentence;
  assert.equal(found.sentence.slice(start, start + length), 'kunskap');
});

test('avstavat ord, klick på andra halvan', () => {
  const found = wordInPageText(page, page.indexOf('skap') + 2);
  assert.equal(found.candidates[0], 'kunskap');
  assert.equal(found.parts.length, 2);
});

test('bindestreck inne i ordet hör till ordet', () => {
  const found = wordInPageText(page, page.indexOf('e-post') + 3);
  assert.deepEqual(found.candidates, ['e-post', 'epost']);
});

test('mellanslag och skiljetecken är inga ord', () => {
  assert.equal(wordInPageText(page, page.indexOf(',')), null);
  assert.equal(wordInPageText(page, page.indexOf(' ')), null);
});

test('stycke slutar vid tom rad', () => {
  const found = wordInPageText(page, page.indexOf('Sista'));
  assert.equal(found.sentence, 'Sista');
});

test('mening i EPUB ur texten före och efter', () => {
  const [sentence, [start, length]] = sentenceAround('Hej. Han ', 'sprang', ' fort. Sedan gick han.');
  assert.equal(sentence, 'Han sprang fort.');
  assert.equal(sentence.slice(start, start + length), 'sprang');
  assert.deepEqual(reflowCandidates('EU-land'), ['EU-land', 'EUland']);
});

test('språket efter meningen', () => {
  assert.equal(guessLanguage('She went to the library to find a book about the town.'), 'en');
  assert.equal(guessLanguage('Hon gick till biblioteket för att hitta en bok.'), 'sv');
  assert.equal(guessLanguage('glass'), 'sv');
});

test('engelsk ordklass efter ordet före', () => {
  assert.equal(englishPos('We attribute the change to the weather.', 3), 'v');
  assert.equal(englishPos('The attribute is missing.', 4), 'n');
  assert.equal(englishPos('Bridges are old.', 0), null);
});

test('normalisering som i lookup.py', () => {
  assert.equal(normalize('  ”Kunskap,” '), 'kunskap');
  assert.equal(normalize('ﬁnns'), 'finns');
  assert.equal(normalize('don’t.'), "don't");
  assert.equal(normalize('kun­skap'), 'kunskap');
});
