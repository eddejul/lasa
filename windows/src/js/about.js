// Om ordboken: källor och licenser (som licenserna kräver), databasens innehåll, hur snabba uppslagen
// är, programbiblioteken som följer med appen, och synonymer som har dolts med Fel synonym.
// Samma källor och texter som AboutDictionaryViewController.swift på iPaden.

import { openUrl } from './backend.js';
import { checkDictionary, dictionary, lookupStats } from './context.js';
import { hidden, unhidePair } from './store.js';
import { el, replace } from './ui.js';

const SOURCES = [
  { name: 'Folkets synonymlexikon (Synlex)',
    use: 'Svenska synonympar med betyg. Bara par med betyg 3 eller högre på den femgradiga skalan visas.',
    license: 'Copyright (c) Viggo Kann, KTH, 2009. Fri att använda och kopiera med upphovsnotisen kvar. '
      + 'Sensus använder en bearbetad version: paren är kopplade till betydelser och ordklasser.',
    url: 'https://folkets-lexikon.csc.kth.se/synlex.html' },
  { name: 'Swesaurus, Språkbanken Text, Göteborgs universitet',
    use: 'Vilken betydelse en svensk synonym hör till.',
    license: 'CC BY 4.0',
    url: 'https://spraakbanken.gu.se/resurser/swesaurus' },
  { name: 'SALDO och SALDO morfologi, Språkbanken Text, Göteborgs universitet',
    use: 'Svenska grundformer, ordklasser, böjningsformer och betydelser.',
    license: 'CC BY 4.0',
    url: 'https://spraakbanken.gu.se/resurser/saldo' },
  { name: 'Open English WordNet 2025',
    use: 'Engelska betydelser, definitioner och synonymer.',
    license: 'CC BY 4.0',
    url: 'https://en-word.net' },
  { name: 'Folkets lexikon, KTH',
    use: 'Svensk översättning av engelska ord, definitioner på enkel svenska och oregelbundna engelska böjningar.',
    license: 'CC BY-SA 2.5. Den bearbetade versionen i Sensus delas under samma licens.',
    url: 'https://folkets-lexikon.csc.kth.se/folkets/' },
  { name: 'wordfreq, Robyn Speer',
    use: 'Hur vanliga orden är, så att vanliga synonymer visas först. Bygger bland annat på Wikipedia, '
      + 'OpenSubtitles 2018, Google Books Ngram Viewer, ParaCrawl och SUBTLEX (Marc Brysbaert med flera, fritt tillgänglig data).',
    license: 'CC BY-SA 4.0',
    url: 'https://github.com/rspeer/wordfreq' },
];

// Programbibliotek som följer med Windows-appen. file: licenstexten bland appens filer.
const LIBRARIES = [
  { name: 'foliate-js, John Factotum', use: 'Visar EPUB och textfiler.', license: 'MIT',
    url: 'https://github.com/johnfactotum/foliate-js', file: 'vendor/foliate-js/LICENSE' },
  { name: 'zip.js, Gildas Lormeau', use: 'Packar upp EPUB-filer (ingår i foliate-js).', license: 'BSD 3-Clause',
    url: 'https://github.com/gildas-lormeau/zip.js', file: 'vendor/foliate-js/vendor/LICENSE-zip.js.txt' },
  { name: 'PDF.js, Mozilla', use: 'Visar PDF-filer och deras text.', license: 'Apache License 2.0',
    url: 'https://mozilla.github.io/pdf.js/', file: 'vendor/pdfjs/LICENSE' },
  { name: 'Tauri', use: 'Fönstret och kopplingen till Windows.', license: 'MIT eller Apache License 2.0',
    url: 'https://tauri.app' },
  { name: 'SQLite och rusqlite', use: 'Läser ordboken och sparar dina ord och böcker.', license: 'SQLite: public domain. rusqlite: MIT.',
    url: 'https://www.sqlite.org' },
];

function group(title, rows, footer = null) {
  return el('section', { class: 'list-section' },
    title ? el('h3', {}, title) : null,
    el('div', { class: 'list-group' }, rows),
    footer ? el('p', { class: 'list-footer' }, footer) : null);
}

function item(text, secondary = null, extra = null) {
  return el('div', { class: 'list-row' },
    el('div', { class: 'list-text' }, text),
    secondary ? el('div', { class: 'list-secondary' }, secondary) : null,
    extra);
}

function linkButton(label, url) {
  return el('button', { class: 'link-button', onclick: () => openUrl(url) }, label);
}

function licenseToggle(file) {
  const holder = el('div', {});
  const button = el('button', { class: 'link-button', onclick: async () => {
    if (holder.childElementCount) {
      holder.replaceChildren();
      button.textContent = 'Visa licenstexten';
      return;
    }
    const text = await (await fetch(file)).text();
    replace(holder, el('pre', { class: 'license-text' }, text));
    button.textContent = 'Dölj licenstexten';
  } }, 'Visa licenstexten');
  return [button, holder];
}

/** Ritar Om ordboken i `container`. */
export async function renderAbout(container) {
  const { meta, error } = await checkDictionary();
  let database;
  if (meta) {
    const counts = await dictionary.counts();
    const number = (n) => Number(n).toLocaleString('sv-SE');
    database = item(`Byggd ${meta.built ?? 'okänt datum'}`,
      `${number(counts.swedishWords)} svenska ord, ${number(counts.swedishPairs)} svenska synonympar, `
      + `${number(counts.swedishDefinitions)} svenska definitioner, ${number(counts.englishWords)} engelska ord och `
      + `${number(counts.translations)} översättningar till svenska. Allt finns i appen och fungerar utan internet.`);
  } else {
    database = item('Ordboken saknas i den här versionen av appen, eller är av en äldre version.', error);
  }

  const hiddenRows = hidden.list.map((pair) => item(`${pair.lemma}: ${pair.synonym}`, pair.language === 'en' ? 'engelska' : 'svenska',
    el('button', { class: 'link-button', onclick: async () => {
      await unhidePair(pair.language, pair.lemma, pair.synonym);
      renderAbout(container);
    } }, 'Visa igen')));

  replace(container,
    el('div', { class: 'about' },
      group('Ordboken', [database]),
      group('Hastighet', [item(lookupStats.summary() ?? 'Inga uppslag än i den här körningen.')],
        'Målet är att rutan ska vara klar på under 150 ms efter dubbelklicket.'),
      group('Källor och licenser', SOURCES.map((source) => item(source.name, `${source.use}\nLicens: ${source.license}`,
        linkButton('Öppna källans webbplats', source.url)))),
      group('Svenska Akademien', [item('SO och SAOL', 'Svenska Akademiens ordböcker har ingen öppen licens. Knappen '
        + 'Visa i SO och SAOL öppnar svenska.se i webbläsaren, och inget därifrån sparas i appen.')]),
      group('Program som ingår i appen', LIBRARIES.map((library) => item(library.name, `${library.use}\nLicens: ${library.license}`,
        el('div', { class: 'row-buttons' }, linkButton('Webbplats', library.url), library.file ? licenseToggle(library.file) : null)))),
      hiddenRows.length ? group('Dolda synonymer', hiddenRows, 'Klicka på Visa igen för att visa en synonym igen.') : null));
}
