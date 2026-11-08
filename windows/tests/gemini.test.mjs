// AI-knappen på Windows (src/js/gemini.js) mot iPadens regler i App/Dictionary/GeminiClient.swift.
//   node --test windows/tests/gemini.test.mjs

import assert from 'node:assert/strict';
import test from 'node:test';

import { answerJSON, candidates, explanationFrom, promptFor, schemaFor } from '../src/js/gemini.js';

const lookup = {
  word: 'sprang',
  language: 'sv',
  entries: [
    { lemma: 'springa', posName: 'verb', translations: [],
      senses: [
        { definition: 'förflytta sig snabbt till fots', synonyms: [{ word: 'löpa' }, { word: 'rusa' }, { word: 'Löpa' }] },
        { definition: null, synonyms: [{ word: 'brista' }, { word: 'spricka' }] },
      ] },
    { lemma: 'språng', posName: 'substantiv', translations: [{ text: 'leap' }], senses: [] },
  ],
};

test('kandidaterna: id b1a, b1b, b2a, och orden utan dubbletter (stora och små bokstäver lika)', () => {
  const choices = candidates(lookup);
  assert.deepEqual(Object.keys(choices.senseTexts), ['b1a', 'b1b', 'b2a']);
  assert.equal(choices.senseTexts.b1b, 'brista, spricka');
  assert.equal(choices.senseTexts.b2a, 'leap');
  assert.deepEqual(choices.words, ['löpa', 'rusa', 'brista', 'spricka', 'leap']);
  assert.equal(choices.senseLines[0], 'b1a (verb): förflytta sig snabbt till fots; löpa, rusa, Löpa');
});

test('schemat: sense_id bland id:na och best_word bland orden eller tomt', () => {
  const schema = schemaFor(candidates(lookup));
  assert.deepEqual(schema.required, ['explanation', 'sense_id']);
  assert.deepEqual(schema.properties.sense_id.enum, ['b1a', 'b1b', 'b2a']);
  assert.deepEqual(schema.properties.best_word.enum, ['löpa', 'rusa', 'brista', 'spricka', 'leap', '']);
});

test('frågan har meningen, språket och reglerna', () => {
  const prompt = promptFor(lookup, 'Hon sprang till stationen.', candidates(lookup));
  assert.match(prompt, /^Du hjälper en svensk läsare/);
  assert.match(prompt, /Meningen: Hon sprang till stationen\./);
  assert.match(prompt, /Språk: svenska/);
  assert.match(prompt, /Ord att välja bland: löpa, rusa, brista, spricka, leap/);
  assert.match(prompt, /best_word ska stå ordagrant i listan, eller vara tom\./);
});

test('svaret: kodblock runt JSON tolkas, och ett påhittat ord visas inte', () => {
  const json = { candidates: [{ content: { parts: [{ text: '```json\n{"explanation": " Hon rörde sig fort. ", "sense_id": "b1a", "best_word": "RUSA"}\n```' }] } }] };
  const answer = answerJSON(json);
  const result = explanationFrom(answer, candidates(lookup));
  assert.deepEqual(result, { senseText: 'förflytta sig snabbt till fots', bestWord: 'rusa', explanation: 'Hon rörde sig fort.' });
  const madeUp = explanationFrom({ explanation: 'x', sense_id: 'b9z', best_word: 'galoppera' }, candidates(lookup));
  assert.equal(madeUp.bestWord, null);
  assert.equal(madeUp.senseText, null);
  assert.throws(() => explanationFrom({ explanation: '  ' }, candidates(lookup)));
});
