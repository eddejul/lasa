// Markeringar i fyra färger, anteckningar och bokmärken för den öppna boken (W1).
//
// Lagras i bibliotek.sqlite i samma format som iPaden (store.js och docs/SYNK.md): section är sidan i en
// PDF och kapitlet bland bokens dokument i en EPUB eller textfil, start och length gäller sidans eller
// kapitlets text i UTF-16, och text är den markerade texten. Stämmer inte platsen (texten räknas lite
// olika i pdf.js och iPadens PDFKit) letas markeringen upp via sin text, närmast den sparade platsen.
// Synken av markeringar görs senare, när synken byts mot filer i iCloud Drive.

import { relocate } from './chaptertext.js';
import {
  HIGHLIGHT_COLORS, addBookmark, bookBookmarks, bookHighlights, deleteBookmark, deleteHighlight, saveHighlight, settings,
  setSetting,
} from './store.js';
import { el, replace } from './ui.js';

// Samma färger som HighlightColor i AnnotationStore.swift.
export const COLORS = {
  yellow: { title: 'Gul', solid: 'rgb(255, 204, 26)', strong: 'rgba(230, 170, 0, 0.95)' },
  green: { title: 'Grön', solid: 'rgb(92, 204, 102)', strong: 'rgba(40, 160, 60, 0.95)' },
  blue: { title: 'Blå', solid: 'rgb(89, 158, 255)', strong: 'rgba(40, 110, 230, 0.95)' },
  pink: { title: 'Rosa', solid: 'rgb(255, 115, 168)', strong: 'rgba(230, 60, 130, 0.95)' },
};

const hasNote = (highlight) => Boolean(highlight.note?.trim());

/** Färgen som nya markeringar får: den som valdes senast, som på iPaden. */
export function lastColor() {
  return HIGHLIGHT_COLORS.includes(settings.highlightColor) ? settings.highlightColor : 'yellow';
}

export class BookAnnotations {
  constructor(book) {
    this.book = book;
    this.highlights = [];
    this.bookmarks = [];
  }

  async load() {
    this.highlights = await bookHighlights(this.book.id);
    this.bookmarks = await bookBookmarks(this.book.id);
  }

  /** Markeringarna i ett avsnitt, med platsen i avsnittets text: [{ id, start, end, color, note, style }]. */
  marksFor(section, text) {
    const result = [];
    for (const highlight of this.highlights) {
      if (highlight.section !== section) continue;
      const place = relocate(text, highlight);
      if (!place) continue;
      const color = COLORS[highlight.color] ?? COLORS.yellow;
      result.push({ id: highlight.id, start: place.start, end: place.end, color: highlight.color, note: highlight.note,
        style: { color: color.solid, strong: color.strong, note: hasNote(highlight) } });
    }
    return result;
  }

  get(id) {
    return this.highlights.find((highlight) => highlight.id === id) ?? null;
  }

  /** Markerar ett intervall. Överlappar det markeringar i samma avsnitt slås de ihop till en, med den nya
   *  färgen och alla anteckningar kvar (som addHighlight på iPaden). */
  async add({ section, start, end, sectionText }, color) {
    let newStart = start;
    let newEnd = end;
    const notes = [];
    const overlapping = this.highlights.filter((h) => h.section === section && h.start < end && h.start + h.length > start);
    for (const old of overlapping) {
      newStart = Math.min(newStart, old.start);
      newEnd = Math.max(newEnd, old.start + old.length);
      if (hasNote(old)) notes.push(old.note);
      await deleteHighlight(old.id);
    }
    const highlight = await saveHighlight({
      id: crypto.randomUUID().toLowerCase(), book: this.book.id, section, start: newStart, length: newEnd - newStart,
      text: sectionText.slice(newStart, newEnd).replace(/\s+/g, ' ').trim(), color, note: notes.join('\n\n'),
    });
    await setSetting('highlightColor', color);
    this.highlights = this.highlights.filter((h) => !overlapping.includes(h)).concat([highlight])
      .sort((a, b) => a.section - b.section || a.start - b.start);
    return highlight;
  }

  async update(id, changes) {
    const old = this.get(id);
    if (!old) return null;
    const saved = await saveHighlight({ ...old, ...changes });
    this.highlights = this.highlights.map((h) => (h.id === id ? saved : h));
    if (changes.color) await setSetting('highlightColor', changes.color);
    return saved;
  }

  async remove(id) {
    await deleteHighlight(id);
    this.highlights = this.highlights.filter((h) => h.id !== id);
  }

  // Bokmärken

  /** Bokmärkena på platsen: PDF-sidorna som syns, eller sidan i kapitlet (från start och en sidas längd). */
  bookmarksAt(place) {
    if (!place) return [];
    if (place.pages) return this.bookmarks.filter((b) => place.pages.includes(b.section));
    return this.bookmarks.filter((b) => b.section === place.section
      && b.progression >= place.progression - 0.0005 && b.progression < place.progression + Math.max(place.extent ?? 0, 0.0005));
  }

  /** Lägger ett bokmärke på platsen, eller tar bort det som finns där. Ger true om det lades till. */
  async toggleBookmark(place, label) {
    const existing = this.bookmarksAt(place);
    if (existing.length) {
      for (const bookmark of existing) await deleteBookmark(bookmark.id);
      this.bookmarks = this.bookmarks.filter((b) => !existing.includes(b));
      return false;
    }
    const section = place.pages ? place.pages[0] : place.section;
    const bookmark = await addBookmark({ book: this.book.id, section, progression: place.pages ? 0 : place.progression, label });
    this.bookmarks = this.bookmarks.concat([bookmark]).sort((a, b) => a.section - b.section || a.progression - b.progression);
    return true;
  }

  async removeBookmark(id) {
    await deleteBookmark(id);
    this.bookmarks = this.bookmarks.filter((b) => b.id !== id);
  }
}

// Rutorna: färgval för en ny markering, menyn för en markering, och anteckningen.

let menu = null;

export function closeMarkMenu() {
  if (!menu) return;
  const { element } = menu;
  menu = null;
  element.remove();
  document.removeEventListener('mousedown', onOutside, true);
  document.removeEventListener('keydown', onMenuKey, true);
}

export function isMarkMenuOpen() {
  return menu !== null;
}

function onOutside(event) {
  if (menu && !menu.element.contains(event.target)) closeMarkMenu();
}

function onMenuKey(event) {
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopPropagation();
    closeMarkMenu();
  }
}

function showMenu(anchor, content) {
  closeMarkMenu();
  const element = el('div', { class: 'mark-menu', role: 'toolbar', dataset: { testid: 'mark-menu' } }, content);
  document.getElementById('popup-layer').append(element);
  menu = { element };
  const margin = 8;
  const width = element.offsetWidth;
  const height = element.offsetHeight;
  let top = anchor.top - height - 10;
  if (top < margin) top = anchor.bottom + 10;
  top = Math.min(top, window.innerHeight - height - margin);
  const left = Math.max(margin, Math.min(window.innerWidth - width - margin, anchor.left + anchor.width / 2 - width / 2));
  element.style.top = `${Math.round(top)}px`;
  element.style.left = `${Math.round(left)}px`;
  // Rutan öppnas av ett musklick: lyssna efter klick utanför först efter det.
  setTimeout(() => {
    if (menu?.element !== element) return;
    document.addEventListener('mousedown', onOutside, true);
    document.addEventListener('keydown', onMenuKey, true);
  }, 0);
  return element;
}

function colorButtons(selected, onColor) {
  return HIGHLIGHT_COLORS.map((color) => el('button', {
    class: `mark-color color-${color}${color === selected ? ' selected' : ''}`, title: COLORS[color].title,
    'aria-label': `Markera ${COLORS[color].title.toLowerCase()}`, dataset: { testid: `mark-${color}` },
    onmousedown: (event) => event.preventDefault(), // markeringen i texten får inte försvinna före klicket
    onclick: () => onColor(color),
  }));
}

/** Färgval vid en markering i texten. */
export function showSelectionMenu(anchor, { onColor, onNote }) {
  showMenu(anchor, [
    ...colorButtons(null, (color) => {
      closeMarkMenu();
      onColor(color);
    }),
    el('button', { class: 'mark-action', dataset: { testid: 'mark-note' }, onmousedown: (event) => event.preventDefault(),
      onclick: () => {
        closeMarkMenu();
        onNote();
      } }, 'Anteckning'),
  ]);
}

/** Menyn för en markering som finns: byt färg, anteckning, kopiera och ta bort. */
export function showHighlightMenu(anchor, highlight, { onColor, onNote, onDelete }) {
  showMenu(anchor, [
    ...colorButtons(highlight.color, (color) => {
      closeMarkMenu();
      onColor(color);
    }),
    el('button', { class: 'mark-action', dataset: { testid: 'mark-note' }, onclick: () => {
      closeMarkMenu();
      onNote();
    } }, hasNote(highlight) ? 'Ändra anteckning' : 'Anteckning'),
    el('button', { class: 'mark-action', onclick: () => {
      closeMarkMenu();
      navigator.clipboard?.writeText(highlight.text).catch(() => {});
    } }, 'Kopiera'),
    el('button', { class: 'mark-action danger', dataset: { testid: 'mark-delete' }, onclick: () => {
      closeMarkMenu();
      onDelete();
    } }, 'Ta bort'),
  ]);
}

/** Anteckningen till en markering. Ger texten, eller null om den avbryts. */
export function editNote(highlight) {
  return new Promise((resolve) => {
    const layer = document.getElementById('modal-layer');
    const area = el('textarea', { class: 'text-input note-input', rows: '7', 'aria-label': 'Anteckning',
      dataset: { testid: 'note-input' }, placeholder: 'Din anteckning' });
    area.value = highlight.note ?? '';
    const close = (answer) => {
      backdrop.remove();
      resolve(answer);
    };
    const backdrop = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === backdrop) close(null); } },
      el('div', { class: 'dialog note-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Anteckning' },
        el('h2', {}, 'Anteckning'),
        el('blockquote', { class: `note-quote color-${highlight.color}` }, highlight.text),
        area,
        el('div', { class: 'dialog-buttons' },
          el('button', { class: 'button', onclick: () => close(null) }, 'Avbryt'),
          el('button', { class: 'button primary', dataset: { testid: 'note-save' }, onclick: () => close(area.value.trim()) }, 'Spara'))));
    area.addEventListener('keydown', (event) => {
      event.stopPropagation();
      if (event.key === 'Escape') {
        event.preventDefault();
        close(null);
      } else if (event.key === 'Enter' && event.ctrlKey) {
        event.preventDefault();
        close(area.value.trim());
      }
    });
    layer.append(backdrop);
    area.focus();
  });
}

/** Panelen Markeringar: bokmärken och markeringar med anteckningar, i bokens ordning. */
export function renderMarksPanel(panel, annotations, { onClose, onGoToBookmark, onGoToHighlight, placeName, onChanged }) {
  const { bookmarks, highlights } = annotations;
  const bookmarkRows = bookmarks.map((bookmark) => el('div', { class: 'marks-row', dataset: { testid: 'bookmark-row' } },
    el('button', { class: 'marks-go', onclick: () => onGoToBookmark(bookmark) },
      el('span', { class: 'marks-label' }, 'Bokmärke'), el('span', {}, bookmark.label || placeName(bookmark.section))),
    el('button', { class: 'link-button danger', title: 'Ta bort bokmärket', onclick: async () => {
      await annotations.removeBookmark(bookmark.id);
      onChanged();
      renderMarksPanel(panel, annotations, { onClose, onGoToBookmark, onGoToHighlight, placeName, onChanged });
    } }, 'Ta bort')));
  const highlightRows = highlights.map((highlight) => el('button', { class: 'marks-go marks-highlight', dataset: { testid: 'highlight-row' },
    onclick: () => onGoToHighlight(highlight) },
  el('span', { class: 'marks-label' }, placeName(highlight.section)),
  el('span', { class: `marks-quote color-${highlight.color}` }, highlight.text.length > 220 ? `${highlight.text.slice(0, 220)}…` : highlight.text),
  hasNote(highlight) ? el('span', { class: 'marks-note' }, highlight.note) : null));
  replace(panel,
    el('div', { class: 'panel-head' }, el('h2', {}, 'Markeringar'),
      el('button', { class: 'popup-close', onclick: onClose, 'aria-label': 'Stäng', title: 'Stäng (Esc)' }, '×')),
    bookmarkRows.length || highlightRows.length ? null : el('p', { class: 'muted' },
      'Inga markeringar eller bokmärken än. Dra över texten med musen och välj en färg, eller tryck B för ett bokmärke.'),
    bookmarkRows.length ? el('h3', { class: 'panel-subhead' }, 'Bokmärken') : null,
    bookmarkRows,
    highlightRows.length ? el('h3', { class: 'panel-subhead' }, `Markeringar (${highlightRows.length})`) : null,
    highlightRows);
}
