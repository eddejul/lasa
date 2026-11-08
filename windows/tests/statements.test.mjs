// De namngivna databasfrågorna (W12): varje namn som gränssnittet använder finns i
// src-tauri/statements.json, som läsande eller ändrande fråga, och ingen JavaScript-fil skickar egen SQL
// mot användarens databaser.
//   node --test windows/tests/statements.test.mjs

import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const statements = JSON.parse(readFileSync(here('../src-tauri/statements.json'), 'utf8'));
const store = readFileSync(here('../src/js/store.js'), 'utf8');

test('varje fråga i store.js finns i statements.json, av rätt slag', () => {
  const used = [...store.matchAll(/\b(read|write)\('([a-z_]+)'/g)].map(([, kind, name]) => [kind, name]);
  assert.ok(used.length > 20, `för få frågor hittades: ${used.length}`);
  for (const [kind, name] of used) {
    assert.ok(statements[kind]?.[name], `${kind}('${name}') saknas i statements.json`);
  }
});

test('läsande frågor läser och ändrande ändrar, mot en känd databas', () => {
  for (const [name, [db, sql]] of Object.entries(statements.read)) {
    assert.ok(['ord', 'bibliotek'].includes(db), name);
    assert.match(sql, /^SELECT /, `${name} ska vara en SELECT`);
  }
  for (const [name, [db, sql]] of Object.entries(statements.write)) {
    assert.ok(['ord', 'bibliotek'].includes(db), name);
    assert.match(sql, /^(INSERT|UPDATE|DELETE) /, `${name} ska vara INSERT, UPDATE eller DELETE`);
  }
});

test('ingen JavaScript-fil skickar egen SQL till användarens databaser', () => {
  const folder = here('../src/js/');
  for (const file of readdirSync(folder).filter((name) => name.endsWith('.js'))) {
    const text = readFileSync(folder + file, 'utf8');
    assert.ok(!/user_query|user_execute|user_batch/.test(text), `${file} använder de gamla kommandona`);
    if (file === 'lookup.js' || file === 'context.js') continue; // ordboken (skrivskyddad, dict_query)
    assert.ok(!/\b(INSERT INTO|UPDATE \w+ SET|DELETE FROM|CREATE TABLE|ALTER TABLE)\b/.test(text), `${file} innehåller SQL`);
  }
});
