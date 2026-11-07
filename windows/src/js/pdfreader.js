// PDF-läsaren: pdf.js ritar sidorna på en canvas och lägger ett osynligt textlager ovanpå, så att ord
// kan hittas och markeras. Uppslag med två sidor när fönstret är brett (omslaget ensamt till höger,
// sedan 2 och 3, 4 och 5, som i en tryckt bok och som på iPaden), annars en sida.

import { closePdf, openPdf, pdfjs } from './pdfjs.js';
import { el } from './ui.js';
import { isWordCharacter, wordInPageText } from './wordfind.js';

const PADDING = 16;
const MAX_CACHED_PAGES = 6;
// Uppslag när fönstrets yta är så här mycket bredare än hög.
const SPREAD_RATIO = 1.15;

export class PdfReader {
  constructor(stage, { onRelocate, onWord, onMessage }) {
    this.kind = 'pdf';
    this.stage = stage;
    this.onRelocate = onRelocate;
    this.onWord = onWord;
    this.onMessage = onMessage;
    this.cache = new Map(); // sidindex -> { scale, element, ready, text, offsets, strings, divs, indexOf }
    this.sizes = new Map(); // sidindex -> { width, height } vid skala 1
    this.current = [0];
    this.token = 0;
    this.spreadElement = el('div', { class: 'pdf-spread' });
    this.stage.replaceChildren(this.spreadElement);
    this.onPointer = this.onPointer.bind(this);
    this.stage.addEventListener('dblclick', this.onPointer);
    this.stage.addEventListener('contextmenu', this.onPointer);
    let timer = null;
    this.resizeObserver = new ResizeObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(() => this.show(this.current[0]), 150);
    });
  }

  async open(bytes, position) {
    this.pdf = await openPdf(bytes);
    this.count = this.pdf.numPages;
    try {
      this.labels = await this.pdf.getPageLabels();
    } catch {
      this.labels = null;
    }
    const start = Math.min(Math.max(0, Number(position?.page) || 0), this.count - 1);
    await this.show(start);
    this.resizeObserver.observe(this.stage);
  }

  get pageCount() {
    return this.count;
  }

  get spreadMode() {
    const { width, height } = this.stage.getBoundingClientRect();
    return this.count > 1 && width > height * SPREAD_RATIO;
  }

  /** Sidorna i uppslaget som innehåller sidan, i ordning från vänster. null är en tom plats. */
  slotsFor(index) {
    if (!this.spreadMode) return [index];
    if (index === 0) return [null, 0];
    const left = index % 2 === 1 ? index : index - 1;
    return [left, left + 1 < this.count ? left + 1 : null];
  }

  async size(index) {
    if (!this.sizes.has(index)) {
      const page = await this.pdf.getPage(index + 1);
      const viewport = page.getViewport({ scale: 1 });
      this.sizes.set(index, { width: viewport.width, height: viewport.height });
    }
    return this.sizes.get(index);
  }

  async scaleFor(index, slots) {
    const { width, height } = this.stage.getBoundingClientRect();
    const availableWidth = Math.max(50, (width - 2 * PADDING) / slots);
    const availableHeight = Math.max(50, height - 2 * PADDING);
    const size = await this.size(index);
    return Math.min(availableWidth / size.width, availableHeight / size.height);
  }

  /** Sidan som element, ritad i rätt skala. Återanvänds om den redan är ritad i samma skala. */
  async pageElement(index, scale) {
    const cached = this.cache.get(index);
    if (cached && Math.abs(cached.scale - scale) < 0.001) {
      await cached.ready;
      return cached;
    }
    if (cached) this.forget(index);
    const page = await this.pdf.getPage(index + 1);
    const viewport = page.getViewport({ scale });
    const ratio = window.devicePixelRatio || 1;
    const width = Math.floor(viewport.width);
    const height = Math.floor(viewport.height);
    const canvas = el('canvas', { class: 'pdf-canvas', width: Math.floor(viewport.width * ratio), height: Math.floor(viewport.height * ratio) });
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    const layer = el('div', { class: 'textLayer' });
    const element = el('div', { class: 'pdf-page', dataset: { page: index } }, el('div', { class: 'pdf-paper' }, canvas), layer);
    element.style.width = `${width}px`;
    element.style.height = `${height}px`;
    element.style.setProperty('--total-scale-factor', String(scale));
    element.style.setProperty('--scale-round-x', '1px');
    element.style.setProperty('--scale-round-y', '1px');
    const entry = { scale, element, text: '', offsets: [], strings: [], divs: [], indexOf: new Map() };
    entry.ready = (async () => {
      entry.task = page.render({
        canvasContext: canvas.getContext('2d', { alpha: false }),
        viewport,
        transform: ratio !== 1 ? [ratio, 0, 0, ratio, 0, 0] : null,
      });
      await entry.task.promise;
      const content = await page.getTextContent();
      entry.textLayer = new pdfjs.TextLayer({ textContentSource: content, container: layer, viewport });
      await entry.textLayer.render();
      // Sidans text som en sträng, med radbrytning där pdf.js säger att raden slutar. offsets[i] är var
      // textbit i börjar, i samma ordning som textlagrets element.
      const items = content.items.filter((item) => item.str !== undefined);
      entry.strings = entry.textLayer.textContentItemsStr;
      entry.divs = entry.textLayer.textDivs;
      let text = '';
      entry.strings.forEach((string, i) => {
        entry.offsets.push(text.length);
        text += string;
        if (items[i]?.hasEOL) text += '\n';
      });
      entry.text = text;
      entry.divs.forEach((div, i) => entry.indexOf.set(div, i));
    })();
    this.cache.set(index, entry);
    try {
      await entry.ready;
    } catch (error) {
      this.cache.delete(index);
      throw error;
    }
    return entry;
  }

  forget(index) {
    const entry = this.cache.get(index);
    if (!entry) return;
    entry.task?.cancel();
    entry.textLayer?.cancel();
    const canvas = entry.element.querySelector('canvas');
    if (canvas) {
      canvas.width = 0;
      canvas.height = 0;
    }
    this.cache.delete(index);
  }

  /** Visar uppslaget (eller sidan) som innehåller sidan `index`. */
  async show(index, attempt = 0) {
    if (!this.pdf) return;
    const token = ++this.token;
    index = Math.min(Math.max(0, index), this.count - 1);
    const slots = this.slotsFor(index);
    const entries = [];
    try {
      for (const page of slots) {
        entries.push(page === null ? null : await this.pageElement(page, await this.scaleFor(page, slots.length)));
      }
    } catch (error) {
      // En sida som ritades i förväg kan ha slängts medan den ritades. Då ritas den om en gång.
      if (error?.name === 'RenderingCancelledException' || error?.name === 'AbortException') {
        if (token === this.token && attempt < 2) return this.show(index, attempt + 1);
        return;
      }
      throw error;
    }
    if (token !== this.token) return;
    this.current = slots.filter((page) => page !== null);
    this.spreadElement.classList.toggle('two', slots.length === 2);
    this.spreadElement.replaceChildren(...slots.map((page, i) => (page === null
      ? el('div', { class: 'pdf-page empty', style: `width: ${entries[1 - i]?.element.style.width ?? '0px'}` })
      : entries[i].element)));
    this.onRelocate?.(this.location());
    this.trimCache();
    this.prefetch(token);
  }

  location() {
    const first = this.current[0];
    const name = (page) => this.labels?.[page] || String(page + 1);
    const differs = this.current.some((page) => name(page) !== String(page + 1));
    let label;
    if (this.current.length === 2) {
      const [a, b] = this.current;
      label = differs ? `Sidorna ${name(a)} och ${name(b)} (${a + 1} och ${b + 1} av ${this.count})`
        : `Sidorna ${a + 1} och ${b + 1} av ${this.count}`;
    } else {
      label = differs ? `Sida ${name(first)} (${first + 1} av ${this.count})` : `Sida ${first + 1} av ${this.count}`;
    }
    const last = this.current[this.current.length - 1];
    return { label, page: first, fraction: this.count > 1 ? last / (this.count - 1) : 1, position: { page: first } };
  }

  /** Ritar uppslagen före och efter i förväg, så att bläddringen går fort. */
  async prefetch(token) {
    const neighbours = [];
    const last = this.current[this.current.length - 1];
    if (last + 1 < this.count) neighbours.push(this.slotsFor(last + 1));
    if (this.current[0] > 0) neighbours.push(this.slotsFor(this.current[0] - 1));
    for (const slots of neighbours) {
      for (const page of slots) {
        if (page === null || token !== this.token) continue;
        try {
          await this.pageElement(page, await this.scaleFor(page, slots.length));
        } catch {
          // en sida som inte går att rita i förväg ritas när den visas
        }
      }
    }
    this.trimCache();
  }

  trimCache() {
    if (this.cache.size <= MAX_CACHED_PAGES) return;
    const center = this.current[0];
    const far = [...this.cache.keys()].sort((a, b) => Math.abs(b - center) - Math.abs(a - center));
    for (const page of far) {
      if (this.cache.size <= MAX_CACHED_PAGES) break;
      if (!this.current.includes(page)) this.forget(page);
    }
  }

  next() {
    const last = this.current[this.current.length - 1];
    if (last + 1 < this.count) return this.show(last + 1);
    return null;
  }

  prev() {
    if (this.current[0] > 0) return this.show(this.current[0] - 1);
    return null;
  }

  goToFraction(fraction) {
    return this.show(Math.round(fraction * (this.count - 1)));
  }

  /** Bokens egna sidnummer (sidetiketter som "xii" eller "45") först, annars sidans plats i filen. */
  goToPageText(text) {
    const wanted = String(text).trim().toLowerCase();
    if (!wanted) return false;
    const labelIndex = this.labels ? this.labels.findIndex((label) => String(label).toLowerCase() === wanted) : -1;
    if (labelIndex >= 0) {
      this.show(labelIndex);
      return true;
    }
    const number = parseInt(wanted, 10);
    if (String(number) === wanted && number >= 1 && number <= this.count) {
      this.show(number - 1);
      return true;
    }
    return false;
  }

  async toc() {
    const outline = await this.pdf.getOutline().catch(() => null);
    const convert = (items) => (items ?? []).map((item) => ({ label: item.title, target: item.dest, subitems: convert(item.items) }));
    return convert(outline);
  }

  async goToTarget(dest) {
    try {
      const explicit = typeof dest === 'string' ? await this.pdf.getDestination(dest) : dest;
      if (!Array.isArray(explicit)) return;
      const [ref] = explicit;
      const index = typeof ref === 'object' && ref !== null ? await this.pdf.getPageIndex(ref) : Number(ref);
      if (Number.isInteger(index)) await this.show(index);
    } catch (error) {
      console.warn('Kunde inte gå till innehållet', error);
    }
  }

  // Ord

  /** Tecknet under punkten i sidans text, eller -1. Provar några punkter bredvid om det behövs. */
  characterAt(entry, x, y) {
    for (const dx of [0, -2, 2, -4, 4]) {
      const range = document.caretRangeFromPoint(x + dx, y);
      const node = range?.startContainer;
      if (!node || node.nodeType !== Node.TEXT_NODE) continue;
      const i = entry.indexOf.get(node.parentElement);
      if (i === undefined) continue;
      let offset = range.startOffset;
      if (offset >= node.data.length || !isWordCharacter(node.data, offset)) offset -= 1;
      if (offset < 0 || offset >= node.data.length) continue;
      const position = entry.offsets[i] + offset;
      if (isWordCharacter(entry.text, position)) return position;
    }
    return -1;
  }

  /** Textnoden och platsen i den för ett tecken i sidans text. */
  domPoint(entry, position, end = false) {
    const target = end ? position - 1 : position;
    for (let i = 0; i < entry.strings.length; i++) {
      const start = entry.offsets[i];
      if (target >= start && target < start + entry.strings[i].length) {
        const node = entry.divs[i].firstChild;
        if (!node) return null;
        return [node, end ? target - start + 1 : target - start];
      }
    }
    return null;
  }

  rangeFor(entry, start, end) {
    const a = this.domPoint(entry, start);
    const b = this.domPoint(entry, end, true);
    if (!a || !b) return null;
    const range = document.createRange();
    range.setStart(a[0], a[1]);
    range.setEnd(b[0], b[1]);
    return range;
  }

  onPointer(event) {
    const pageElement = event.target.closest?.('.pdf-page');
    if (event.type === 'contextmenu') event.preventDefault();
    if (!pageElement) return;
    const index = Number(pageElement.dataset.page);
    const entry = this.cache.get(index);
    if (!entry) return;
    const started = performance.now();
    if (!/\p{L}/u.test(entry.text)) {
      this.onMessage?.('Den här sidan har inget textlager (en skannad sida), så ord kan inte slås upp här.');
      return;
    }
    const position = this.characterAt(entry, event.clientX, event.clientY);
    if (position < 0) return;
    const found = wordInPageText(entry.text, position);
    if (!found) return;
    event.preventDefault();
    const selection = window.getSelection();
    selection.removeAllRanges();
    const whole = this.rangeFor(entry, found.parts[0][0], found.parts[found.parts.length - 1][1]);
    if (whole) selection.addRange(whole);
    const core = found.parts.find(([a, b]) => position >= a && position < b) ?? found.parts[0];
    const anchor = this.rangeFor(entry, core[0], core[1])?.getBoundingClientRect()
      ?? new DOMRect(event.clientX, event.clientY, 1, 1);
    this.onWord?.({ candidates: found.candidates, sentence: found.sentence, rangeInSentence: found.rangeInSentence,
      page: index, anchor, started,
      clear: () => window.getSelection().removeAllRanges() });
  }

  destroy() {
    this.token += 1;
    this.resizeObserver.disconnect();
    this.stage.removeEventListener('dblclick', this.onPointer);
    this.stage.removeEventListener('contextmenu', this.onPointer);
    for (const index of [...this.cache.keys()]) this.forget(index);
    closePdf(this.pdf);
    this.pdf = null;
  }
}
