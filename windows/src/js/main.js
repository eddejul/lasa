// Läsa för Windows: start, flikarna Bibliotek, Sparade ord och Om ordboken, och läsaren.

import { renderAbout } from './about.js';
import { checkDictionary, dictionary } from './context.js';
import { ACCEPT_ATTRIBUTE, importFiles, renderLibrary } from './library.js';
import { setAboutHandler } from './popup.js';
import { closeReader, openReader } from './reader.js';
import { renderSavedWords } from './savedwords.js';
import { renderSettings } from './settings.js';
import { getBook, openStore, settings } from './store.js';
import { syncSoon, syncState } from './sync.js';
import { applyTheme } from './theme.js';
import { el, replace, toast } from './ui.js';

const app = document.getElementById('app');
const TABS = [
  { id: 'library', title: 'Bibliotek' },
  { id: 'saved', title: 'Sparade ord' },
  { id: 'about', title: 'Om ordboken' },
  { id: 'settings', title: 'Inställningar' },
];
let currentTab = null;

async function showTab(tab) {
  await closeReader();
  currentTab = tab;
  document.title = 'Läsa';
  const content = el('main', { class: 'main-content', dataset: { view: tab } });
  const fileInput = el('input', { type: 'file', multiple: true, accept: ACCEPT_ATTRIBUTE, hidden: true, dataset: { testid: 'file-input' } });
  fileInput.addEventListener('change', async () => {
    const files = [...fileInput.files];
    fileInput.value = '';
    if (await importFiles(files) && currentTab === 'library') showTab('library');
  });
  const header = el('header', { class: 'toolbar main-toolbar' },
    el('div', { class: 'app-name' }, 'Läsa'),
    el('nav', { class: 'tabs' }, TABS.map((item) => el('button', {
      class: `tab${item.id === tab ? ' selected' : ''}`, onclick: () => showTab(item.id), dataset: { testid: `tab-${item.id}` },
    }, item.title))),
    el('div', { class: 'toolbar-spacer' }),
    tab === 'library' ? el('button', { class: 'button primary', onclick: () => fileInput.click(), dataset: { testid: 'add-books' } }, 'Lägg till böcker') : null,
    fileInput);
  replace(app, header, content);
  if (tab === 'library') await renderLibrary(content, { onOpen: openBook });
  else if (tab === 'saved') await renderSavedWords(content);
  else if (tab === 'settings') await renderSettings(content);
  else await renderAbout(content);
}

/** Sparade ord eller Om ordboken som en ruta över läsaren, så att man inte tappar sin plats. */
function openModal(title, render) {
  const layer = document.getElementById('modal-layer');
  const body = el('div', { class: 'modal-content' });
  const close = () => {
    backdrop.remove();
    document.removeEventListener('keydown', onKey, true);
  };
  const onKey = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
    }
  };
  const backdrop = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === backdrop) close(); } },
    el('div', { class: 'modal-panel', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
      el('div', { class: 'panel-head' }, el('h2', {}, title),
        el('button', { class: 'popup-close', onclick: close, 'aria-label': 'Stäng' }, '×')),
      body));
  layer.append(backdrop);
  document.addEventListener('keydown', onKey, true);
  render(body);
}

async function openBook(id) {
  const book = await getBook(id);
  if (!book) {
    toast('Boken finns inte längre i biblioteket.');
    showTab('library');
    return;
  }
  currentTab = null;
  document.title = `${book.title} · Läsa`;
  const container = el('div', { class: 'reader-container' });
  replace(app, container);
  await openReader(container, book, {
    onBack: () => showTab('library'),
    onSavedWords: () => openModal('Sparade ord', renderSavedWords),
    onAbout: () => openModal('Om ordboken', renderAbout),
  });
}

// Dra in filer var som helst i fönstret.
function setUpDrop() {
  const overlay = document.getElementById('drop-overlay');
  let depth = 0;
  const hasFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes('Files');
  window.addEventListener('dragenter', (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    depth += 1;
    overlay.hidden = false;
  });
  window.addEventListener('dragover', (event) => {
    if (hasFiles(event)) event.preventDefault();
  });
  window.addEventListener('dragleave', (event) => {
    if (!hasFiles(event)) return;
    depth = Math.max(0, depth - 1);
    if (!depth) overlay.hidden = true;
  });
  window.addEventListener('drop', async (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    depth = 0;
    overlay.hidden = true;
    const added = await importFiles([...event.dataTransfer.files]);
    if (added && currentTab === 'library') showTab('library');
  });
}

/** Slår upp några ord i bakgrunden efter start, så att ordboksfilen och frågorna är varma och första
 *  dubbelklicket går lika fort som de följande. Inget sparas och inget visas. */
function warmDictionary() {
  setTimeout(async () => {
    for (const [word, language] of [['undersökningen', 'sv'], ['sprang', 'sv'], ['went', 'en'], ['libraries', 'en']]) {
      try {
        await dictionary.lookup(word, { language });
      } catch {
        return;
      }
    }
  }, 400);
}

async function start() {
  try {
    await openStore();
  } catch (error) {
    replace(app, el('div', { class: 'empty' }, el('p', {}, 'Läsa kunde inte öppna sina filer.'), el('p', { class: 'muted' }, String(error?.message ?? error))));
    return;
  }
  applyTheme(settings.theme);
  setAboutHandler(() => openModal('Om ordboken', renderAbout));
  setUpDrop();
  // Webbvyns egen högerklicksmeny (Uppdatera, Spara som och liknande) passar inte i appen.
  // Högerklick på ett ord i en bok slår upp ordet, det sköter läsarna själva.
  document.addEventListener('contextmenu', (event) => {
    if (!event.target.closest?.('input, textarea')) event.preventDefault();
  });
  const { error } = await checkDictionary();
  if (error) toast(error, 10);
  else warmDictionary();
  // Efter en synk visas hämtade ord direkt om Sparade ord är öppet.
  window.addEventListener('lasa-sync', () => {
    if (!syncState.running && currentTab === 'saved') {
      const content = app.querySelector('.main-content[data-view="saved"]');
      if (content) renderSavedWords(content);
    }
  });
  await showTab('library');
  syncSoon();
}

start();
