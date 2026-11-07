// Det som hela appen delar: ordboken och mätningen av hur snabba uppslagen är.

import { dictionaryDb } from './backend.js';
import { Dictionary, SCHEMA_VERSION } from './lookup.js';

export const dictionary = new Dictionary(dictionaryDb);

/** Läser ordbokens meta-tabell. Ger null och ett felmeddelande om ordboken saknas eller är för gammal. */
export async function checkDictionary() {
  try {
    const meta = await dictionary.meta();
    if ((parseInt(meta.schema_version, 10) || 0) < SCHEMA_VERSION) {
      return { meta: null, error: 'Ordboken i appen är av en äldre version.' };
    }
    return { meta, error: null };
  } catch (error) {
    return { meta: null, error: `Ordboken kunde inte läsas (${error?.message ?? error}).` };
  }
}

/** Hur lång tid uppslagen tar. Finns bara i minnet och visas under Om ordboken. */
export const lookupStats = {
  lookup: [],
  ready: [],
  record(lookupMs, readyMs) {
    this.lookup = this.lookup.concat([lookupMs]).slice(-50);
    this.ready = this.ready.concat([readyMs]).slice(-50);
  },
  summary() {
    if (!this.ready.length) return null;
    const median = [...this.ready].sort((a, b) => a - b)[Math.floor(this.ready.length / 2)];
    return `Senaste: uppslag ${Math.round(this.lookup.at(-1))} ms, rutan klar efter ${Math.round(this.ready.at(-1))} ms. `
      + `Mittvärde för de senaste ${this.ready.length}: ${Math.round(median)} ms.`;
  },
};
