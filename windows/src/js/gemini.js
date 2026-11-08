// AI-knappen "Förklara i meningen" (W11), med Google Gemini. Samma anrop och regler som iPadens
// App/Dictionary/GeminiClient.swift: modellen får meningen, ordet och ordbokens betydelser och ska bara välja
// bland dem (strukturerat JSON-svar). Ett ord den hittar på själv visas inte. Ändras det ena ska det andra
// ändras i samma commit.
//
// Nyckeln skrivs in under Inställningar och sparas i Windows Autentiseringshanteraren (gemini-api-key),
// modellen är en inställning. Utan nyckel syns ingen knapp. Appens Content-Security-Policy släpper fram
// generativelanguage.googleapis.com och inget annat hos Google.

import { secretGet } from './backend.js';
import { settings } from './store.js';

/** En gratismodell som är snabb nog för en knapp (som på iPaden, kontrollerad 7 november 2026). */
export const DEFAULT_MODEL = 'gemini-3.5-flash-lite';
export const GEMINI_SECRET = 'gemini-api-key';
const ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/';
const LANGUAGE_NAMES = { sv: 'svenska', en: 'engelska' };

export function aiModel() {
  const stored = String(settings.aiModel ?? '').trim();
  return stored || DEFAULT_MODEL;
}

export async function isConfigured() {
  return Boolean(await secretGet(GEMINI_SECRET));
}

class GeminiFailure extends Error {}

function failure(status, message) {
  const text = String(message ?? '');
  if ((status === 400 && text.toLowerCase().includes('api key')) || status === 401 || status === 403) {
    return new GeminiFailure('Google godkände inte nyckeln. Kontrollera den under Inställningar.');
  }
  if (status === 404) return new GeminiFailure('Modellen finns inte. Kontrollera modellens namn under Inställningar.');
  if (status === 429) return new GeminiFailure('Gratiskvoten är slut för stunden. Prova igen om en stund.');
  return new GeminiFailure(`Gemini svarade med fel ${status}. ${text.slice(0, 160)}`);
}

/** Betydelserna och orden som modellen får välja bland, med korta id:n (b1a, b1b, b2a ...). */
export function candidates(lookup) {
  const senseLines = [];
  const senseTexts = {};
  let words = [];
  lookup.entries.slice(0, 3).forEach((entry, entryIndex) => {
    const translations = entry.translations.map((t) => t.text);
    words = words.concat(translations);
    entry.senses.slice(0, 6).forEach((sense, senseIndex) => {
      const id = `b${entryIndex + 1}${String.fromCharCode(97 + senseIndex)}`;
      const synonyms = sense.synonyms.slice(0, 8).map((s) => s.word);
      words = words.concat(synonyms);
      const gloss = sense.definition ?? synonyms.slice(0, 4).join(', ');
      senseTexts[id] = gloss;
      let line = `${id} (${entry.posName}): ${gloss}`;
      if (synonyms.length) line += `; ${synonyms.join(', ')}`;
      senseLines.push(line);
    });
    if (!entry.senses.length && translations.length) {
      const id = `b${entryIndex + 1}a`;
      senseTexts[id] = translations.join(', ');
      senseLines.push(`${id} (${entry.posName}): ${translations.join(', ')}`);
    }
  });
  const seen = new Set();
  words = words.filter((word) => {
    const key = word.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return { senseLines, senseTexts, words };
}

export function schemaFor({ senseTexts, words }) {
  const properties = { explanation: { type: 'string' } };
  const required = ['explanation'];
  const ids = Object.keys(senseTexts).sort();
  if (ids.length) {
    properties.sense_id = { type: 'string', enum: ids };
    required.push('sense_id');
  }
  if (words.length) properties.best_word = { type: 'string', enum: words.concat(['']) };
  return { type: 'object', properties, required };
}

export function promptFor(lookup, sentence, { senseLines, words }) {
  const lines = [
    'Du hjälper en svensk läsare att förstå ett ord i en bok.',
    `Ordet: ${lookup.word}`,
    `Meningen: ${sentence || lookup.word}`,
    `Språk: ${LANGUAGE_NAMES[lookup.language] ?? lookup.language}`,
    '',
    'Ordbokens betydelser (id: förklaring; ord):',
    ...senseLines,
  ];
  if (words.length) lines.push('', `Ord att välja bland: ${words.join(', ')}`);
  lines.push(
    '',
    'Välj det id som passar ordets betydelse i just den här meningen.',
    `Välj det ord ur listan som bäst kan ersätta ordet i meningen${lookup.language === 'en' ? ', helst en svensk översättning.' : '.'}`,
    'Hitta inte på egna ord: best_word ska stå ordagrant i listan, eller vara tom.',
    'Skriv explanation på enkel svenska, högst två korta meningar, om vad ordet betyder här.',
    'Svara bara med JSON enligt schemat.',
  );
  return lines.join('\n');
}

/** Texten i svaret, tolkad som JSON. Tål kodblock runt JSON:en. */
export function answerJSON(json) {
  const parts = json?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return null;
  let text = parts.map((part) => (typeof part.text === 'string' ? part.text : '')).join('');
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start >= 0 && end > start) text = text.slice(start, end + 1);
  try {
    const answer = JSON.parse(text);
    return answer && typeof answer === 'object' ? answer : null;
  } catch {
    return null;
  }
}

/** Svaret, med det modellen hittat på själv bortrensat: { senseText, bestWord, explanation }. */
export function explanationFrom(answer, { senseTexts, words }) {
  const text = typeof answer?.explanation === 'string' ? answer.explanation.trim() : '';
  if (!text) throw new GeminiFailure('Svaret från Gemini gick inte att läsa.');
  const best = typeof answer.best_word === 'string' ? answer.best_word.trim() : null;
  const known = best ? words.find((word) => word.toLowerCase() === best.toLowerCase()) ?? null : null;
  const senseText = typeof answer.sense_id === 'string' ? senseTexts[answer.sense_id] ?? null : null;
  return { senseText, bestWord: known, explanation: text.slice(0, 400) };
}

async function send(prompt, schema, key, useSchema) {
  const generationConfig = { responseMimeType: 'application/json', temperature: 0.2, maxOutputTokens: 400 };
  if (useSchema) generationConfig.responseJsonSchema = schema;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  let response;
  try {
    response = await fetch(`${ENDPOINT}${encodeURI(aiModel())}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig }),
      signal: controller.signal,
    });
  } catch (error) {
    throw new GeminiFailure(`Ingen kontakt med Gemini. ${error?.message ?? error}`);
  } finally {
    clearTimeout(timer);
  }
  const body = await response.text();
  let json = null;
  try {
    json = JSON.parse(body);
  } catch {
    json = null;
  }
  if (!response.ok) {
    const message = json?.error?.message ?? '';
    // Äldre modeller känner inte till responseJsonSchema: fråga igen med schemat bara i texten.
    if (useSchema && response.status === 400 && message.includes('response') && !message.toLowerCase().includes('api key')) {
      return send(`${prompt}\n\nJSON-schema: ${JSON.stringify(schema)}`, schema, key, false);
    }
    throw failure(response.status, message);
  }
  const answer = answerJSON(json);
  if (!answer) throw new GeminiFailure('Svaret från Gemini gick inte att läsa.');
  return answer;
}

/** Ber modellen välja betydelse och ord för ordet i meningen. */
export async function explain(lookup, sentence) {
  const key = await secretGet(GEMINI_SECRET);
  if (!key) throw new GeminiFailure('Ingen API-nyckel. Skriv in den under Inställningar.');
  const choices = candidates(lookup);
  const answer = await send(promptFor(lookup, sentence, choices), schemaFor(choices), key, true);
  return explanationFrom(answer, choices);
}

/** Provar nyckeln och modellen med en liten fråga. */
export async function testKey(key) {
  const schema = { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] };
  await send('Svara med {"ok": true}.', schema, key, true);
}
