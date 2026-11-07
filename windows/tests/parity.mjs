// Paritetstest: windows/src/js/lookup.js mot tools/dictionary/lookup.py, över hela testlistan.
//
//   node windows/tests/parity.mjs <ordbok.sqlite> [ordlista] [python]
//
// Båda slår upp varje ord som svenska och som engelska mot samma databas, och svaren ska vara lika
// i allt som rutan visar: grundform, ordklass, betydelser, definitioner, synonymer med betyg och
// vanlighet, översättningar och lånade översättningar. Avslutas med kod 1 om något skiljer.

import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Dictionary } from '../src/js/lookup.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const dbPath = process.argv[2];
const listPath = process.argv[3] ?? path.join(here, '..', '..', 'tools', 'dictionary', 'testwords.txt');
const python = process.argv[4] ?? 'python';
if (!dbPath) {
  console.error('Ange ordboksfilen: node windows/tests/parity.mjs <ordbok.sqlite>');
  process.exit(2);
}

const sqlite = new DatabaseSync(dbPath, { readOnly: true });
const statements = new Map();
const db = {
  async all(sql, params) {
    let statement = statements.get(sql);
    if (!statement) {
      statement = sqlite.prepare(sql);
      if (typeof statement.setReturnArrays === 'function') statement.setReturnArrays(true);
      statements.set(sql, statement);
    }
    const rows = statement.all(...params);
    return rows.map((row) => (Array.isArray(row) ? row : Object.values(row)));
  },
};
const dictionary = new Dictionary(db);

/** JavaScript-svaret i samma form som lookup.py ger (listor i stället för tupler). */
function pythonShape(result) {
  if (!result) return null;
  return {
    language: result.language,
    word: result.word,
    key: result.key,
    compound: result.compound,
    entries: result.entries.map((entry) => ({
      lemma: entry.lemma,
      pos: entry.pos,
      pos_name: entry.posName,
      senses: entry.senses.map((sense) => ({
        id: sense.id,
        definition: sense.definition,
        synonyms: sense.synonyms.map((s) => [s.word, s.score, s.freq]),
      })),
      translations: entry.translations.map((t) => [t.text, t.comment]),
      via: entry.via,
    })),
  };
}

function difference(a, b, where = '') {
  if (a === b) return null;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') {
    return `${where || '(svaret)'}: lookup.py ${JSON.stringify(a)}, lookup.js ${JSON.stringify(b)}`;
  }
  if (Array.isArray(a) !== Array.isArray(b)) return `${where}: olika typer`;
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const key of keys) {
    const found = difference(a[key], b[key], `${where}.${key}`);
    if (found) return found;
  }
  return null;
}

const dump = spawnSync(python, [path.join(here, 'parity_dump.py'), dbPath, listPath], {
  encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
});
if (dump.status !== 0) {
  console.error(dump.stderr);
  process.exit(2);
}
const expected = dump.stdout.trim().split('\n').map((line) => JSON.parse(line));

let failures = 0;
let compared = 0;
const started = performance.now();
for (const item of expected) {
  const has = await dictionary.has(item.word);
  const sv = pythonShape(await dictionary.lookupSv(item.word));
  const en = pythonShape(await dictionary.lookupEn(item.word));
  for (const [name, a, b] of [['has', item.has, has], ['sv', item.sv, sv], ['en', item.en, en]]) {
    compared += 1;
    const found = difference(a, b, name);
    if (found) {
      failures += 1;
      console.log(`SKILLNAD ${item.word}: ${found}`);
    }
  }
}
const elapsed = performance.now() - started;
console.log(`${expected.length} ord, ${compared} jämförelser, ${failures} skillnader, `
  + `${(elapsed / expected.length).toFixed(1)} ms per ord i JavaScript`);
process.exit(failures ? 1 : 0);
