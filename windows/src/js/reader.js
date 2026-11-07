// Läsarens ram: verktygsraden, sidan, reglaget och sidnumret nere, tangenter och mushjul.
// Själva sidorna ritas av PdfReader (PDF) eller ReflowReader (EPUB och text).

import { readBookFile } from './backend.js';
import { closeWordPopup, isWordPopupOpen, showWordPopup } from './popup.js';
import { PdfReader } from './pdfreader.js';
import { FONTS, ReflowReader, SIZES } from './reflowreader.js';
import { markOpened, savePosition, setSetting, settings } from './store.js';
import { el, promptDialog, replace, toast } from './ui.js';

const THEMES = [
  { id: 'white', title: 'Vitt' },
  { id: 'sepia', title: 'Sepia' },
  { id: 'dark', title: 'Mörkt' },
];

let active = null;

export function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
}

export async function closeReader() {
  if (!active) return;
  const reader = active;
  active = null;
  await reader.close();
}

/** Öppnar en bok i `container`. onBack går tillbaka till biblioteket. */
export async function openReader(container, book, { onBack, onSavedWords, onAbout }) {
  await closeReader();
  const bytes = await readBookFile(book.id, book.ext);
  const stage = el('div', { class: 'reader-stage', tabindex: '-1' });
  const label = el('button', { class: 'page-label', title: book.format === 'pdf' ? 'Gå till sida' : null }, '');
  const slider = el('input', { type: 'range', class: 'page-slider', min: '0', max: '1000', value: '0', 'aria-label': 'Plats i boken' });
  const panel = el('div', { class: 'reader-panel', hidden: true });

  const toolbar = el('header', { class: 'toolbar reader-toolbar' },
    el('button', { class: 'toolbar-button', onclick: () => onBack(), title: 'Tillbaka till biblioteket (Esc)' }, '‹ Bibliotek'),
    el('div', { class: 'reader-title', title: book.title }, book.title),
    el('div', { class: 'toolbar-buttons' },
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('toc'), dataset: { testid: 'toc-button' } }, 'Innehåll'),
      book.format === 'pdf' ? el('button', { class: 'toolbar-button', onclick: () => goToPage() }, 'Gå till sida') : null,
      book.format !== 'pdf' ? el('button', { class: 'toolbar-button', onclick: () => togglePanel('type'), title: 'Typsnitt och storlek' }, 'Aa') : null,
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('theme'), dataset: { testid: 'theme-button' } }, 'Tema'),
      el('button', { class: 'toolbar-button', onclick: () => onSavedWords() }, 'Sparade ord'),
      el('button', { class: 'toolbar-button', onclick: () => onAbout() }, 'Om ordboken')));

  const arrows = [
    el('button', { class: 'page-arrow left', 'aria-label': 'Föregående sida', onclick: () => turn(-1) }, '‹'),
    el('button', { class: 'page-arrow right', 'aria-label': 'Nästa sida', onclick: () => turn(1) }, '›'),
  ];
  const view = el('div', { class: 'reader' },
    toolbar,
    el('div', { class: 'reader-body' }, stage, arrows, panel),
    el('footer', { class: 'reader-bottom' }, slider, label));
  replace(container, view);

  let location = null;
  let saveTimer = null;
  const save = () => {
    clearTimeout(saveTimer);
    saveTimer = null;
    if (location) return savePosition(book.id, location.position, location.fraction);
    return null;
  };
  const onRelocate = (next) => {
    location = next;
    label.textContent = next.label;
    if (document.activeElement !== slider) slider.value = String(Math.round(next.fraction * 1000));
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, 400);
  };
  const onWord = (word) => {
    showWordPopup({ ...word, book: { id: book.id, title: book.title }, onClose: word.clear });
  };

  // Tangenter och mushjul
  const isTyping = (event) => /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName ?? '') && event.target !== slider;
  const turn = (direction) => {
    closeWordPopup();
    return direction > 0 ? reader.next() : reader.prev();
  };
  const onKey = (event) => {
    if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey) return;
    if (document.querySelector('#modal-layer .modal-backdrop')) return;
    if (event.key === 'Escape') {
      if (isWordPopupOpen()) closeWordPopup();
      else if (!panel.hidden) togglePanel(null);
      else onBack();
      event.preventDefault();
      return;
    }
    if (isTyping(event)) return;
    const forward = ['ArrowRight', 'ArrowDown', 'PageDown'].includes(event.key) || (event.key === ' ' && !event.shiftKey);
    const backward = ['ArrowLeft', 'ArrowUp', 'PageUp'].includes(event.key) || (event.key === ' ' && event.shiftKey);
    if (forward || backward) {
      event.preventDefault();
      turn(forward ? 1 : -1);
    } else if (event.key === 'Home') {
      event.preventDefault();
      reader.goToFraction(0);
    } else if (event.key === 'End') {
      event.preventDefault();
      reader.goToFraction(1);
    }
  };
  // Ett hack i mushjulet bläddrar en sida. Pekplattans små rörelser samlas ihop, och efter en bläddring
  // väntar hjulet en stund så att en lång rörelse inte bläddrar många sidor.
  let wheelSum = 0;
  let wheelBlockedUntil = 0;
  const onWheel = (event) => {
    if (event.ctrlKey) {
      event.preventDefault();
      return;
    }
    if (!panel.hidden && panel.contains(event.target)) return;
    event.preventDefault();
    const now = performance.now();
    if (now < wheelBlockedUntil) return;
    const delta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX;
    wheelSum += event.deltaMode === 1 ? delta * 40 : delta;
    if (Math.abs(wheelSum) >= 50) {
      const direction = Math.sign(wheelSum);
      wheelSum = 0;
      wheelBlockedUntil = now + 300;
      turn(direction);
    }
  };
  const onPointerDown = () => {
    if (isWordPopupOpen()) closeWordPopup();
  };

  const reader = book.format === 'pdf'
    ? new PdfReader(stage, { onRelocate, onWord, onMessage: (message) => toast(message) })
    : new ReflowReader(stage, { onRelocate, onWord, onKey, onWheel, onPointerDown });

  document.addEventListener('keydown', onKey);
  stage.addEventListener('wheel', onWheel, { passive: false });
  slider.addEventListener('change', () => reader.goToFraction(Number(slider.value) / 1000));
  label.addEventListener('click', () => (book.format === 'pdf' ? goToPage() : null));
  container.addEventListener('contextmenu', (event) => {
    if (!event.target.closest?.('input')) event.preventDefault();
  });

  async function goToPage() {
    const answer = await promptDialog({ title: 'Gå till sida', message: 'Skriv bokens sidnummer (till exempel 45 eller xii).',
      confirm: 'Gå', placeholder: 'Sidnummer' });
    if (answer === null) return;
    if (!reader.goToPageText(answer)) toast(`Hittade ingen sida ${answer}.`);
  }

  async function togglePanel(name) {
    if (!name || panel.dataset.name === name) {
      panel.hidden = true;
      panel.dataset.name = '';
      return;
    }
    panel.dataset.name = name;
    panel.hidden = false;
    if (name === 'toc') {
      const items = await reader.toc();
      const list = (entries, depth) => el('ul', { class: `toc-list depth-${depth}` }, entries.map((entry) => el('li', {},
        el('button', { class: 'toc-item', onclick: async () => {
          togglePanel(null);
          await reader.goToTarget(entry.target);
        } }, entry.label || 'Utan namn'),
        entry.subitems?.length ? list(entry.subitems, depth + 1) : null)));
      replace(panel, el('div', { class: 'panel-head' }, el('h2', {}, 'Innehåll'),
        el('button', { class: 'popup-close', onclick: () => togglePanel(null), 'aria-label': 'Stäng' }, '×')),
      items.length ? list(items, 0) : el('p', { class: 'muted' }, 'Boken har ingen innehållsförteckning.'));
    } else if (name === 'theme') {
      replace(panel, el('div', { class: 'panel-head' }, el('h2', {}, 'Tema'),
        el('button', { class: 'popup-close', onclick: () => togglePanel(null), 'aria-label': 'Stäng' }, '×')),
      el('div', { class: 'theme-choices' }, THEMES.map((theme) => el('button', {
        class: `theme-choice theme-${theme.id}${settings.theme === theme.id ? ' selected' : ''}`,
        dataset: { testid: `theme-${theme.id}` },
        onclick: async () => {
          await setSetting('theme', theme.id);
          applyTheme(theme.id);
          reader.setSettings?.({ theme: theme.id });
          togglePanel(null);
        } }, theme.title))),
      el('p', { class: 'muted' }, 'Gäller alla böcker. Mörkt vänder ljusheten på PDF-sidor men behåller färgerna.'));
    } else if (name === 'type') {
      const sizeLabel = el('span', { class: 'size-label' }, `${Math.round(SIZES[settings.size] * 100)} %`);
      const setSize = async (index) => {
        const size = Math.min(Math.max(index, 0), SIZES.length - 1);
        await setSetting('size', size);
        reader.setSettings({ size });
        sizeLabel.textContent = `${Math.round(SIZES[size] * 100)} %`;
      };
      replace(panel, el('div', { class: 'panel-head' }, el('h2', {}, 'Typsnitt och storlek'),
        el('button', { class: 'popup-close', onclick: () => togglePanel(null), 'aria-label': 'Stäng' }, '×')),
      el('div', { class: 'size-row' },
        el('button', { class: 'button', onclick: () => setSize(settings.size - 1), 'aria-label': 'Mindre text' }, 'A−'),
        sizeLabel,
        el('button', { class: 'button', onclick: () => setSize(settings.size + 1), 'aria-label': 'Större text' }, 'A+')),
      el('div', { class: 'font-list' }, FONTS.map((font) => el('button', {
        class: `font-choice${settings.font === font.id ? ' selected' : ''}`,
        style: font.css ? `font-family: ${font.css}` : null,
        onclick: async () => {
          await setSetting('font', font.id);
          reader.setSettings({ font: font.id });
          togglePanel(null);
          togglePanel('type');
        } }, font.title))));
    }
  }

  active = {
    async close() {
      document.removeEventListener('keydown', onKey);
      closeWordPopup();
      await save();
      reader.destroy();
    },
  };

  await markOpened(book.id);
  try {
    if (book.format === 'pdf') await reader.open(bytes, book.position);
    else await reader.open(bytes, book.position, { ext: book.ext, title: book.title, settings: { ...settings } });
  } catch (error) {
    console.error(error);
    replace(stage, el('div', { class: 'empty' }, el('p', {}, 'Boken kunde inte öppnas.'), el('p', { class: 'muted' }, String(error?.message ?? error))));
  }
  stage.focus({ preventScroll: true });
  return reader;
}
