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

// K6b: det allmänna anropet generate och beskeden (som AIClient.Failure på iPaden).
import { AIFailure, failureFrom, generate, quotaResetText } from '../src/js/gemini.js';

function mockFetch(handler) {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).startsWith('/api/secret_get')) {
      const key = handler.key === undefined ? 'nyckel' : handler.key;
      return new Response(JSON.stringify(key), { status: 200 });
    }
    return handler.respond(calls[calls.length - 1]);
  };
  return calls;
}

const ok = (object) => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(object) }] } }] }), { status: 200 });
const error = (status, error) => new Response(JSON.stringify({ error }), { status });

test('generate: schemat, tidsgränsen och svaret', async () => {
  const calls = mockFetch({ respond: () => ok({ ok: true }) });
  const answer = await generate({ prompt: 'fråga', schema: { type: 'object' } });
  assert.deepEqual(answer, { ok: true });
  const sent = JSON.parse(calls[1].options.body);
  assert.deepEqual(sent.generationConfig, { responseMimeType: 'application/json', temperature: 0.3, maxOutputTokens: 8192,
    responseJsonSchema: { type: 'object' } });
  assert.match(calls[1].url, /generativelanguage\.googleapis\.com\/v1beta\/models\/.+:generateContent$/);
  assert.equal(calls[1].options.headers['x-goog-api-key'], 'nyckel');
});

test('generate: beskeden för nyckel, modell, kvot och nät', async () => {
  const kinds = async (handler) => {
    mockFetch(handler);
    try {
      await generate({ prompt: 'x', schema: {} });
      return null;
    } catch (failure) {
      assert.ok(failure instanceof AIFailure);
      return failure;
    }
  };
  assert.equal((await kinds({ key: null, respond: () => ok({}) })).kind, 'noKey');
  assert.equal((await kinds({ respond: () => error(400, { message: 'API key not valid.' }) })).kind, 'badKey');
  assert.equal((await kinds({ respond: () => error(404, { message: 'not found' }) })).kind, 'unknownModel');
  const day = await kinds({ respond: () => error(429, { message: 'Quota', details: [{ violations: [{ quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier' }] }] }) });
  assert.equal(day.kind, 'quotaDay');
  assert.match(day.message, /^Dagens gratiskvot hos Google är slut\. Den fylls på klockan \d\d\.\d\d svensk tid\./);
  const minute = await kinds({ respond: () => error(429, { message: 'Quota', details: [{ retryDelay: '16.2s' }] }) });
  assert.equal(minute.kind, 'quotaMinute');
  assert.equal(minute.seconds, 17);
  assert.equal(minute.message, 'Gratiskvoten för den här minuten är slut. Prova igen om 17 sekunder.');
  assert.equal((await kinds({ respond: () => { throw new TypeError('Failed to fetch'); } })).kind, 'offline');
  assert.equal((await kinds({ respond: () => new Response('{"candidates": []}', { status: 200 }) })).kind, 'invalid');
  assert.equal(failureFrom(500, { error: { message: 'Internt' } }, 'm').message, 'Gemini svarade med fel 500. Internt');
});

test('dagens kvot fylls på vid midnatt i Kalifornien', () => {
  // 9 november 2026 kl. 12.00 i Sverige (UTC+1) är 03.00 i Kalifornien (UTC-8): nästa midnatt där är 09.00 här.
  const text = quotaResetText(new Date('2026-11-09T11:00:00Z'));
  const local = new Date('2026-11-10T08:00:00Z');
  assert.equal(text, `${String(local.getHours()).padStart(2, '0')}.${String(local.getMinutes()).padStart(2, '0')}`);
});
