// EPUB- och textläsaren: foliate-js delar kapitlen i sidor med CSS-kolumner. Två kolumner (ett
// uppslag) när fönstret är brett, annars en. Ord tas fram som lasa.wordAt i App/Reader/ReflowStyle.swift.

import '../vendor/foliate-js/view.js';
import { makeTextBook } from './textbook.js';
import { reflowCandidates, sentenceAround } from './wordfind.js';

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
  constructor(stage, { onRelocate, onWord, onKey, onWheel, onPointerDown }) {
    this.kind = 'reflow';
    this.stage = stage;
    this.onRelocate = onRelocate;
    this.onWord = onWord;
    this.onKey = onKey;
    this.onWheel = onWheel;
    this.onPointerDown = onPointerDown;
    this.settings = { theme: 'white', font: 'original', size: 2 };
  }

  async open(bytes, position, { ext, title, settings }) {
    this.settings = { ...this.settings, ...settings };
    this.view = document.createElement('foliate-view');
    this.stage.replaceChildren(this.view);
    this.view.addEventListener('load', (event) => this.onLoad(event.detail));
    this.view.addEventListener('relocate', (event) => this.onRelocateEvent(event.detail));
    const book = ext === 'epub'
      ? new File([bytes], 'bok.epub', { type: 'application/epub+zip' })
      : makeTextBook(bytes, { title, ext });
    await this.view.open(book);
    const renderer = this.view.renderer;
    renderer.setAttribute('flow', 'paginated');
    renderer.setAttribute('max-inline-size', '620px');
    renderer.setAttribute('max-column-count', '2');
    renderer.setAttribute('gap', '6%');
    renderer.setAttribute('margin', '40px');
    renderer.setAttribute('animated', '');
    this.applyStyles();
    await this.view.init({ lastLocation: position?.cfi ?? null });
  }

  onLoad({ doc }) {
    this.applyFontSize(doc);
    doc.addEventListener('dblclick', (event) => this.handleWord(doc, event));
    doc.addEventListener('contextmenu', (event) => this.handleWord(doc, event));
    doc.addEventListener('keydown', (event) => this.onKey?.(event));
    doc.addEventListener('wheel', (event) => this.onWheel?.(event), { passive: false });
    doc.addEventListener('mousedown', (event) => this.onPointerDown?.(event));
    // En fil som släpps över sidan ska inte öppnas i kapitlets ram.
    doc.addEventListener('dragover', (event) => event.preventDefault());
    doc.addEventListener('drop', (event) => event.preventDefault());
  }

  onRelocateEvent(detail) {
    const total = detail.location?.total ?? 0;
    const current = (detail.location?.current ?? 0) + 1;
    const parts = [];
    if (detail.tocItem?.label) parts.push(detail.tocItem.label.trim());
    if (total) parts.push(`plats ${Math.min(current, total)} av ${total}`);
    this.lastPage = detail.location?.current ?? 0;
    this.onRelocate?.({
      label: parts.join(', ') || `${Math.round((detail.fraction ?? 0) * 100)} %`,
      page: this.lastPage,
      fraction: detail.fraction ?? 0,
      position: { cfi: detail.cfi },
    });
  }

  get book() {
    return this.view?.book;
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
