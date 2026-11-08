// Läsarens ram: verktygsraden, sidan, reglaget och sidnumret nere, tangenter och mushjul.
// Själva sidorna ritas av PdfReader (PDF) eller ReflowReader (EPUB och text).

import { bookFileSize, inTauri, readBookFile, readBookRange } from './backend.js';
import {
  BookAnnotations, closeMarkMenu, editNote, isMarkMenuOpen, lastColor, renderMarksPanel, showHighlightMenu, showSelectionMenu,
} from './annotations.js';
import { bookErrorMessage } from './bookerrors.js';
import { closeWordPopup, isWordPopupOpen, showWordPopup } from './popup.js';
import { PdfReader } from './pdfreader.js';
import { FONTS, ReflowReader, SIZES } from './reflowreader.js';
import { newSearchState, renderSearchPanel } from './searchpanel.js';
import { isBrowserKey } from './shortcuts.js';
import { contentId, markOpened, savePosition, setSetting, settings } from './store.js';
import { syncSoon } from './sync.js';
import { THEMES, applyTheme, resolvedTheme, setThemeListener } from './theme.js';
import { el, promptDialog, replace, toast } from './ui.js';

let active = null;

/** Sant medan en bok är öppen. */
export function isReaderOpen() {
  return active !== null;
}

export async function closeReader() {
  if (!active) return;
  const reader = active;
  active = null;
  await reader.close();
  // Synka när en bok stängs (högst en gång i minuten, och bara om synken är inställd).
  syncSoon();
}

/** Öppnar en bok i `container`. onBack går tillbaka till biblioteket. */
export async function openReader(container, book, { onBack, onSavedWords, onAbout, onAppKey = null }) {
  await closeReader();
  const stage = el('div', { class: 'reader-stage', tabindex: '-1' });
  const loading = el('div', { class: 'reader-loading', dataset: { testid: 'reader-loading' } }, 'Öppnar boken ...');
  const label = el('button', { class: 'page-label', title: book.format === 'pdf' ? 'Gå till sida' : null }, '');
  const slider = el('input', { type: 'range', class: 'page-slider', min: '0', max: '1000', value: '0', 'aria-label': 'Plats i boken' });
  const panel = el('div', { class: 'reader-panel', hidden: true });

  const annotations = new BookAnnotations(book);
  const bookmarkButton = el('button', { class: 'toolbar-button bookmark-button', onclick: () => toggleBookmark(),
    title: 'Bokmärke på sidan (B)', 'aria-pressed': 'false', dataset: { testid: 'bookmark-button' } }, 'Bokmärke');
  const toolbar = el('header', { class: 'toolbar reader-toolbar' },
    el('button', { class: 'toolbar-button', onclick: () => onBack(), title: 'Tillbaka till biblioteket (Esc)' }, '‹ Bibliotek'),
    el('div', { class: 'reader-title', title: book.title }, book.title),
    el('div', { class: 'toolbar-buttons' },
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('toc'), dataset: { testid: 'toc-button' } }, 'Innehåll'),
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('search'), title: 'Sök i boken (Ctrl och F)',
        dataset: { testid: 'search-button' } }, 'Sök'),
      book.format === 'pdf' ? el('button', { class: 'toolbar-button', onclick: () => goToPage() }, 'Gå till sida') : null,
      book.format === 'pdf' ? el('button', { class: 'toolbar-button', onclick: () => togglePanel('zoom'), dataset: { testid: 'zoom-button' } }, 'Visning') : null,
      book.format !== 'pdf' ? el('button', { class: 'toolbar-button', onclick: () => togglePanel('type'), title: 'Typsnitt och storlek' }, 'Aa') : null,
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('marks'), title: 'Markeringar och bokmärken',
        dataset: { testid: 'marks-button' } }, 'Markeringar'),
      bookmarkButton,
      el('button', { class: 'toolbar-button', onclick: () => togglePanel('theme'), dataset: { testid: 'theme-button' } }, 'Tema'),
      el('button', { class: 'toolbar-button', onclick: () => onSavedWords() }, 'Sparade ord'),
      el('button', { class: 'toolbar-button', onclick: () => onAbout() }, 'Om ordboken')));

  const arrows = [
    el('button', { class: 'page-arrow left', 'aria-label': 'Föregående sida', onclick: () => turn(-1) }, '‹'),
    el('button', { class: 'page-arrow right', 'aria-label': 'Nästa sida', onclick: () => turn(1) }, '›'),
  ];
  const view = el('div', { class: 'reader' },
    toolbar,
    el('div', { class: 'reader-body' }, stage, loading, arrows, panel),
    el('footer', { class: 'reader-bottom' }, slider, label));
  replace(container, view);

  // Positionen sparas bara när läsaren har flyttat sig sedan boken öppnades eller senast sparades. Då
  // skriver en öppen bok aldrig över en nyare position som synken hämtat medan boken var öppen (den
  // gäller nästa gång boken öppnas, och läsningen hoppar inte).
  let location = null;
  let saveTimer = null;
  let baseline = null; // positionen när boken hade öppnats klart, eller senast sparades
  const positionKey = (position) => JSON.stringify(position ?? null);
  const save = () => {
    clearTimeout(saveTimer);
    saveTimer = null;
    if (!location || baseline === null) return null;
    const key = positionKey(location.position);
    if (key === baseline) return null;
    baseline = key;
    return savePosition(book.id, location.position, location.fraction);
  };
  let currentPlace = null;
  let currentPlaceLabel = '';
  const updateBookmarkButton = () => {
    const marked = annotations.bookmarksAt(currentPlace).length > 0;
    bookmarkButton.classList.toggle('active', marked);
    bookmarkButton.setAttribute('aria-pressed', String(marked));
  };
  const onRelocate = (next) => {
    label.textContent = next.label;
    currentPlace = next.place ?? null;
    currentPlaceLabel = next.placeLabel ?? next.label;
    updateBookmarkButton();
    if (document.activeElement !== slider) slider.value = String(Math.round(next.fraction * 1000));
    // Medan boken öppnas sparas inget, platsen blir utgångsläget när den har öppnats klart.
    if (baseline === null) {
      location = next;
      return;
    }
    // En omritning på samma ställe (EPUB) är ingen flytt.
    if (next.moved === false) return;
    location = next;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, 400);
  };
  const onWord = (word) => {
    showWordPopup({ ...word, book: { id: book.id, title: book.title }, onClose: word.clear });
  };

  // Tangenter och mushjul
  const isTyping = (event) => /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName ?? '') && event.target !== slider;
  const turn = (direction, options = {}) => {
    closeWordPopup();
    return direction > 0 ? reader.next() : reader.prev(options);
  };
  // Nedåt och uppåt (pil, PageDown, mellanslag): rulla sidan om den rullas, annars bläddra.
  const step = (direction) => {
    closeWordPopup();
    if (reader.scrollStep?.(direction)) return null;
    return turn(direction, { atEnd: direction < 0 });
  };
  const zoom = async (direction) => {
    if (!reader.zoomStep) return;
    await reader.zoomStep(direction);
    await setSetting('pdfZoom', reader.zoom);
  };
  const onKey = (event) => {
    // Tangenter i ett EPUB-kapitel kommer hit från kapitlets ram: webbläsarens egna stoppas, och appens
    // genvägar (F11, Ctrl och O, ?, T) skickas vidare.
    const origin = event.target?.ownerDocument ?? event.target;
    if (origin && origin !== document) {
      if (isBrowserKey(event)) {
        event.preventDefault();
        return;
      }
      onAppKey?.(event);
    }
    if (event.defaultPrevented) return;
    const ctrl = event.ctrlKey || event.metaKey;
    const letter = (event.key ?? '').toLowerCase();
    if (ctrl && !event.altKey && !event.shiftKey && (letter === 'f' || letter === 'g')) {
      event.preventDefault();
      if (letter === 'f') openSearch();
      else goToPage();
      return;
    }
    if (event.ctrlKey && !event.altKey && reader.zoomStep) {
      if (['+', '=', 'Add'].includes(event.key)) {
        event.preventDefault();
        zoom(1);
      } else if (['-', 'Subtract'].includes(event.key)) {
        event.preventDefault();
        zoom(-1);
      } else if (event.key === '0') {
        event.preventDefault();
        reader.setView({ zoom: 1 }).then(() => setSetting('pdfZoom', 1));
      }
      return;
    }
    if (event.ctrlKey || event.altKey || event.metaKey) return;
    if (document.querySelector('#modal-layer .modal-backdrop')) return;
    if (event.key === 'Escape') {
      if (isMarkMenuOpen()) closeMarkMenu();
      else if (isWordPopupOpen()) closeWordPopup();
      else if (!panel.hidden) togglePanel(null);
      else onBack();
      event.preventDefault();
      return;
    }
    if (isTyping(event)) return;
    // Höger och vänster bläddrar alltid. Nedåt och uppåt rullar först om sidan är större än fönstret.
    const down = ['ArrowDown', 'PageDown'].includes(event.key) || (event.key === ' ' && !event.shiftKey);
    const up = ['ArrowUp', 'PageUp'].includes(event.key) || (event.key === ' ' && event.shiftKey);
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
      event.preventDefault();
      turn(event.key === 'ArrowRight' ? 1 : -1);
    } else if (down || up) {
      event.preventDefault();
      step(down ? 1 : -1);
    } else if ((event.key === 'b' || event.key === 'B') && !event.shiftKey) {
      event.preventDefault();
      toggleBookmark();
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
      if (reader.zoomStep && Math.abs(event.deltaY) > 0 && performance.now() >= wheelBlockedUntil) {
        wheelBlockedUntil = performance.now() + 200;
        zoom(event.deltaY < 0 ? 1 : -1);
      }
      return;
    }
    if (!panel.hidden && panel.contains(event.target)) return;
    const delta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX;
    // En sida som är större än fönstret rullar som vanligt, och bläddrar först när den är i kanten.
    if (reader.scrollMode && !reader.atEdge(Math.sign(delta))) {
      wheelSum = 0;
      return;
    }
    event.preventDefault();
    const now = performance.now();
    if (now < wheelBlockedUntil) return;
    wheelSum += event.deltaMode === 1 ? delta * 40 : delta;
    if (Math.abs(wheelSum) >= 50) {
      const direction = Math.sign(wheelSum);
      wheelSum = 0;
      wheelBlockedUntil = now + (reader.scrollMode ? 600 : 300);
      turn(direction, { atEnd: direction < 0 });
    }
  };
  const onPointerDown = () => {
    if (isWordPopupOpen()) closeWordPopup();
    if (isMarkMenuOpen()) closeMarkMenu();
    clearTimeout(markClickTimer);
  };

  // Markeringar: färgval när text markeras med musen, meny vid klick på en markering.
  const getMarks = (section, text) => annotations.marksFor(section, text);
  const addHighlight = async (selection, color) => {
    const highlight = await annotations.add(selection, color);
    selection.clear();
    reader.refreshMarks();
    refreshMarksPanel();
    return highlight;
  };
  const writeNote = async (highlight) => {
    const note = await editNote(highlight);
    if (note === null) return;
    await annotations.update(highlight.id, { note });
    reader.refreshMarks();
    refreshMarksPanel();
  };
  const onSelect = (selection) => {
    if (isWordPopupOpen()) return;
    showSelectionMenu(selection.rect, {
      onColor: (color) => addHighlight(selection, color),
      onNote: async () => writeNote(await addHighlight(selection, lastColor())),
    });
  };
  // Ett klick på en markering väntar en kort stund, så att ett dubbelklick (ordfunktionen) inte öppnar menyn.
  let markClickTimer = null;
  const onMarkClick = (mark, rect) => {
    clearTimeout(markClickTimer);
    markClickTimer = setTimeout(() => {
      const highlight = annotations.get(mark.id);
      if (!highlight || isWordPopupOpen()) return;
      showHighlightMenu(rect, highlight, {
        onColor: async (color) => {
          await annotations.update(highlight.id, { color });
          reader.refreshMarks();
          refreshMarksPanel();
        },
        onNote: () => writeNote(highlight),
        onDelete: async () => {
          await annotations.remove(highlight.id);
          reader.refreshMarks();
          refreshMarksPanel();
          toast('Markeringen togs bort.', 2);
        },
      });
    }, 280);
  };
  stage.addEventListener('mousedown', () => clearTimeout(markClickTimer));

  async function toggleBookmark() {
    if (!currentPlace) return;
    const label = book.format === 'pdf' ? `Sida ${reader.pageName(currentPlace.pages[0])}` : currentPlaceLabel;
    const added = await annotations.toggleBookmark(currentPlace, label);
    updateBookmarkButton();
    refreshMarksPanel();
    toast(added ? 'Bokmärke på sidan.' : 'Bokmärket togs bort.', 2);
  }

  const placeName = (section) => (book.format === 'pdf' ? `s. ${reader.pageName(section)}` : reader.chapterLabel(section));
  function refreshMarksPanel() {
    if (panel.dataset.name !== 'marks') return;
    renderMarksPanel(panel, annotations, {
      onClose: () => togglePanel(null),
      onGoToBookmark: (bookmark) => reader.goToPlace(bookmark.section, bookmark.progression),
      onGoToHighlight: (highlight) => reader.showMark(highlight.section, highlight.text, highlight),
      placeName,
      onChanged: updateBookmarkButton,
    });
  }

  const reader = book.format === 'pdf'
    ? new PdfReader(stage, { onRelocate, onWord, onMessage: (message) => toast(message),
      fit: settings.pdfFit ?? 'auto', zoom: settings.pdfZoom ?? 1, spread: settings.pdfSpread ?? 'auto', flow: settings.pdfFlow ?? 'paged',
      getMarks, onSelect, onMarkClick })
    : new ReflowReader(stage, { onRelocate, onWord, onKey, onWheel, onPointerDown, getMarks, onSelect, onMarkClick });

  document.addEventListener('keydown', onKey);
  // Provkörningen i webbläsaren (dev/server.py) når läsaren härifrån. Finns inte i appen.
  if (!inTauri) globalThis.lasaTest = { reader, book };
  stage.addEventListener('wheel', onWheel, { passive: false });
  slider.addEventListener('change', () => reader.goToFraction(Number(slider.value) / 1000));
  label.addEventListener('click', () => (book.format === 'pdf' ? goToPage() : null));
  container.addEventListener('contextmenu', (event) => {
    if (!event.target.closest?.('input')) event.preventDefault();
  });

  async function goToPage() {
    if (document.querySelector('#modal-layer .modal-backdrop')) return;
    const pdf = book.format === 'pdf';
    const total = reader.placeCount ?? 0;
    const answer = await promptDialog(pdf
      ? { title: 'Gå till sida', message: 'Skriv bokens sidnummer (till exempel 45 eller xii).', confirm: 'Gå', placeholder: 'Sidnummer' }
      : { title: 'Gå till plats', message: `Skriv platsen (1 till ${total || 'slutet'}) eller hur långt in i boken, som 50 %.`,
        confirm: 'Gå', placeholder: 'Plats eller procent' });
    if (answer === null) return;
    if (!reader.goToPageText(answer)) toast(pdf ? `Hittade ingen sida ${answer}.` : `Hittade ingen plats ${answer}.`);
  }

  /** Ctrl och F: öppnar sökpanelen, eller går till sökfältet om den redan är öppen. */
  function openSearch() {
    if (panel.dataset.name === 'search') {
      const input = panel.querySelector('input');
      input?.focus();
      input?.select();
    } else {
      togglePanel('search');
    }
  }

  const searchState = newSearchState();

  /** Valet av uppslag: Automatiskt, En sida eller Två sidor. */
  function spreadChoices(current, onChoose) {
    const choices = [
      { id: 'auto', title: 'Automatiskt', note: 'Två sidor bredvid varandra när fönstret är brett nog.' },
      { id: 'one', title: 'En sida', note: 'Alltid en sida åt gången.' },
      { id: 'two', title: 'Två sidor', note: 'Alltid två sidor bredvid varandra, som en uppslagen bok.' },
    ];
    return el('div', { class: 'font-list' }, choices.map((choice) => el('button', {
      class: `font-choice${current === choice.id ? ' selected' : ''}`, dataset: { testid: `spread-${choice.id}` },
      onclick: () => onChoose(choice.id) }, el('div', {}, choice.title), el('div', { class: 'choice-note' }, choice.note))));
  }

  async function togglePanel(name) {
    if (panel.dataset.name === 'search' && name !== 'search') reader.clearSearchHit?.();
    if (!name || panel.dataset.name === name) {
      panel.hidden = true;
      panel.dataset.name = '';
      stage.focus({ preventScroll: true });
      return;
    }
    panel.dataset.name = name;
    panel.hidden = false;
    if (name === 'search') {
      renderSearchPanel(panel, reader, searchState, { onClose: () => togglePanel(null) });
    } else if (name === 'marks') {
      refreshMarksPanel();
    } else if (name === 'toc') {
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
          reader.setSettings?.({ theme: resolvedTheme() });
          togglePanel(null);
        } }, theme.title))),
      el('p', { class: 'muted' }, 'Gäller alla böcker. Mörkt vänder ljusheten på PDF-sidor men behåller färgerna. '
        + 'Följ systemet blir ljust eller mörkt som Windows.'));
    } else if (name === 'zoom') {
      const fits = [
        { id: 'auto', title: 'Automatiskt', note: 'Hela sidan om texten blir läsbar, annars en sida i läsbar storlek som du rullar i.' },
        { id: 'page', title: 'Hela sidan', note: 'Sidan, eller två sidor bredvid varandra, ryms i fönstret.' },
        { id: 'width', title: 'Sidbredd', note: 'Sidan fyller fönstrets bredd. Rulla nedåt med hjulet eller piltangenterna.' },
      ];
      const zoomLabel = el('span', { class: 'size-label', dataset: { testid: 'zoom-label' } }, `${Math.round(reader.zoom * 100)} %`);
      replace(panel, el('div', { class: 'panel-head' }, el('h2', {}, 'Visning'),
        el('button', { class: 'popup-close', onclick: () => togglePanel(null), 'aria-label': 'Stäng' }, '×')),
      el('div', { class: 'font-list' }, fits.map((fit) => el('button', {
        class: `font-choice${reader.fit === fit.id ? ' selected' : ''}`, dataset: { testid: `fit-${fit.id}` },
        onclick: async () => {
          await reader.setView({ fit: fit.id });
          await setSetting('pdfFit', fit.id);
          togglePanel(null);
          togglePanel('zoom');
        } }, el('div', {}, fit.title), el('div', { class: 'choice-note' }, fit.note)))),
      el('h3', { class: 'panel-subhead' }, 'Bläddra eller rulla'),
      el('div', { class: 'font-list' }, [
        { id: 'paged', title: 'Bläddra', note: 'En sida eller ett uppslag i taget.' },
        { id: 'scroll', title: 'Rulla', note: 'Alla sidor efter varandra, som en lång remsa. Bra för artiklar.' },
      ].map((flow) => el('button', {
        class: `font-choice${reader.flow === flow.id ? ' selected' : ''}`, dataset: { testid: `flow-${flow.id}` },
        onclick: async () => {
          await reader.setView({ flow: flow.id });
          await setSetting('pdfFlow', flow.id);
          togglePanel(null);
          togglePanel('zoom');
        } }, el('div', {}, flow.title), el('div', { class: 'choice-note' }, flow.note)))),
      el('h3', { class: 'panel-subhead' }, 'Uppslag'),
      spreadChoices(reader.spread, async (spread) => {
        await reader.setView({ spread });
        await setSetting('pdfSpread', spread);
        togglePanel(null);
        togglePanel('zoom');
      }),
      el('h3', { class: 'panel-subhead' }, 'Zoom'),
      el('div', { class: 'size-row' },
        el('button', { class: 'button', onclick: async () => { await zoom(-1); zoomLabel.textContent = `${Math.round(reader.zoom * 100)} %`; },
          'aria-label': 'Zooma ut' }, '−'),
        zoomLabel,
        el('button', { class: 'button', onclick: async () => { await zoom(1); zoomLabel.textContent = `${Math.round(reader.zoom * 100)} %`; },
          'aria-label': 'Zooma in', dataset: { testid: 'zoom-in' } }, '+')),
      el('p', { class: 'muted' }, 'Ctrl och plus eller minus, eller Ctrl och mushjulet, zoomar också. Ctrl och 0 återställer.'));
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
      el('h3', { class: 'panel-subhead' }, 'Uppslag'),
      spreadChoices(settings.reflowSpread ?? 'auto', async (spread) => {
        await setSetting('reflowSpread', spread);
        reader.setSettings({ spread });
        togglePanel(null);
        togglePanel('type');
      }),
      el('h3', { class: 'panel-subhead' }, 'Textstorlek'),
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
      setThemeListener(null);
      clearTimeout(markClickTimer);
      closeMarkMenu();
      closeWordPopup();
      await save();
      reader.destroy();
    },
  };
  // Följ systemet: när Windows byter mellan ljust och mörkt följer EPUB-sidorna med.
  setThemeListener((theme) => reader.setSettings?.({ theme }));

  /** En stor PDF (över 16 MB) läses i bitar, en mindre läses hel. Går bitarna inte att läsa provas hela filen. */
  async function openPdfBook() {
    const limit = Number.isFinite(settings.pdfRangeMin) ? settings.pdfRangeMin : 16 * 1024 * 1024;
    let length = 0;
    try {
      length = await bookFileSize(contentId(book), book.ext);
    } catch {
      length = 0;
    }
    if (length > limit) {
      try {
        await reader.open({ length, read: (start, end) => readBookRange(contentId(book), book.ext, start, end) }, book.position);
        return;
      } catch (error) {
        if (['PasswordException', 'InvalidPDFException', 'FormatError'].includes(error?.name)) throw error;
        console.warn('PDF:en kunde inte läsas i bitar, läser hela filen', error);
      }
    }
    await reader.open(await readBookFile(contentId(book), book.ext), book.position);
  }

  await markOpened(book.id);
  await annotations.load();
  try {
    // Bokfilen läses först nu, så att läsaren och Öppnar boken syns direkt. En stor PDF läses i bitar.
    if (book.format === 'pdf') await openPdfBook();
    else {
      const bytes = await readBookFile(contentId(book), book.ext);
      await reader.open(bytes, book.position, { ext: book.ext, title: book.title,
        settings: { ...settings, theme: resolvedTheme(), spread: settings.reflowSpread ?? 'auto' } });
    }
  } catch (error) {
    console.error(error);
    replace(stage, el('div', { class: 'empty', dataset: { testid: 'open-error' } },
      el('p', {}, 'Boken kunde inte öppnas.'), el('p', { class: 'muted' }, bookErrorMessage(error, book.title))));
  }
  loading.remove();
  // Boken har öppnats: platsen nu är utgångsläget, och först en flytt härifrån sparas.
  baseline = positionKey(location?.position);
  stage.focus({ preventScroll: true });
  return reader;
}
