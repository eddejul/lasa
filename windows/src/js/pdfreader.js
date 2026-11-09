// PDF-läsaren: pdf.js ritar sidorna på en canvas och lägger ett osynligt textlager ovanpå, så att ord
// kan hittas och markeras. Uppslag med två sidor när fönstret är brett (omslaget ensamt till höger,
// sedan 2 och 3, 4 och 5, som i en tryckt bok och som på iPaden), annars en sida. Bläddra visar en sida
// eller ett uppslag i taget, Rulla (W10) alla sidor efter varandra i en lång remsa.
//
// Visning: Hela sidan (sidan eller uppslaget ryms i fönstret) eller Sidbredd (en sida så bred som
// fönstret, och man rullar nedåt). Automatiskt väljer Sidbredd när en hel sida skulle bli för liten
// för att läsa, som på en bärbar dator med 150 procents skalning. Zoom gör sidan större än så.

import { closePdf, openPdf, openPdfRange, pdfjs } from './pdfjs.js';
import { MAX_HITS, breathe, excerpt, findAll, foldQuery } from './search.js';
import { el } from './ui.js';
import { isWordCharacter, wordInPageText } from './wordfind.js';
import { pagesSource } from './questions.js';

const PADDING = 16;
const SCROLLBAR = 18;
// Ritade sidor som hålls i minnet: sidan (eller uppslaget) som syns och de närmaste före och efter.
// En sida åt gången: högst 4. Uppslag: högst 6 (tre uppslag).
const MAX_CACHED_PAGES = 4;
const MAX_CACHED_PAGES_SPREAD = 6;
// Rulla (W10): sidorna som syns och några runt dem. En sida per rad: högst 6. Två sidor per rad: högst 10.
const SCROLL_CACHED_PAGES = 6;
const SCROLL_CACHED_PAGES_TWO = 10;
// Uppslag när fönstrets yta är så här mycket bredare än hög.
const SPREAD_RATIO = 1.15;
// Under den här skalan (1 = PDF:ens egen storlek) blir en hel sida svår att läsa, och Automatiskt
// väljer Sidbredd.
const READABLE_SCALE = 0.8;
// Automatiskt i ett lågt fönster: sidan så bred som fönstret, men inte större än så här, så att en
// A4-sida inte blir dubbelt så stor som på papper i ett brett fönster.
const AUTO_MAX_SCALE = 1.3;
export const ZOOM_STEPS = [1, 1.25, 1.5, 1.75, 2, 2.5];
// Största canvas i bildpunkter (8 miljoner, cirka 32 MB). Större sidor, som vid hög zoom, ritas med
// lägre upplösning, så att minnet räcker på en dator med 8 GB.
const MAX_CANVAS_PIXELS = 8e6;

export class PdfReader {
  constructor(stage, { onRelocate, onWord, onMessage, fit = 'auto', zoom = 1, spread = 'auto', flow = 'paged', getMarks = null,
    onSelect = null, onMarkClick = null, getDots = null, onDotClick = null }) {
    this.kind = 'pdf';
    // Frågorna i marginalen (K6, questions.js): getDots(sida) ger [{ id, offset, y, number, status }].
    this.getDots = getDots;
    this.onDotClick = onDotClick;
    // Bläddra ('paged', en sida eller ett uppslag i taget) eller Rulla ('scroll', alla sidor efter varandra).
    this.flow = flow === 'scroll' ? 'scroll' : 'paged';
    this.inflight = new Map();
    this.near = new Set();
    this.onScroll = this.onScroll.bind(this);
    this.spread = ['auto', 'one', 'two'].includes(spread) ? spread : 'auto';
    this.stage = stage;
    this.onRelocate = onRelocate;
    this.onWord = onWord;
    this.onMessage = onMessage;
    // Markeringarna på en sida: [{ id, start, end, color, note }] i sidans text (se annotations.js).
    this.getMarks = getMarks;
    this.onSelect = onSelect; // text markerad med musen: { section, start, end, sectionText, rect, clear }
    this.onMarkClick = onMarkClick; // klick på en markering: (mark, rect)
    this.searchHit = null; // { section, start, end } när en sökträff visas
    this.texts = new Map(); // sidindex -> sidans text, för sökningen
    this.fit = fit; // 'auto', 'page' eller 'width'
    this.zoom = ZOOM_STEPS.includes(zoom) ? zoom : 1;
    this.effectiveFit = 'page';
    this.cache = new Map(); // sidindex -> { scale, element, ready, text, offsets, strings, divs, indexOf }
    this.sizes = new Map(); // sidindex -> { width, height } vid skala 1
    this.current = [0];
    this.token = 0;
    this.spreadElement = el('div', { class: 'pdf-spread' });
    this.stage.replaceChildren(this.spreadElement);
    this.onPointer = this.onPointer.bind(this);
    this.stage.addEventListener('dblclick', this.onPointer);
    this.stage.addEventListener('contextmenu', this.onPointer);
    this.onMouseUp = this.onMouseUp.bind(this);
    this.stage.addEventListener('mouseup', this.onMouseUp);
    let timer = null;
    // Fönstret ändrar storlek: rita om sidan som visas, eller den som är på väg att visas. Det första
    // anropet (när observationen börjar) och anrop utan ändrad storlek hoppas över, annars kunde en
    // bläddring direkt efter att boken öppnats skrivas över av en omritning av den förra sidan.
    this.resizeObserver = new ResizeObserver(() => {
      const { width, height } = this.stage.getBoundingClientRect();
      const size = `${Math.round(width)}x${Math.round(height)}`;
      if (size === this.observedSize) return;
      const first = this.observedSize === undefined;
      this.observedSize = size;
      if (first) return;
      clearTimeout(timer);
      timer = setTimeout(() => this.show(this.target ?? this.current[0], { keepScroll: true }), 150);
    });
  }

  /** source: bokens byte, eller { length, read(start, end) } för att läsa en stor PDF i bitar. */
  async open(source, position) {
    this.pdf = source instanceof Uint8Array ? await openPdf(source) : await openPdfRange(source.length, source.read);
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

  /** Om sidan rullas (Sidbredd, läsbar storlek eller inzoomat) i stället för att rymmas i fönstret. */
  get scrollMode() {
    return this.flow === 'scroll' || this.effectiveFit !== 'page' || this.zoom > 1;
  }

  /** Uppslag (två sidor bredvid varandra). spread: 'auto' (när fönstret är brett och sidan ryms),
   *  'one' (aldrig) eller 'two' (alltid, utom när man zoomar in). */
  get spreadMode() {
    if (this.count < 2 || this.spread === 'one') return false;
    if (this.flow === 'scroll') return this.rowSize() === 2;
    if (this.spread === 'two') return this.zoom === 1;
    const { width, height } = this.stage.getBoundingClientRect();
    return !this.scrollMode && width > height * SPREAD_RATIO;
  }

  /** Hela sidan eller Sidbredd. Automatiskt: hela sidan om den blir läsbar, annars 'readable', en
   *  sida i läsbar storlek (sidbredd, men högst AUTO_MAX_SCALE) som man rullar i. */
  async resolveFit(index) {
    if (this.fit !== 'auto') return this.fit;
    // Två sidor valt: uppslaget ryms i fönstret, även om sidorna blir små.
    if (this.spread === 'two' && this.zoom === 1 && this.count > 1) return 'page';
    const { width, height } = this.stage.getBoundingClientRect();
    const size = await this.size(index);
    const whole = Math.min((width - 2 * PADDING) / size.width, (height - 2 * PADDING) / size.height);
    return whole >= READABLE_SCALE ? 'page' : 'readable';
  }

  /** Sidorna i uppslaget som innehåller sidan, i ordning från vänster. null är en tom plats. */
  slotsFor(index) {
    if (!this.spreadMode) return [index];
    if (index === 0) return [null, 0];
    const left = index % 2 === 1 ? index : index - 1;
    return [left, left + 1 < this.count ? left + 1 : null];
  }

  async setView({ fit = this.fit, zoom = this.zoom, spread = this.spread, flow = this.flow }) {
    const index = this.current[0] ?? 0;
    const offset = this.rowElements ? this.rowOffset() : 0;
    this.fit = fit;
    this.spread = ['auto', 'one', 'two'].includes(spread) ? spread : 'auto';
    this.zoom = ZOOM_STEPS.includes(zoom) ? zoom : 1;
    this.flow = flow === 'scroll' ? 'scroll' : 'paged';
    if (this.flow === 'scroll') {
      await this.layoutScroll(index, { offset });
      return;
    }
    if (this.rowElements) {
      this.teardownScroll();
      this.spreadElement.replaceChildren();
    }
    await this.show(index, { keepScroll: !offset });
  }

  zoomStep(direction) {
    const index = ZOOM_STEPS.indexOf(this.zoom);
    const next = ZOOM_STEPS[Math.min(Math.max(index + direction, 0), ZOOM_STEPS.length - 1)];
    return this.setView({ zoom: next });
  }

  /** Rullar en skärm uppåt eller nedåt. Ger false när sidan redan är i kanten (då bläddrar läsaren). */
  scrollStep(direction) {
    if (!this.scrollMode) return false;
    const view = this.spreadElement;
    if (this.atEdge(direction)) return false;
    view.scrollBy({ top: direction * view.clientHeight * 0.85 });
    return true;
  }

  atEdge(direction) {
    const view = this.spreadElement;
    const max = view.scrollHeight - view.clientHeight;
    return direction > 0 ? view.scrollTop >= max - 2 : view.scrollTop <= 2;
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
    const availableWidth = Math.max(50, (width - 2 * PADDING - (this.scrollMode ? SCROLLBAR : 0)) / slots);
    const availableHeight = Math.max(50, height - 2 * PADDING);
    const size = await this.size(index);
    let fitted;
    if (this.effectiveFit === 'width') fitted = availableWidth / size.width;
    else if (this.effectiveFit === 'readable') fitted = Math.min(availableWidth / size.width, AUTO_MAX_SCALE);
    else fitted = Math.min(availableWidth / size.width, availableHeight / size.height);
    return fitted * this.zoom;
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
    const width = Math.floor(viewport.width);
    const height = Math.floor(viewport.height);
    let ratio = window.devicePixelRatio || 1;
    if (width * height * ratio * ratio > MAX_CANVAS_PIXELS) ratio = Math.sqrt(MAX_CANVAS_PIXELS / (width * height));
    const canvas = el('canvas', { class: 'pdf-canvas', width: Math.floor(viewport.width * ratio), height: Math.floor(viewport.height * ratio) });
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    const layer = el('div', { class: 'textLayer' });
    const marks = el('div', { class: 'pdf-marks' });
    const element = el('div', { class: 'pdf-page', dataset: { page: index } }, el('div', { class: 'pdf-paper' }, canvas), marks, layer);
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
      this.texts.set(index, text);
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
    if (this.flow === 'scroll') entry.element.remove();
    this.cache.delete(index);
  }

  /** Visar uppslaget (eller sidan) som innehåller sidan `index`. atEnd: visa sidans nederkant (när man
   *  rullar bakåt in på sidan). keepScroll: behåll var på sidan man är (när fönstret eller zoomen ändras). */
  async show(index, { atEnd = false, keepScroll = false } = {}, attempt = 0) {
    if (!this.pdf) return;
    if (this.flow === 'scroll') {
      index = Math.min(Math.max(0, index), this.count - 1);
      // Ny storlek på fönstret (keepScroll) eller ingen remsa än: bygg remsan, annars rulla dit.
      if (!this.rowElements || keepScroll) return this.layoutScroll(index, { offset: keepScroll ? this.rowOffset() : 0, atEnd });
      return this.showScroll(index, { atEnd });
    }
    const token = ++this.token;
    index = Math.min(Math.max(0, index), this.count - 1);
    this.target = index;
    const view = this.spreadElement;
    const scrolled = keepScroll && view.scrollHeight > 0 ? view.scrollTop / view.scrollHeight : 0;
    const entries = [];
    let slots;
    try {
      this.effectiveFit = await this.resolveFit(index);
      slots = this.slotsFor(index);
      for (const page of slots) {
        entries.push(page === null ? null : await this.pageElement(page, await this.scaleFor(page, slots.length)));
      }
    } catch (error) {
      // En sida som ritades i förväg kan ha slängts medan den ritades. Då ritas den om en gång.
      if (error?.name === 'RenderingCancelledException' || error?.name === 'AbortException') {
        if (token === this.token && attempt < 2) return this.show(index, { atEnd, keepScroll }, attempt + 1);
        return;
      }
      throw error;
    }
    if (token !== this.token) return;
    this.current = slots.filter((page) => page !== null);
    view.classList.toggle('two', slots.length === 2);
    view.classList.toggle('scroll', this.scrollMode);
    view.replaceChildren(...slots.map((page, i) => (page === null
      ? el('div', { class: 'pdf-page empty', style: `width: ${entries[1 - i]?.element.style.width ?? '0px'}` })
      : entries[i].element)));
    if (this.scrollMode) {
      view.scrollTop = keepScroll ? scrolled * view.scrollHeight : (atEnd ? view.scrollHeight : 0);
    } else {
      view.scrollTop = 0;
    }
    this.refreshMarks();
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
    return { label, page: first, fraction: this.count > 1 ? last / (this.count - 1) : 1, position: { page: first },
      place: { pages: [...this.current] } };
  }

  // Rulla (W10): alla sidor efter varandra i en lång remsa, en eller två sidor per rad (uppslaget som i Bläddra,
  // omslaget ensamt till höger). Varje sida har en plats med sin storlek (uppskattad från första sidan tills
  // sidan mätts), och bara sidorna som syns och några runt dem ritas (högst SCROLL_CACHED_PAGES). Övriga
  // platser är tomma papper. Webbläsarens scroll anchoring håller kvar det man läser när en plats ändrar höjd.

  /** Sidor per rad i Rulla. */
  rowSize() {
    if (this.count < 2 || this.spread === 'one' || this.zoom !== 1) return 1;
    if (this.spread === 'two') return 2;
    if (this.fit === 'width') return 1;
    const { width, height } = this.stage.getBoundingClientRect();
    const size = this.sizes.get(0) ?? { width: 595, height: 842 };
    const half = (width - 2 * PADDING - SCROLLBAR) / 2;
    return width > height * SPREAD_RATIO && half / size.width >= READABLE_SCALE ? 2 : 1;
  }

  /** Skalan för en sida i Rulla (samma räkning som scaleFor, men utan att vänta på sidan). */
  scrollScale(size, perRow) {
    const { width, height } = this.stage.getBoundingClientRect();
    const availableWidth = Math.max(50, (width - 2 * PADDING - SCROLLBAR) / perRow);
    const availableHeight = Math.max(50, height - 2 * PADDING);
    let fitted;
    if (this.fit === 'page') fitted = Math.min(availableWidth / size.width, availableHeight / size.height);
    else if (this.fit === 'width') fitted = availableWidth / size.width;
    else fitted = Math.min(availableWidth / size.width, AUTO_MAX_SCALE);
    return fitted * this.zoom;
  }

  scrollLimit() {
    return this.perRow === 2 ? SCROLL_CACHED_PAGES_TWO : SCROLL_CACHED_PAGES;
  }

  rowOf(page) {
    return this.perRow === 2 ? (page === 0 ? 0 : Math.floor((page + 1) / 2)) : page;
  }

  /** Var i raden som syns man är (0 överst, 1 nederst), för att hamna rätt när remsan byggs om. */
  rowOffset() {
    const row = this.rowElements?.[this.rowOf(this.current[0] ?? 0)];
    if (!row || !row.offsetHeight) return 0;
    return Math.min(Math.max((this.spreadElement.scrollTop - row.offsetTop + PADDING) / row.offsetHeight, 0), 1);
  }

  sizeSlot(slot, page) {
    const size = this.sizes.get(page) ?? this.sizes.get(0) ?? { width: 595, height: 842 };
    const scale = this.scrollScale(size, this.perRow);
    slot.style.width = `${Math.floor(size.width * scale)}px`;
    slot.style.height = `${Math.floor(size.height * scale)}px`;
  }

  /** Bygger remsan och går till sidan `index` (offset: var i raden, se rowOffset). */
  async layoutScroll(index, { offset = 0, atEnd = false } = {}) {
    const token = ++this.token;
    await this.size(0);
    if (token !== this.token || !this.pdf) return;
    this.effectiveFit = this.fit === 'auto' ? 'readable' : this.fit;
    this.teardownScroll();
    this.perRow = this.rowSize();
    const view = this.spreadElement;
    view.classList.remove('two');
    view.classList.add('scroll', 'continuous');
    this.slots = new Array(this.count).fill(null);
    this.rowPages = [];
    if (this.perRow === 2) {
      this.rowPages.push([null, 0]);
      for (let page = 1; page < this.count; page += 2) this.rowPages.push([page, page + 1 < this.count ? page + 1 : null]);
    } else {
      for (let page = 0; page < this.count; page++) this.rowPages.push([page]);
    }
    this.rowElements = this.rowPages.map((pages, row) => el('div', { class: `pdf-row${this.perRow === 2 ? ' two' : ''}`,
      dataset: { row } }, pages.map((page, i) => {
      if (page === null) {
        const blank = el('div', { class: 'pdf-slot empty' });
        this.sizeSlot(blank, pages[1 - i] ?? 0);
        return blank;
      }
      const slot = el('div', { class: 'pdf-slot', dataset: { slot: page } });
      this.sizeSlot(slot, page);
      this.slots[page] = slot;
      return slot;
    })));
    view.replaceChildren(...this.rowElements);
    this.near = new Set();
    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const page = Number(entry.target.dataset.slot);
        if (entry.isIntersecting) this.near.add(page);
        else this.near.delete(page);
      }
      this.scheduleRender();
    }, { root: view, rootMargin: '100% 0px' });
    for (const slot of this.slots) if (slot) this.observer.observe(slot);
    view.addEventListener('scroll', this.onScroll, { passive: true });
    await this.showScroll(index, { offset, atEnd });
  }

  /** Tar bort remsan (när man går över till Bläddra eller bygger om den). */
  teardownScroll() {
    this.observer?.disconnect();
    this.observer = null;
    this.spreadElement.removeEventListener('scroll', this.onScroll);
    this.inflight = new Map();
    for (const index of [...this.cache.keys()]) this.forget(index);
    this.rowElements = null;
    this.slots = null;
    this.near = new Set();
    this.spreadElement.classList.remove('continuous');
  }

  /** Rullar till sidan i remsan och ritar den (och sidan bredvid) direkt. */
  async showScroll(index, { offset = 0, atEnd = false } = {}) {
    const view = this.spreadElement;
    const row = this.rowElements[this.rowOf(index)];
    if (atEnd) view.scrollTop = row.offsetTop + row.offsetHeight - view.clientHeight;
    else view.scrollTop = row.offsetTop - PADDING + offset * row.offsetHeight;
    this.updateCurrent(true);
    const token = this.token;
    for (const page of this.current) {
      try {
        await this.renderSlot(page, token);
      } catch (error) {
        if (!['RenderingCancelledException', 'AbortException'].includes(error?.name)) throw error;
      }
    }
  }

  /** Raden högst upp i fönstret (en fjärdedel ned) är sidan man läser. */
  updateCurrent(force = false) {
    const view = this.spreadElement;
    const rows = this.rowElements;
    if (!rows?.length) return;
    const probe = view.scrollTop + Math.min(view.clientHeight * 0.25, 160);
    let low = 0;
    let high = rows.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (rows[middle].offsetTop <= probe) low = middle;
      else high = middle - 1;
    }
    const pages = this.rowPages[low].filter((page) => page !== null);
    const key = pages.join(',');
    if (!force && key === this.currentKey) return;
    this.currentKey = key;
    this.current = pages;
    this.target = undefined;
    this.onRelocate?.(this.location());
  }

  onScroll() {
    if (this.scrollFrame) return;
    this.scrollFrame = requestAnimationFrame(() => {
      this.scrollFrame = 0;
      this.updateCurrent();
    });
  }

  /** Ritar en sida i sin plats. Samma sida ritas aldrig två gånger samtidigt. */
  renderSlot(page, token) {
    const inflight = this.inflight;
    if (inflight.has(page)) return inflight.get(page);
    const job = (async () => {
      const slot = this.slots?.[page];
      if (!slot) return;
      const size = await this.size(page);
      if (token !== this.token || this.slots?.[page] !== slot) return;
      const entry = await this.pageElement(page, this.scrollScale(size, this.perRow));
      if (token !== this.token || this.slots?.[page] !== slot) return;
      if (entry.element.parentElement !== slot) {
        slot.style.width = entry.element.style.width;
        slot.style.height = entry.element.style.height;
        slot.replaceChildren(entry.element);
      }
      this.paintMarks(page);
    })().finally(() => {
      if (inflight.get(page) === job) inflight.delete(page);
    });
    inflight.set(page, job);
    return job;
  }

  /** Ritar sidorna nära fönstret, närmast sidan man läser först, och släpper de andra. */
  scheduleRender() {
    if (this.rendering) {
      this.renderAgain = true;
      return;
    }
    this.rendering = true;
    (async () => {
      try {
        do {
          this.renderAgain = false;
          const token = this.token;
          const wanted = this.wantedPages();
          for (const page of wanted) {
            if (token !== this.token || this.renderAgain) break;
            if (this.cache.get(page)?.element.parentElement === this.slots?.[page]) continue;
            try {
              await this.renderSlot(page, token);
            } catch (error) {
              if (!['RenderingCancelledException', 'AbortException'].includes(error?.name)) console.warn(error);
            }
          }
          if (token === this.token) this.trimScroll();
        } while (this.renderAgain);
      } finally {
        this.rendering = false;
      }
    })();
  }

  wantedPages() {
    const center = this.current[0] ?? 0;
    return [...this.near].sort((a, b) => Math.abs(a - center) - Math.abs(b - center)).slice(0, this.scrollLimit());
  }

  trimScroll() {
    const keep = new Set([...this.wantedPages(), ...this.current]);
    for (const page of [...this.cache.keys()]) {
      if (!keep.has(page) && !this.inflight.has(page)) this.forget(page);
    }
  }

  // Markeringar och sökträffar

  /** Ritar om markeringarna och sökträffen på sidorna som syns. */
  refreshMarks() {
    for (const page of this.flow === 'scroll' ? [...this.cache.keys()] : this.current) this.paintMarks(page);
  }

  /** Rutor för ett teckenintervall på en sida, i sidans koordinater. Sidan måste synas. */
  rectsFor(entry, start, end) {
    const range = this.rangeFor(entry, start, end);
    if (!range) return [];
    const origin = entry.element.getBoundingClientRect();
    return [...range.getClientRects()].filter((r) => r.width > 0.5 && r.height > 0.5)
      .map((r) => ({ left: r.left - origin.left, top: r.top - origin.top, width: r.width, height: r.height }));
  }

  paintMarks(index) {
    const entry = this.cache.get(index);
    const layer = entry?.element.querySelector('.pdf-marks');
    if (!layer || !entry.element.isConnected) return;
    this.paintDots(index, entry);
    if (!entry.text) return;
    const boxes = [];
    entry.markRects = [];
    for (const mark of this.getMarks?.(index, entry.text) ?? []) {
      const rects = this.rectsFor(entry, mark.start, mark.end);
      entry.markRects.push({ mark, rects });
      for (const r of rects) {
        boxes.push(el('div', { class: `pdf-mark color-${mark.color}${mark.note ? ' has-note' : ''}`, dataset: { id: mark.id },
          style: `left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px` }));
      }
    }
    if (this.searchHit?.section === index) {
      for (const r of this.rectsFor(entry, this.searchHit.start, this.searchHit.end)) {
        boxes.push(el('div', { class: 'pdf-search-hit', dataset: { testid: 'search-hit' },
          style: `left:${r.left - 2}px;top:${r.top - 2}px;width:${r.width + 4}px;height:${r.height + 4}px` }));
      }
    }
    layer.replaceChildren(...boxes);
  }

  /** Frågornas numrerade prickar i sidans högra marginal, vid raden där platsen står (K6). */
  paintDots(index, entry) {
    let layer = entry.element.querySelector('.pdf-dots');
    const dots = this.getDots?.(index) ?? [];
    if (!layer && !dots.length) return;
    if (!layer) {
      layer = el('div', { class: 'pdf-dots' });
      entry.element.append(layer);
    }
    const height = parseFloat(entry.element.style.height) || entry.element.offsetHeight;
    const buttons = [];
    for (const dot of dots) {
      let middle = null;
      if (Number.isInteger(dot.offset) && entry.text) {
        const rects = this.rectsFor(entry, Math.max(0, dot.offset - 1), Math.min(dot.offset, entry.text.length));
        const last = rects[rects.length - 1];
        if (last) middle = last.top + last.height / 2;
      } else if (typeof dot.y === 'number') {
        middle = dot.y * height;
      }
      if (middle === null) continue;
      buttons.push(el('button', { class: `question-dot${dot.status ? ` status-${dot.status}` : ''}`, title: `Fråga ${dot.number}`,
        style: `top:${Math.max(0, middle - 10)}px`, dataset: { id: dot.id, testid: 'question-dot' },
        onmousedown: (event) => event.stopPropagation(),
        onclick: (event) => {
          event.stopPropagation();
          this.onDotClick?.(dot);
        } }, String(dot.number)));
    }
    layer.replaceChildren(...buttons);
  }

  // Frågorna (K6b): kapitlen, texten och platserna, som questions.js använder.

  get sectionCount() {
    return this.count;
  }

  /** Sidans text, samma som markeringarna räknar i. */
  sectionText(index) {
    return this.pageText(index);
  }

  /** Kapitlen för frågorna: innehållets översta nivå (bokmärkena), annars tio sidor i taget.
   *  [{ key, order, title, pages: [första, sista] }], sidorna från 0. */
  async questionChapters() {
    const starts = [];
    try {
      const outline = await this.pdf.getOutline();
      for (const item of outline ?? []) {
        let dest = item.dest;
        if (typeof dest === 'string') dest = await this.pdf.getDestination(dest);
        if (!Array.isArray(dest)) continue;
        const [ref] = dest;
        const page = typeof ref === 'object' && ref !== null ? await this.pdf.getPageIndex(ref) : Number(ref);
        if (Number.isInteger(page) && page >= 0 && page < this.count) starts.push({ page, title: String(item.title ?? '').trim() });
      }
    } catch (error) {
      console.warn('Innehållet kunde inte läsas för frågorna', error);
    }
    starts.sort((a, b) => a.page - b.page);
    const unique = starts.filter((start, i) => i === 0 || start.page !== starts[i - 1].page);
    const ranges = [];
    if (unique.length) {
      if (unique[0].page > 0) ranges.push({ title: 'Början', first: 0 });
      for (const start of unique) ranges.push({ title: start.title || `Sida ${this.pageName(start.page)}`, first: start.page });
    } else {
      for (let first = 0; first < this.count; first += 10) {
        const last = Math.min(first + 9, this.count - 1);
        ranges.push({ title: `Sidorna ${this.pageName(first)} till ${this.pageName(last)}`, first });
      }
    }
    // Har boken text alls? Några sidor jämnt fördelade i boken (en fotad PDF utan text får inga frågor).
    let letters = 0;
    const samples = new Set();
    for (let i = 0; i < Math.min(12, this.count); i++) samples.add(Math.floor((i * this.count) / Math.min(12, this.count)));
    for (const page of samples) {
      letters += (await this.pageText(page)).replace(/\s+/g, '').length;
      if (letters > 200) break;
    }
    this.noTextFlag = letters < 50;
    return ranges.map((range, order) => {
      const last = order + 1 < ranges.length ? ranges[order + 1].first - 1 : this.count - 1;
      return { key: `p${range.first + 1}-${last + 1}`, order, title: range.title, pages: [range.first, last] };
    });
  }

  hasNoText() {
    return this.noTextFlag === true;
  }

  /** Kapitlets text: sidornas text i ordning med en tom rad emellan, och vägen tillbaka till sidorna. */
  async questionText(chapter) {
    const pages = [];
    for (let page = chapter.pages[0]; page <= chapter.pages[1]; page++) {
      pages.push({ page, text: await this.pageText(page) });
      if (page % 8 === 7) await breathe();
    }
    return pagesSource(pages);
  }

  chapterForPlace(place, chapters) {
    const page = place?.pages?.[0];
    if (!Number.isInteger(page)) return null;
    return chapters.find((chapter) => page >= chapter.pages[0] && page <= chapter.pages[1]) ?? null;
  }

  /** Kapitlets första sida syns. */
  isChapterStart(place, chapter) {
    return Boolean(place?.pages?.includes(chapter.pages[0]));
  }

  placeName(section) {
    return `s. ${this.pageName(section)}`;
  }

  /** Visar ett ställe på en sida och ringar in det (Visa i boken). */
  showRange(section, start, end) {
    return this.showHit({ section, start, end });
  }

  /** Markeringen under en punkt i fönstret, eller null. */
  markAt(x, y) {
    for (const page of this.flow === 'scroll' ? [...this.cache.keys()] : this.current) {
      const entry = this.cache.get(page);
      if (!entry?.markRects) continue;
      const origin = entry.element.getBoundingClientRect();
      for (const { mark, rects } of entry.markRects) {
        if (rects.some((r) => x >= origin.left + r.left && x <= origin.left + r.left + r.width
          && y >= origin.top + r.top && y <= origin.top + r.top + r.height)) return { mark, page };
      }
    }
    return null;
  }

  /** Platsen i sidans text för en punkt i textlagret (en gräns i en markering). */
  pointOffset(entry, container, offset) {
    if (container.nodeType === Node.TEXT_NODE) {
      const i = entry.indexOf.get(container.parentElement);
      if (i !== undefined) return entry.offsets[i] + Math.min(offset, container.data.length);
    }
    const boundary = document.createRange();
    try {
      boundary.setStart(container, offset);
    } catch {
      return null;
    }
    for (let i = 0; i < entry.divs.length; i++) {
      if (boundary.comparePoint(entry.divs[i], 0) >= 0) return entry.offsets[i];
    }
    return entry.text.length;
  }

  /** Musen släpps: text som har markerats blir ett förslag till markering, ett klick på en markering
   *  öppnar dess meny. Dubbelklick (ordfunktionen) räknas inte. */
  onMouseUp(event) {
    if (event.button !== 0 || event.detail !== 1) return;
    const selection = window.getSelection();
    if (!selection.rangeCount || selection.isCollapsed) {
      const hit = this.markAt(event.clientX, event.clientY);
      if (hit) this.onMarkClick?.(hit.mark, new DOMRect(event.clientX - 10, event.clientY - 10, 20, 20));
      return;
    }
    const range = selection.getRangeAt(0);
    const element = (node) => (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
    const pageElement = element(range.startContainer)?.closest?.('.pdf-page') ?? element(range.endContainer)?.closest?.('.pdf-page');
    if (!pageElement) return;
    const index = Number(pageElement.dataset.page);
    const entry = this.cache.get(index);
    if (!entry?.text) return;
    let start = this.pointOffset(entry, range.startContainer, range.startOffset);
    let end = pageElement.contains(range.endContainer) ? this.pointOffset(entry, range.endContainer, range.endOffset) : entry.text.length;
    if (start === null || end === null) return;
    // En markering över två sidor stannar vid sidans slut, som på iPaden.
    if (!pageElement.contains(range.startContainer)) start = 0;
    while (start < end && /\s/.test(entry.text[start])) start += 1;
    while (end > start && /\s/.test(entry.text[end - 1])) end -= 1;
    if (end <= start || !/[\p{L}\p{N}]/u.test(entry.text.slice(start, end))) return;
    const rects = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
    const first = rects[0] ?? range.getBoundingClientRect();
    this.onSelect?.({ section: index, start, end, sectionText: entry.text, rect: first,
      clear: () => window.getSelection().removeAllRanges() });
  }

  /** Går till ett bokmärke (sidan). */
  goToPlace(section) {
    return this.show(section);
  }

  /** Visar en markering: sidan, och rullar till den om sidan rullas. */
  async showMark(section, text, mark) {
    await this.show(section);
    const entry = this.cache.get(section);
    const marks = entry ? (this.getMarks?.(section, entry.text) ?? []) : [];
    const found = marks.find((m) => m.id === mark.id);
    if (found) this.scrollToMark(section, found.start, found.end);
  }

  // Sök

  pageName(index) {
    return this.labels?.[index] || String(index + 1);
  }

  /** Sidans text som sökningen och markeringarna använder (samma som textlagret). */
  async pageText(index) {
    if (this.texts.has(index)) return this.texts.get(index);
    const page = await this.pdf.getPage(index + 1);
    const content = await page.getTextContent();
    // Sidor som bara söks (inte visas) släpper sina resurser direkt, så att en sökning i en stor bok inte
    // fyller minnet.
    if (!this.cache.has(index)) page.cleanup();
    let text = '';
    for (const item of content.items) {
      if (item.str === undefined) continue;
      text += item.str;
      if (item.hasEOL) text += '\n';
    }
    this.texts.set(index, text);
    return text;
  }

  /** Söker sida för sida. onResult får varje träff, onProgress andelen av boken. isCurrent() falskt avbryter. */
  async search(query, { onResult, onProgress, isCurrent }) {
    const needle = foldQuery(query);
    if (!needle || !this.pdf) return 0;
    let total = 0;
    for (let index = 0; index < this.count && total < MAX_HITS; index++) {
      if (!isCurrent() || !this.pdf) return total;
      const text = await this.pageText(index);
      if (!isCurrent()) return total;
      for (const [start, end] of findAll(text, needle, MAX_HITS - total)) {
        total += 1;
        onResult({ section: index, start, end, excerpt: excerpt(text, start, end), label: `s. ${this.pageName(index)}` });
      }
      onProgress?.((index + 1) / this.count);
      if (index % 4 === 3) await breathe();
    }
    return total;
  }

  /** Visar sidan med träffen och ringar in den. */
  async showHit(hit) {
    this.searchHit = hit;
    if (this.flow === 'scroll' || !this.current.includes(hit.section)) await this.show(hit.section);
    else this.refreshMarks();
    this.scrollToMark(hit.section, hit.start, hit.end);
  }

  /** I en sida som rullas: rulla så att intervallet syns. */
  scrollToMark(page, start, end) {
    const entry = this.cache.get(page);
    if (!this.scrollMode || !entry) return;
    const [rect] = this.rectsFor(entry, start, end);
    if (!rect) return;
    const view = this.spreadElement;
    const top = entry.element.getBoundingClientRect().top - view.getBoundingClientRect().top + view.scrollTop + rect.top;
    if (top < view.scrollTop + 40 || top > view.scrollTop + view.clientHeight - 60) {
      view.scrollTop = Math.max(0, top - view.clientHeight / 3);
    }
  }

  clearSearchHit() {
    this.searchHit = null;
    this.refreshMarks();
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
    const limit = this.current.length > 1 ? MAX_CACHED_PAGES_SPREAD : MAX_CACHED_PAGES;
    if (this.cache.size <= limit) return;
    const center = this.current[0];
    const far = [...this.cache.keys()].sort((a, b) => Math.abs(b - center) - Math.abs(a - center));
    for (const page of far) {
      if (this.cache.size <= limit) break;
      if (!this.current.includes(page)) this.forget(page);
    }
  }

  /** Sidorna som visas, eller som är på väg att visas. Flera snabba tryck på en pil räknas då från
   *  sidan som är på väg, inte från den som syntes när det första trycket kom. */
  targetPages() {
    const pages = this.target === undefined ? this.current : this.slotsFor(this.target).filter((page) => page !== null);
    return pages.length ? pages : this.current;
  }

  next() {
    if (this.flow === 'scroll') {
      const row = this.rowPages?.[this.rowOf(this.current[this.current.length - 1] ?? 0) + 1];
      return row ? this.show(row.find((page) => page !== null)) : null;
    }
    const pages = this.targetPages();
    const last = pages[pages.length - 1];
    if (last + 1 < this.count) return this.show(last + 1);
    return null;
  }

  /** atEnd: börja längst ned på sidan före (när man rullar uppåt förbi sidans topp). */
  prev({ atEnd = false } = {}) {
    if (this.flow === 'scroll') {
      const row = this.rowPages?.[this.rowOf(this.current[0] ?? 0) - 1];
      return row ? this.show(row.find((page) => page !== null)) : null;
    }
    const first = this.targetPages()[0];
    if (first > 0) return this.show(first - 1, { atEnd });
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
    this.observer?.disconnect();
    this.spreadElement.removeEventListener('scroll', this.onScroll);
    this.stage.removeEventListener('dblclick', this.onPointer);
    this.stage.removeEventListener('contextmenu', this.onPointer);
    this.stage.removeEventListener('mouseup', this.onMouseUp);
    for (const index of [...this.cache.keys()]) this.forget(index);
    closePdf(this.pdf);
    this.pdf = null;
  }
}
