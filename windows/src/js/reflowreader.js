// EPUB- och textläsaren: foliate-js delar kapitlen i sidor med CSS-kolumner. Två kolumner (ett
// uppslag) när fönstret är brett, annars en. Ord tas fram som lasa.wordAt i App/Reader/ReflowStyle.swift.

import '../vendor/foliate-js/view.js';
import { Overlayer } from '../vendor/foliate-js/overlayer.js';
import { chapterNodes, rangeFromOffsets } from './chaptertext.js';
import { MAX_HITS, breathe, excerpt, findAll, foldQuery } from './search.js';
import { makeTextBook } from './textbook.js';
import { reflowCandidates, sentenceAround } from './wordfind.js';

const SVG = 'http://www.w3.org/2000/svg';

/** En markering i kapitlet: färgen över texten, och ett streck under om den har en anteckning. */
function drawMark(rects, { color, strong, note }) {
  const group = Overlayer.highlight(rects, { color });
  if (!note) return group;
  const wrapper = document.createElementNS(SVG, 'g');
  wrapper.append(group);
  for (const { left, bottom, width } of rects) {
    const line = document.createElementNS(SVG, 'rect');
    line.setAttribute('x', left);
    line.setAttribute('y', bottom - 1.5);
    line.setAttribute('width', width);
    line.setAttribute('height', 2);
    line.setAttribute('fill', strong);
    wrapper.append(line);
  }
  return wrapper;
}

// Typsnitt som finns i Windows. Samma nycklar som på iPaden där det går (original, georgia, palatino, system).
export const FONTS = [
  { id: 'original', title: 'Bokens eget', css: null },
  { id: 'georgia', title: 'Georgia', css: 'Georgia, serif' },
  { id: 'palatino', title: 'Palatino', css: '"Palatino Linotype", Palatino, "Book Antiqua", serif' },
  { id: 'cambria', title: 'Cambria', css: 'Cambria, Georgia, serif' },
  { id: 'system', title: 'Segoe UI', css: '"Segoe UI", system-ui, sans-serif' },
  { id: 'verdana', title: 'Verdana', css: 'Verdana, sans-serif' },
];
// Storlekarna som andel av bokens egen textstorlek, som på iPaden.
export const SIZES = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7, 2.0];

// Samma färger som ReflowStyle.swift.
const COLORS = {
  sepia: { paper: '#f4ecd8', text: '#3b2f23', link: '#8a4b1f' },
  dark: { paper: '#1c1c1c', text: '#d2d2d2', link: '#8ab4f8' },
};

const WORD = /[\p{L}\p{N}\p{M}]/u;
const JOINERS = '-‐‑\'’­';

function isWord(character) {
  return Boolean(character) && WORD.test(character);
}

function isJoiner(text, i) {
  return i > 0 && i + 1 < text.length && JOINERS.includes(text[i]) && isWord(text[i - 1]) && isWord(text[i + 1]);
}

const clean = (text) => text.replace(/­/g, '').replace(/\s+/g, ' ');

function blockOf(node, doc) {
  let element = node.parentElement;
  while (element && element !== doc.documentElement) {
    const display = doc.defaultView.getComputedStyle(element).display;
    if (display && !display.startsWith('inline') && display !== 'contents') return element;
    element = element.parentElement;
  }
  return doc.body || doc.documentElement;
}

/** Ordet under punkten i ett kapitel, som lasa.wordAt på iPaden. */
export function wordAt(doc, x, y) {
  const range = doc.caretRangeFromPoint(x, y);
  const node = range?.startContainer;
  if (!node || node.nodeType !== Node.TEXT_NODE) return null;
  const text = node.data;
  let i = range.startOffset;
  if (i >= text.length || !isWord(text[i])) i -= 1;
  if (i < 0 || i >= text.length || !isWord(text[i])) return null;
  let start = i;
  let end = i + 1;
  while (start > 0 && (isWord(text[start - 1]) || isJoiner(text, start - 1))) start -= 1;
  while (end < text.length && (isWord(text[end]) || isJoiner(text, end))) end += 1;

  const wordRange = doc.createRange();
  wordRange.setStart(node, start);
  wordRange.setEnd(node, end);
  const rects = [];
  let hit = false;
  for (const r of wordRange.getClientRects()) {
    if (r.width < 1 || r.height < 1) continue;
    rects.push(r);
    if (x >= r.left - 8 && x <= r.right + 8 && y >= r.top - 8 && y <= r.bottom + 8) hit = true;
  }
  if (!hit) return null;

  let before = '';
  let after = '';
  try {
    const block = blockOf(node, doc);
    const pre = doc.createRange();
    pre.setStart(block, 0);
    pre.setEnd(node, start);
    before = pre.toString();
    const post = doc.createRange();
    post.setStart(node, end);
    post.setEnd(block, block.childNodes.length);
    after = post.toString();
  } catch {
    // meningen blir bara ordet
  }
  return {
    word: text.slice(start, end).replace(/­/g, ''),
    before: clean(before).slice(-200),
    after: clean(after).slice(0, 200),
    rects,
    range: wordRange,
  };
}

export class ReflowReader {
  constructor(stage, { onRelocate, onWord, onKey, onWheel, onPointerDown, getMarks = null, onMarkClick = null, onSelect = null }) {
    this.kind = 'reflow';
    this.stage = stage;
    this.onRelocate = onRelocate;
    this.onWord = onWord;
    this.onKey = onKey;
    this.onWheel = onWheel;
    this.onPointerDown = onPointerDown;
    // Markeringar (se annotations.js): getMarks(kapitel, kapitlets text) ger [{ id, start, end, color, note }].
    this.getMarks = getMarks;
    this.onMarkClick = onMarkClick;
    this.onSelect = onSelect;
    this.settings = { theme: 'white', font: 'original', size: 2 };
    this.annotations = new Map(); // CFI -> { value, index, kind: 'mark' eller 'search', mark }
    this.searchHit = null;
  }

  async open(bytes, position, { ext, title, settings }) {
    this.settings = { ...this.settings, ...settings };
    this.view = document.createElement('foliate-view');
    this.stage.replaceChildren(this.view);
    this.view.addEventListener('load', (event) => this.onLoad(event.detail));
    const book = ext === 'epub'
      ? new File([bytes], 'bok.epub', { type: 'application/epub+zip' })
      : makeTextBook(bytes, { title, ext });
    await this.view.open(book);
    this.mapSections();
    this.view.addEventListener('draw-annotation', (event) => this.drawAnnotation(event.detail));
    this.view.addEventListener('create-overlay', (event) => this.paintMarks(event.detail.index));
    this.view.addEventListener('show-annotation', (event) => this.showAnnotation(event.detail));
    const renderer = this.view.renderer;
    // Lyssnar på sidornas egen händelse (den kommer efter vyns), som har andelen av kapitlet.
    renderer.addEventListener('relocate', (event) => this.onRelocateEvent(event.detail));
    renderer.setAttribute('flow', 'paginated');
    renderer.setAttribute('max-inline-size', '620px');
    renderer.setAttribute('max-column-count', '2');
    renderer.setAttribute('gap', '6%');
    renderer.setAttribute('margin', '40px');
    renderer.setAttribute('animated', '');
    this.applyStyles();
    // En position från synken har kapitel och andel men ingen CFI: då öppnas kapitlet på den andelen.
    const synced = !position?.cfi && Number.isInteger(position?.section) ? this.sectionOfDocument[position.section] : undefined;
    if (synced !== undefined) {
      await renderer.goTo({ index: synced, anchor: Math.min(Math.max(Number(position.progression) || 0, 0), 1) });
    } else {
      await this.view.init({ lastLocation: position?.cfi ?? null });
    }
  }

  /** Kapitlens nummer för synken: bara poster i läsordningen (spine) som är (X)HTML-dokument räknas,
   *  även linear="no", som på iPaden (EPUBBookReader.swift). foliate-js har alla poster som sektioner. */
  mapSections() {
    const book = this.view.book;
    this.documentOfSection = [];
    this.sectionOfDocument = [];
    const manifest = book.resources?.manifest;
    book.sections.forEach((section, index) => {
      let isDocument = true;
      if (manifest) {
        const item = manifest.find((entry) => entry.href === section.id);
        const type = String(item?.mediaType ?? '').toLowerCase();
        isDocument = Boolean(item) && (type === 'application/xhtml+xml' || type === 'text/html'
          || /\.(xhtml|html|htm)$/i.test(item.href ?? ''));
      }
      if (isDocument) {
        this.documentOfSection[index] = this.sectionOfDocument.length;
        this.sectionOfDocument.push(index);
      } else {
        this.documentOfSection[index] = null;
      }
    });
  }

  onLoad({ doc }) {
    this.applyFontSize(doc);
    doc.addEventListener('dblclick', (event) => this.handleWord(doc, event));
    doc.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      this.handleWord(doc, event);
    });
    doc.addEventListener('keydown', (event) => this.onKey?.(event));
    doc.addEventListener('wheel', (event) => this.onWheel?.(event), { passive: false });
    doc.addEventListener('mousedown', (event) => this.onPointerDown?.(event));
    // En fil som släpps över sidan ska inte öppnas i kapitlets ram.
    doc.addEventListener('dragover', (event) => event.preventDefault());
    doc.addEventListener('drop', (event) => event.preventDefault());
  }

  /** Sidornas händelse: index är sektionen i foliate-js, fraction andelen av den. Vyns sammanställning
   *  (CFI, plats i boken, innehåll) finns redan i view.lastLocation. */
  onRelocateEvent({ index, fraction: sectionFraction, reason }) {
    const detail = this.view?.lastLocation ?? {};
    const total = detail.location?.total ?? 0;
    const current = (detail.location?.current ?? 0) + 1;
    const parts = [];
    if (detail.tocItem?.label) parts.push(detail.tocItem.label.trim());
    if (total) parts.push(`plats ${Math.min(current, total)} av ${total}`);
    this.lastPage = detail.location?.current ?? 0;
    const position = { cfi: detail.cfi };
    // Synkens plats: kapitlet bland bokens dokument och andelen av kapitlet (bara EPUB).
    const section = this.view?.book?.resources ? this.documentOfSection?.[index] : null;
    if (Number.isInteger(section)) {
      position.section = section;
      position.progression = Math.round(Math.min(Math.max(Number(sectionFraction) || 0, 0), 1) * 10000) / 10000;
    }
    this.onRelocate?.({
      label: parts.join(', ') || `${Math.round((detail.fraction ?? 0) * 100)} %`,
      page: this.lastPage,
      fraction: detail.fraction ?? 0,
      position,
      // 'anchor' är när sidorna ritas om på samma ställe (typsnitt som laddas, fönstret som ändras).
      // Det är ingen flytt och ska inte ge positionen en ny ändringstid.
      moved: reason !== 'anchor',
    });
  }

  get book() {
    return this.view?.book;
  }

  // Markeringar och sökträffar, ritade av foliate-js (overlayer.js) ovanpå kapitlet.

  /** Kapitlet bland bokens dokument (som synken och iPaden räknar), för foliate-js sektion. */
  documentIndex(index) {
    return this.documentOfSection?.[index] ?? index;
  }

  drawAnnotation({ draw, annotation }) {
    if (annotation.kind === 'search') draw(Overlayer.outline, { color: 'rgba(230, 140, 0, 0.95)', width: 2.5, radius: 3 });
    else draw(drawMark, annotation.style);
  }

  loadedDoc(index) {
    return this.view?.renderer?.getContents().find((content) => content.index === index)?.doc ?? null;
  }

  /** Lägger markeringarna i ett kapitel som har laddats (eller ritar om dem efter en ändring). */
  paintMarks(index) {
    const doc = this.loadedDoc(index);
    if (!doc) return;
    const info = chapterNodes(doc);
    const fresh = new Map();
    for (const mark of this.getMarks?.(this.documentIndex(index), info.text) ?? []) {
      const range = rangeFromOffsets(doc, mark.start, mark.end, info);
      if (!range) continue;
      const value = this.view.getCFI(index, range);
      fresh.set(value, { value, index, kind: 'mark', mark, style: mark.style });
    }
    // Borttagna markeringar tas bort, de andra ritas om (samma CFI ersätter den gamla).
    for (const [value, annotation] of [...this.annotations]) {
      if (annotation.kind === 'mark' && annotation.index === index && !fresh.has(value)) {
        this.view.deleteAnnotation(annotation);
        this.annotations.delete(value);
      }
    }
    for (const [value, annotation] of fresh) {
      this.annotations.set(value, annotation);
      this.view.addAnnotation(annotation);
    }
    if (this.searchHit?.index === index) this.view.addAnnotation(this.searchHit.annotation);
  }

  refreshMarks() {
    for (const { index } of this.view?.renderer?.getContents() ?? []) this.paintMarks(index);
  }

  showAnnotation({ value, range }) {
    const annotation = this.annotations.get(value);
    if (annotation?.kind !== 'mark') return;
    const doc = range?.startContainer?.ownerDocument;
    if (doc && !doc.getSelection()?.isCollapsed) return;
    this.onMarkClick?.(annotation.mark, this.frameRect(doc, range.getBoundingClientRect()));
  }

  /** En ruta i ett kapitel i fönstrets koordinater. */
  frameRect(doc, rect) {
    const frame = doc?.defaultView?.frameElement?.getBoundingClientRect() ?? new DOMRect(0, 0, 0, 0);
    return new DOMRect(frame.left + rect.left, frame.top + rect.top, rect.width, rect.height);
  }

  // Sök

  /** Kapitlens namn ur innehållsförteckningen, för träfflistan. */
  sectionLabels() {
    if (this.labels) return this.labels;
    const labels = [];
    const book = this.view.book;
    const walk = (items) => {
      for (const item of items ?? []) {
        let index = null;
        try {
          index = book.resolveHref?.(item.href)?.index ?? null;
        } catch {
          index = null;
        }
        if (Number.isInteger(index) && labels[index] === undefined) labels[index] = (item.label ?? '').trim();
        walk(item.subitems);
      }
    };
    walk(book.toc);
    let last = '';
    this.labels = book.sections.map((_, index) => {
      if (labels[index]) last = labels[index];
      return last;
    });
    return this.labels;
  }

  /** Söker kapitel för kapitel. onResult får varje träff, onProgress andelen av boken. */
  async search(query, { onResult, onProgress, isCurrent }) {
    const needle = foldQuery(query);
    const sections = this.view?.book?.sections ?? [];
    if (!needle) return 0;
    const labels = this.sectionLabels();
    let total = 0;
    for (const [index, section] of sections.entries()) {
      if (!isCurrent() || !this.view || total >= MAX_HITS) return total;
      if (!section.createDocument || this.documentOfSection?.[index] === null) continue;
      let doc;
      try {
        doc = await section.createDocument();
      } catch {
        continue;
      }
      if (!isCurrent() || !this.view) return total;
      const info = chapterNodes(doc);
      for (const [start, end] of findAll(info.text, needle, MAX_HITS - total)) {
        const range = rangeFromOffsets(doc, start, end, info);
        if (!range) continue;
        total += 1;
        onResult({ section: index, start, end, cfi: this.view.getCFI(index, range), excerpt: excerpt(info.text, start, end),
          label: labels[index] || `Kapitel ${this.documentIndex(index) + 1}` });
      }
      onProgress?.((index + 1) / sections.length);
      await breathe();
    }
    return total;
  }

  async showHit(hit) {
    this.clearSearchHit();
    const annotation = { value: hit.cfi, index: hit.section, kind: 'search' };
    this.searchHit = { ...hit, index: hit.section, annotation };
    await this.view.goTo(hit.cfi);
    await this.view.addAnnotation(annotation);
  }

  clearSearchHit() {
    if (!this.searchHit) return;
    this.view?.deleteAnnotation(this.searchHit.annotation);
    this.searchHit = null;
  }

  next() {
    return this.view?.next();
  }

  prev() {
    return this.view?.prev();
  }

  goToFraction(fraction) {
    return this.view?.goToFraction(Math.min(Math.max(fraction, 0), 0.9999));
  }

  /** Antalet platser i boken (en plats är ungefär 1 500 tecken). */
  get placeCount() {
    return this.view?.lastLocation?.location?.total ?? 0;
  }

  /** Gå till sida i en EPUB: en plats (1 till antalet) eller hur långt in i boken ("50 %"). */
  goToPageText(text) {
    const value = String(text).trim().replace(',', '.');
    let fraction = null;
    if (value.endsWith('%')) {
      const percent = parseFloat(value);
      if (percent >= 0 && percent <= 100) fraction = percent / 100;
    } else {
      const number = parseInt(value, 10);
      const total = this.placeCount;
      if (String(number) === value && total && number >= 1 && number <= total) fraction = (number - 1) / total;
    }
    if (fraction === null) return false;
    this.goToFraction(fraction);
    return true;
  }

  async toc() {
    const convert = (items) => (items ?? []).map((item) => ({ label: (item.label ?? '').trim(), target: item.href, subitems: convert(item.subitems) }));
    return convert(this.view?.book?.toc);
  }

  goToTarget(href) {
    return this.view?.goTo(href);
  }

  setSettings(settings) {
    this.settings = { ...this.settings, ...settings };
    this.applyStyles();
    for (const { doc } of this.view?.renderer?.getContents() ?? []) this.applyFontSize(doc);
  }

  applyStyles() {
    const { theme, font } = this.settings;
    let css = '';
    if (theme === 'white') {
      css += 'html { background-color: #ffffff !important; }\n';
    } else {
      const { paper, text, link } = COLORS[theme] ?? COLORS.sepia;
      css += `html { background-color: ${paper} !important; color: ${text} !important; }
body, body *:not(a) { color: inherit !important; background-color: transparent !important; }
a, a * { color: ${link} !important; background-color: transparent !important; }\n`;
      if (theme === 'dark') css += 'img, svg, video { opacity: 0.88; }\n';
    }
    const family = FONTS.find((f) => f.id === font)?.css;
    if (family) css += `body, body *:not(pre):not(code):not(kbd):not(samp):not(tt) { font-family: ${family} !important; }\n`;
    this.view?.renderer?.setStyles(css);
  }

  /** Bokens egen grundstorlek mäts en gång per kapitel, så att varje ny storlek räknas från den. */
  applyFontSize(doc) {
    const root = doc.documentElement;
    if (!root.dataset.lasaBase) {
      root.dataset.lasaBase = String(parseFloat(doc.defaultView.getComputedStyle(root).fontSize) || 16);
    }
    const scale = SIZES[Math.min(Math.max(this.settings.size, 0), SIZES.length - 1)];
    root.style.setProperty('font-size', `${(parseFloat(root.dataset.lasaBase) * scale).toFixed(2)}px`, 'important');
  }

  handleWord(doc, event) {
    if (event.type === 'contextmenu') event.preventDefault();
    const started = performance.now();
    const found = wordAt(doc, event.clientX, event.clientY);
    if (!found) return;
    event.preventDefault();
    const selection = doc.getSelection();
    selection.removeAllRanges();
    selection.addRange(found.range);
    const frame = doc.defaultView.frameElement?.getBoundingClientRect() ?? new DOMRect(0, 0, 0, 0);
    const r = found.rects.find((rect) => event.clientX >= rect.left - 8 && event.clientX <= rect.right + 8) ?? found.rects[0];
    const anchor = new DOMRect(frame.left + r.left, frame.top + r.top, r.width, r.height);
    const [sentence, rangeInSentence] = sentenceAround(found.before, found.word, found.after);
    this.onWord?.({ candidates: reflowCandidates(found.word), sentence, rangeInSentence, page: this.lastPage ?? 0, anchor, started,
      clear: () => doc.getSelection()?.removeAllRanges() });
  }

  destroy() {
    this.view?.close();
    this.view?.remove();
    this.view = null;
  }
}
