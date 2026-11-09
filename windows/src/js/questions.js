// Frågor i marginalen (K6) och AI-frågorna (K6b) i den öppna boken. Kravet är docs/AI-FRAGOR.md och
// docs/FRAGOR.md, logiken utan sidor i aiquestions.js. Här finns texten som skickas, kön till Gemini (ett
// anrop åt gången i hela appen), prickarna, rutan med frågan, panelen Frågor och raderna före och efter
// kapitlet. Läsarna (pdfreader.js och reflowreader.js) ger kapitlen och texten och ritar prickarna.

import {
  KIND_QUESTIONS, MIN_CHAPTER, OPEN_TYPES, TYPE_IDS, SCHEMA_COMPARE, SCHEMA_QUESTIONS, buildCompare, buildPrompt, capFor, chapterKeyFor, check,
  checkSummary, foldedQuery, locateRange, partCount, splitParts, typeName, validAnswer, validCompare,
} from './aiquestions.js';
import { chapterNodes } from './chaptertext.js';
import { AIFailure, aiModel, generate, isConfigured, quotaResetText } from './gemini.js';
import { breathe, foldText } from './search.js';
import {
  aiQuestions, deleteAiQuestions, deleteQuestionFile, otherBooksWithQuestions, questionAnswers, questionFile,
  saveAiQuestions, saveQuestionFile, setQuestionFeedback, setQuestionMyAnswer, setQuestionStatus, setSetting, settings,
} from './store.js';
import { confirmDialog, el, replace, toast } from './ui.js';

// Inställningarna: Frågor i marginalen (av från början) och under det Gör frågor med AI (på från början).
export const questionsEnabled = () => settings.questionsInMargin === true;
export const aiEnabled = () => settings.aiQuestions !== false;
export async function setQuestionsEnabled(on) {
  await setSetting('questionsInMargin', Boolean(on));
}
export async function setAiEnabled(on) {
  await setSetting('aiQuestions', Boolean(on));
}

export const STATUSES = [['kan', 'Kan'], ['osaker', 'Osäker'], ['kan_inte', 'Kan inte']];
const STATUS_NAMES = Object.fromEntries(STATUSES);
const SUGGESTION = { bra: 'kan', delvis: 'osaker', saknas_mycket: 'kan_inte' };
const MAX_FILE = 2000000;
const PAUSE_WHOLE_BOOK = 4000;
const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// Texten som skickas, med vägen tillbaka till avsnittens egen text (den som markeringarna räknar i).

const BLOCKS = new Set(['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'section', 'article', 'td', 'th',
  'tr', 'pre', 'dt', 'dd', 'figcaption', 'header', 'footer', 'aside', 'table', 'ul', 'ol', 'dl', 'figure', 'nav', 'main',
  'caption', 'hr', 'body']);

/** Texten med en karta: place(pos) ger { section, offset } i avsnittets text. end: pos är ett slut (exklusive). */
function makeSource(text, segments) {
  return {
    text,
    place(pos, end = false) {
      const p = end ? pos - 1 : pos;
      let lo = 0;
      let hi = segments.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const s = segments[mid];
        if (p < s.from) hi = mid - 1;
        else if (p >= s.to) lo = mid + 1;
        else return { section: s.section, offset: s.base + (p - s.from) + (end ? 1 : 0) };
      }
      const next = segments[lo] ?? segments[segments.length - 1];
      return next ? { section: next.section, offset: next.base } : null;
    },
  };
}

/** Ett EPUB-kapitel: kapitlets text utan taggar (som markeringarna), med en tom rad mellan styckena. */
export function paragraphSource(doc, section) {
  const { root, nodes } = chapterNodes(doc);
  const blockOf = (node) => {
    for (let element = node.parentNode; element && element !== root; element = element.parentNode) {
      if (BLOCKS.has(element.localName)) return element;
    }
    return root;
  };
  let text = '';
  const segments = [];
  let lastBlock = null;
  for (const { node, start } of nodes) {
    const block = blockOf(node);
    const blank = !/\S/.test(node.data);
    if (blank && block !== lastBlock) continue; // blanktecken mellan styckena
    if (text && block !== lastBlock) text += '\n\n';
    segments.push({ from: text.length, to: text.length + node.data.length, section, base: start });
    text += node.data;
    lastBlock = block;
  }
  return makeSource(text, segments);
}

/** PDF: sidornas text i ordning med en tom rad emellan. pages [{ page, text }]. */
export function pagesSource(pages) {
  let text = '';
  const segments = [];
  pages.forEach(({ page, text: pageText }, i) => {
    if (i > 0) text += '\n\n';
    segments.push({ from: text.length, to: text.length + pageText.length, section: page, base: 0 });
    text += pageText;
  });
  return makeSource(text, segments);
}

// Frågefilen (docs/FRAGOR.md), som BookQuestionFile.parse på iPaden.

const plain = (value) => {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  return '';
};
const integer = (value) => {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === 'string' && /^\s*-?\d+\s*$/.test(value)) return parseInt(value, 10);
  return null;
};
const pointList = (value) => (Array.isArray(value) ? value.map(plain).filter(Boolean) : (plain(value) ? [plain(value)] : []));

/** Frågorna i en frågefil. Kastar ett Error med ett svenskt besked om filen inte går att läsa. */
export function parseQuestionFile(text) {
  if (text.length > MAX_FILE) throw new Error('Frågefilen är större än 2 MB och läses inte.');
  let object;
  try {
    object = JSON.parse(text);
  } catch {
    throw new Error('Filen är inte giltig JSON.');
  }
  const list = Array.isArray(object) ? object : (object?.fragor ?? object?.['frågor'] ?? object?.questions);
  if (!Array.isArray(list)) throw new Error('Filen saknar listan fragor.');
  const result = [];
  const used = new Set();
  for (const entry of list) {
    if (!entry || typeof entry !== 'object') continue;
    const question = plain(entry.fraga ?? entry['fråga'] ?? entry.question);
    const quote = plain(entry.citat ?? entry.quote);
    const rawPage = integer(entry.sida ?? entry.page);
    const page = rawPage === null ? null : Math.min(Math.max(rawPage, 1), 100000);
    if (!question || (!quote && page === null)) continue;
    const number = result.length + 1;
    let id = plain(entry.id);
    if (!id) id = `f${fnv64(`${question}|${quote}`).toString(36)}`;
    if (used.has(id)) id += `-${number}`;
    used.add(id);
    const chapter = entry.kapitel ?? entry.chapter;
    const y = typeof entry.y === 'number' ? Math.min(Math.max(entry.y, 0), 1) : null;
    const typ = plain(entry.typ);
    const nar = ['fore', 'efter', 'slut'].includes(plain(entry.nar)) ? plain(entry.nar) : 'efter';
    result.push({
      source: 'file', id, number, title: plain(entry.titel ?? entry.title), fraga: question, svar: pointList(entry.svar ?? entry.answer),
      quote, page, chapterNumber: integer(chapter), chapterTitle: typeof chapter === 'string' && integer(chapter) === null ? plain(chapter) : null,
      y, typ: TYPE_IDS.includes(typ) ? typ : '', nar, kalla: plain(entry.kalla), oppen: OPEN_TYPES.has(typ),
    });
  }
  return result;
}

function fnv64(text) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash;
}

// Kön: ett anrop till Gemini åt gången i hela appen.

const listeners = new Set();
/** Läget som panelen visar. blocked: { kind, message } när något hindrar (nyckel, kvot, nät). */
export const aiState = { busy: null, whole: null, blocked: null, blockedUntil: 0 };
const jobs = [];
let pumping = false;

export function onAiState(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
function notify() {
  for (const listener of [...listeners]) {
    try {
      listener(aiState);
    } catch (error) {
      console.warn(error);
    }
  }
}

/** Lägger ett jobb i kön. priority: först i kön (Jämför). Ger jobbets resultat. */
function enqueue(key, run, { priority = false } = {}) {
  const existing = jobs.find((job) => job.key === key);
  if (existing) return existing.promise;
  const job = { key, run };
  job.promise = new Promise((resolve, reject) => {
    job.resolve = resolve;
    job.reject = reject;
  });
  if (priority) jobs.unshift(job);
  else jobs.push(job);
  pump();
  return job.promise;
}

function dropJobs(filter) {
  for (let i = jobs.length - 1; i >= 0; i--) {
    if (filter(jobs[i])) {
      const [job] = jobs.splice(i, 1);
      job.resolve('avbrutet');
    }
  }
}

async function pump() {
  if (pumping) return;
  pumping = true;
  try {
    while (jobs.length) {
      const job = jobs.shift();
      try {
        job.resolve(await job.run());
      } catch (error) {
        job.reject(error);
      }
    }
  } finally {
    pumping = false;
  }
}

/** Ett anrop med kravets regler: minutens kvot väntar retryDelay (högst 60 s) och försöker en gång till, och ett
 *  svar som inte går att läsa försöks en gång till. */
async function ask(prompt, schema, validate, { maxOutputTokens, timeout }) {
  let waited = false;
  let invalid = 0;
  for (;;) {
    try {
      const answer = validate(await generate({ prompt, schema, maxOutputTokens, temperature: 0.3, timeout }));
      if (answer) return answer;
      throw new AIFailure('invalid', 'Svaret från Gemini gick inte att läsa. Prova igen.');
    } catch (failure) {
      if (failure?.kind === 'invalid' && invalid < 1) {
        invalid += 1;
        continue;
      }
      if (failure?.kind === 'quotaMinute' && !waited) {
        waited = true;
        await sleep(Math.min(Math.max(failure.seconds ?? 60, 1), 60) * 1000);
        continue;
      }
      throw failure;
    }
  }
}

function block(failure) {
  aiState.blocked = { kind: failure.kind, message: failure.message };
  aiState.blockedUntil = failure.kind === 'quotaDay' ? nextQuotaReset() : 0;
  notify();
}

function nextQuotaReset() {
  const [hours, minutes] = quotaResetText().split('.').map(Number);
  const reset = new Date();
  reset.setHours(hours, minutes, 0, 0);
  if (reset.getTime() <= Date.now()) reset.setDate(reset.getDate() + 1);
  return reset.getTime();
}

function stillBlocked() {
  if (!aiState.blocked) return false;
  if (aiState.blocked.kind === 'quotaDay') {
    if (Date.now() < aiState.blockedUntil) return true;
    aiState.blocked = null;
    notify();
    return false;
  }
  // Nyckel och modell hindrar tills de rättats. Nät och andra fel hindrar inte: kapitlet försöks igen nästa
  // gång det visas.
  return ['noKey', 'badKey', 'unknownModel'].includes(aiState.blocked.kind);
}

// Den öppna boken.

/** Frågorna i den öppna boken. reader ger questionChapters(), questionText(kapitel), sectionText(avsnitt),
 *  chapterForPlace(plats) och showRange(avsnitt, start, slut). host är läsarens yta för raderna. */
export class BookQuestions {
  constructor(book, { reader, host, onRefresh, onOpenSettings, onPanelChange }) {
    this.book = book;
    this.reader = reader;
    this.host = host;
    this.onRefresh = onRefresh;
    this.onOpenSettings = onOpenSettings;
    this.onPanelChange = onPanelChange;
    this.ai = []; // rader ur ai_questions
    this.file = null; // { name, questions, error }
    this.answers = new Map();
    this.chapters = null;
    this.dots = new Map(); // avsnitt -> [{ id, offset, y, number }]
    this.byId = new Map();
    this.foreShown = new Set();
    this.endShown = new Set();
    this.failed = new Set();
    this.lengths = new Map();
    this.closed = false;
    this.unsubscribe = onAiState(() => this.onPanelChange?.());
  }

  get hasFile() {
    return Boolean(this.file?.questions?.length);
  }

  async load() {
    // En nyckel eller modell kan ha rättats sedan förra boken: försök igen.
    if (aiState.blocked && aiState.blocked.kind !== 'quotaDay') {
      aiState.blocked = null;
      notify();
    }
    const stored = await questionFile(this.book.id);
    this.file = null;
    if (stored) {
      try {
        this.file = { name: stored.name, questions: parseQuestionFile(stored.json), error: '' };
      } catch (error) {
        this.file = { name: stored.name, questions: [], error: error.message };
      }
    }
    this.ai = await aiQuestions(this.book.id);
    this.answers = await questionAnswers(this.book.id);
    // Kapitlen tas fram bara när frågorna är påslagna och boken gick att öppna.
    const opened = this.reader.kind === 'pdf' ? Boolean(this.reader.pdf) : Boolean(this.reader.view?.book);
    this.chapters = [];
    if (questionsEnabled() && opened) {
      try {
        this.chapters = await this.reader.questionChapters();
      } catch (error) {
        console.warn('Kapitlen för frågorna kunde inte tas fram', error);
      }
    }
    await this.rebuild();
  }

  close() {
    this.closed = true;
    this.unsubscribe();
    this.banner?.remove();
    // Kapitel som väntar i kön för den här boken görs inte. Ett anrop som redan har skickats sparas ändå.
    dropJobs((job) => job.key.startsWith(`${this.book.id}|`));
    if (aiState.whole?.book === this.book.id) {
      aiState.whole = null;
      notify();
    }
  }

  /** Bokens frågor i bokens ordning med nummer, och prickarna per avsnitt. */
  async rebuild() {
    const list = [];
    if (this.hasFile) {
      await this.placeFileQuestions();
      for (const q of this.file.questions) list.push(q);
    } else {
      for (const row of this.ai) {
        const chapter = this.chapterByKey(row.chapter);
        for (const q of row.questions) {
          list.push({ ...q, source: 'ai', chapterKey: row.chapter, chapterTitle: row.chapterTitle, part: row.part,
            order: chapter?.order ?? 0 });
        }
      }
    }
    this.byId = new Map(list.map((q) => [q.id, q]));
    const inText = list.filter((q) => q.nar === 'efter' && Number.isInteger(q.section))
      .sort((a, b) => a.section - b.section || (a.offset ?? a.y * 1e9) - (b.offset ?? b.y * 1e9));
    this.dots = new Map();
    inText.forEach((q, i) => {
      q.number = i + 1;
      if (!this.dots.has(q.section)) this.dots.set(q.section, []);
      this.dots.get(q.section).push({ id: q.id, offset: q.offset ?? null, y: q.offset === undefined || q.offset === null ? (q.y ?? 0.08) : null,
        number: q.number, status: this.answers.get(q.id)?.status ?? '' });
    });
    this.list = list;
  }

  chapterByKey(key) {
    return this.chapters?.find((chapter) => chapter.key === key) ?? null;
  }

  /** Prickarna i ett avsnitt (sidan i en PDF, kapitlet i en EPUB): [{ id, offset, y, number, status }]. */
  dotsFor(section) {
    if (!questionsEnabled()) return [];
    return this.dots.get(section) ?? [];
  }

  /** Frågefilens frågor letas upp i boken: sidan eller kapitlet först, sedan resten. */
  async placeFileQuestions() {
    const pdf = this.book.format === 'pdf';
    const count = this.reader.sectionCount;
    const titles = pdf ? [] : this.chapters.map((chapter) => chapter.title);
    const folded = new Map();
    const foldedOf = async (section) => {
      if (!folded.has(section)) folded.set(section, foldText(await this.reader.sectionText(section)));
      return folded.get(section);
    };
    for (const q of this.file.questions) {
      if (q.placed) continue;
      q.placed = true;
      let hint = null;
      if (pdf && q.page) hint = Math.min(q.page - 1, count - 1);
      if (!pdf) {
        if (q.chapterNumber && q.chapterNumber >= 1 && q.chapterNumber <= count) hint = q.chapterNumber - 1;
        else if (q.chapterTitle) {
          const wanted = foldedQuery(q.chapterTitle);
          let index = titles.findIndex((title) => foldedQuery(title) === wanted);
          if (index < 0) index = titles.findIndex((title) => foldedQuery(title).includes(wanted));
          if (index >= 0) hint = this.chapters[index].index;
        }
      }
      if (!q.quote) {
        if (hint !== null) {
          q.section = hint;
          q.y = q.y ?? 0.08;
        }
      } else {
        const needle = foldedQuery(q.quote);
        const order = [...Array(count).keys()].sort((x, y) => (hint === null ? x - y : Math.abs(x - hint) - Math.abs(y - hint) || x - y));
        for (const section of order) {
          const text = await foldedOf(section);
          const at = text.text.indexOf(needle);
          if (at >= 0) {
            q.section = section;
            q.offset = text.map[at + needle.length - 1] + 1;
            break;
          }
          if (section === hint) {
            const range = locateRange(q.quote, await this.reader.sectionText(section));
            if (range) {
              q.section = section;
              q.offset = range.end;
              break;
            }
          }
          if (section % 8 === 7) await breathe();
        }
      }
      if (!Number.isInteger(q.section)) continue;
      // De valfria fälten (docs/FRAGOR.md): källan letas upp i samma avsnitt, och kapitlet behövs för fore och slut.
      if (q.kalla) {
        const range = locateRange(q.kalla, await this.reader.sectionText(q.section));
        if (range) q.kallaPlace = { section: q.section, start: range.start, end: range.end };
      }
      const chapter = this.chapters?.length
        ? this.reader.chapterForPlace(pdf ? { pages: [q.section] } : { section: q.section }, this.chapters) : null;
      q.chapterKey = chapter?.key ?? null;
    }
  }

  // Att göra frågorna

  /** Om AI-frågor ska göras i den här boken just nu. Ger beskedet som hindrar, eller ''. */
  async aiBlocker() {
    if (!questionsEnabled() || !aiEnabled()) return 'off';
    if (this.hasFile) return 'file';
    if (this.noText()) return 'noText';
    if (!(await isConfigured())) return 'noKey';
    return '';
  }

  noText() {
    return this.book.format === 'pdf' && this.chapters !== null && this.reader.hasNoText?.() === true;
  }

  hasChapter(key) {
    return this.ai.some((row) => row.chapter === key);
  }

  /** Kapitlet sparades som för kort, utan frågor och sammanfattning. */
  isShortChapter(key) {
    const rows = this.ai.filter((row) => row.chapter === key);
    return rows.length > 0 && rows.every((row) => !row.questions.length && !row.summary);
  }

  /** Läsaren visar en ny plats: kapitlets frågor görs om de saknas, sedan nästa kapitels. */
  async onShown(place) {
    if (this.closed || !this.chapters?.length || !place) return;
    const chapter = this.reader.chapterForPlace(place, this.chapters);
    if (!chapter) return;
    const previous = this.currentChapter;
    this.currentChapter = chapter;
    let ended = false;
    if (previous && previous.key !== chapter.key) {
      this.failed.delete(previous.key);
      if (this.banner?.dataset.testid === 'before-reading') this.banner.remove();
      // Kapitlet är slut: bara när man bläddrar framåt förbi kapitlets sista sida, inte vid ett hopp.
      const turned = this.turning && this.turning.direction > 0 && Date.now() - this.turning.at < 3000;
      if (turned && chapter.order === previous.order + 1 && questionsEnabled()) ended = this.offerChapterEnd(previous);
    }
    // Raden före läsningen väntar tills raden om kapitlet som tog slut har stängts.
    this.lastPlace = place;
    const endBanner = this.banner?.isConnected && this.banner.dataset.testid === 'chapter-end';
    if (questionsEnabled() && !ended && !endBanner) this.offerBeforeReading(chapter, place);
    // Nyckeln läses bara när något kapitel saknar frågor, inte vid varje sidvändning.
    const next = this.chapters[chapter.order + 1];
    const targets = [chapter, next].filter((target) => target && !this.hasChapter(target.key) && !this.failed.has(target.key));
    if (!targets.length || stillBlocked() || await this.aiBlocker()) return;
    for (const target of targets) this.queueChapter(target).catch(() => {});
  }

  /** Läsaren bläddrar (1 framåt, -1 bakåt), för raden Kapitlet är slut. */
  noteTurn(direction) {
    this.turning = { direction, at: Date.now() };
  }

  queueChapter(chapter, { replace = false } = {}) {
    return enqueue(`${this.book.id}|${chapter.key}|${replace ? 'ny' : ''}`, () => this.makeChapter(chapter, { replace }));
  }

  /** Gör ett kapitels frågor: texten, en fråga per del till Gemini, kontrollen och sparandet. */
  async makeChapter(chapter, { replace = false } = {}) {
    if (this.closed && !replace) return 'stängd';
    if (!replace && this.hasChapter(chapter.key)) return 'finns';
    if (stillBlocked() && aiState.blocked.kind === 'quotaDay') return 'kvot';
    const source = await this.reader.questionText(chapter);
    this.lengths.set(chapter.key, source.text.length);
    const book = this.book;
    const model = aiModel();
    if (source.text.length < MIN_CHAPTER) {
      if (replace) await deleteAiQuestions(book.id, chapter.key);
      await saveAiQuestions(book.id, { chapter: chapter.key, part: 1, chapterTitle: chapter.title, model, summary: '', concepts: [], questions: [] });
      await this.reloadAi();
      return 'kort';
    }
    aiState.busy = { book: book.id, title: chapter.title };
    notify();
    try {
      const last = await this.isLastChapterWithText(chapter);
      const earlier = this.earlierSummaries(chapter);
      const others = (await otherBooksWithQuestions(book.id)).slice(0, 5).map((other) => ({
        titel: other.title,
        sammanfattning: other.summaries.slice(0, 2).reverse().join(' ').slice(0, 400),
        begrepp: other.concepts.slice(0, 8),
      }));
      const parts = splitParts(source.text);
      const results = [];
      for (const [i, range] of parts.entries()) {
        const text = source.text.slice(range.start, range.end);
        const tal = partCount(text.length, { firstPart: i === 0, lastPart: i === parts.length - 1, lastChapter: last });
        const prompt = buildPrompt({ titel: book.title, forfattare: book.author },
          { rubrik: chapter.title, del: i + 1, delar: parts.length, text, sista: last }, earlier, others, tal);
        const answer = await ask(prompt, SCHEMA_QUESTIONS, validAnswer, { maxOutputTokens: 8192, timeout: 90000 });
        const { kept, dropped } = check(answer, text, { bookId: book.id, chapterKey: chapter.key, part: i + 1,
          otherTitles: others.map((other) => other.titel), cap: capFor(tal) });
        console.info(checkSummary(chapter.key, kept, dropped));
        for (const q of kept) {
          if (q.position !== null) {
            q.position += range.start;
            const place = source.place(q.position, true);
            if (place) {
              q.section = place.section;
              q.offset = place.offset;
            }
          }
          if (q.kalla) {
            const found = locateRange(q.kalla, text);
            if (found) {
              const a = source.place(found.start + range.start);
              const b = source.place(found.end + range.start, true);
              if (a && b) q.kallaPlace = { section: a.section, start: a.offset, end: b.section === a.section ? b.offset : a.offset + 1 };
            }
          }
          delete q.nr;
        }
        results.push({ part: i + 1, summary: answer.sammanfattning, concepts: answer.begrepp, questions: kept });
      }
      if (replace) await deleteAiQuestions(book.id, chapter.key);
      for (const result of results) {
        await saveAiQuestions(book.id, { chapter: chapter.key, part: result.part, chapterTitle: chapter.title, model, ...result });
      }
      if (aiState.blocked) {
        aiState.blocked = null;
        notify();
      }
      await this.reloadAi();
      return 'klar';
    } catch (failure) {
      this.failed.add(chapter.key);
      if (failure instanceof AIFailure) {
        console.warn(`AI-frågor ${chapter.key}: ${failure.message}`);
        if (failure.kind !== 'invalid' && failure.kind !== 'cancelled') {
          block(failure);
          dropJobs((job) => job.key.includes('|') && !job.key.startsWith('jamfor|'));
          if (aiState.whole) aiState.whole.cancelled = true;
        }
      } else {
        console.error(failure);
      }
      throw failure;
    } finally {
      aiState.busy = null;
      notify();
    }
  }

  async reloadAi() {
    if (this.closed) return;
    this.ai = await aiQuestions(this.book.id);
    await this.rebuild();
    this.onRefresh?.();
    this.onPanelChange?.();
    // Raden före läsningen, om kapitlet som visas just fick sina frågor.
    if (this.lastPlace && this.currentChapter) this.offerBeforeReading(this.currentChapter, this.lastPlace);
  }

  earlierSummaries(chapter) {
    const result = [];
    for (const row of this.ai) {
      const other = this.chapterByKey(row.chapter);
      if (!other || other.order >= chapter.order || !row.summary) continue;
      result.push({ order: other.order, part: row.part, rubrik: row.chapterTitle || other.title, sammanfattning: row.summary });
    }
    return result.sort((a, b) => a.order - b.order || a.part - b.part);
  }

  /** Bokens sista kapitel med text: alla senare kapitel är för korta. */
  async isLastChapterWithText(chapter) {
    for (const later of this.chapters.slice(chapter.order + 1)) {
      if (!this.lengths.has(later.key)) {
        try {
          this.lengths.set(later.key, (await this.reader.questionText(later)).text.length);
        } catch {
          this.lengths.set(later.key, 0);
        }
      }
      if (this.lengths.get(later.key) >= MIN_CHAPTER) return false;
    }
    return true;
  }

  /** Gör frågor till hela boken: resten av kapitlen i läsordning, med fyra sekunders paus mellan anropen. */
  async wholeBook() {
    if (aiState.whole) return;
    aiState.blocked = null;
    const remaining = this.chapters.filter((chapter) => !this.hasChapter(chapter.key));
    const whole = { book: this.book.id, done: 0, total: remaining.length, cancelled: false };
    aiState.whole = whole;
    notify();
    let first = true;
    for (const chapter of remaining) {
      if (whole.cancelled || this.closed) break;
      if (this.hasChapter(chapter.key)) {
        whole.done += 1;
        notify();
        continue;
      }
      if (!first) await sleep(PAUSE_WHOLE_BOOK);
      if (whole.cancelled || this.closed) break;
      let result;
      try {
        result = await this.queueChapter(chapter);
      } catch {
        if (aiState.blocked) break;
      }
      first = result === 'kort' || result === 'finns';
      whole.done += 1;
      notify();
    }
    if (aiState.whole === whole) aiState.whole = null;
    notify();
  }

  cancelWholeBook() {
    if (!aiState.whole) return;
    aiState.whole.cancelled = true;
    dropJobs((job) => job.key.startsWith(`${this.book.id}|`));
    notify();
  }

  async replaceChapter(chapter) {
    const ok = await confirmDialog({ title: 'Gör nya frågor till kapitlet?',
      message: `Frågorna till ${chapter.title} byts ut. Svaren på de gamla frågorna hör då inte längre till någon fråga.`,
      confirm: 'Gör nya frågor' });
    if (!ok) return;
    aiState.blocked = null;
    this.failed.delete(chapter.key);
    try {
      await this.queueChapter(chapter, { replace: true });
      toast(`Nya frågor till ${chapter.title}.`, 3);
    } catch (failure) {
      toast(failure?.message ?? String(failure));
    }
  }

  // Frågefilen

  async chooseFile() {
    const input = el('input', { type: 'file', accept: '.json,application/json', hidden: true });
    document.body.append(input);
    const file = await new Promise((resolve) => {
      input.addEventListener('change', () => resolve(input.files?.[0] ?? null), { once: true });
      input.click();
    });
    input.remove();
    if (!file) return;
    if (file.size > MAX_FILE) {
      toast('Frågefilen är större än 2 MB och läses inte.');
      return;
    }
    const text = await file.text();
    let questions;
    try {
      questions = parseQuestionFile(text);
    } catch (error) {
      toast(`Frågefilen kunde inte läsas: ${error.message}`);
      return;
    }
    await saveQuestionFile(this.book.id, file.name, text);
    toast(`${questions.length} ${questions.length === 1 ? 'fråga' : 'frågor'} ur ${file.name}.`, 3);
    await this.load();
    this.onRefresh?.();
    this.onPanelChange?.();
  }

  async removeFile() {
    const ok = await confirmDialog({ title: 'Ta bort frågefilen?', message: 'Frågorna ur filen försvinner ur boken. Svaren finns kvar.',
      confirm: 'Ta bort', danger: true });
    if (!ok) return;
    await deleteQuestionFile(this.book.id);
    await this.load();
    this.onRefresh?.();
    this.onPanelChange?.();
  }

  // Raderna före och efter kapitlet

  showBanner(testid, text, actions, onDone = null) {
    this.banner?.remove();
    const banner = el('div', { class: 'question-banner', role: 'status', dataset: { testid } },
      el('span', { class: 'question-banner-text' }, text),
      ...actions.map(([label, run]) => el('button', { class: 'link-button', onclick: () => {
        banner.remove();
        run?.();
        onDone?.();
      } }, label)));
    this.banner = banner;
    this.host.append(banner);
  }

  /** Läs för att ta reda på: på kapitlets första sida, en gång per kapitel medan boken är öppen. */
  offerBeforeReading(chapter, place) {
    this.lastPlace = place;
    if (this.foreShown.has(chapter.key) || !this.reader.isChapterStart(place, chapter)) return;
    const fore = this.chapterQuestions(chapter).filter((q) => q.nar === 'fore');
    if (!fore.length) return;
    this.foreShown.add(chapter.key);
    const first = fore[0].fraga.length > 110 ? `${fore[0].fraga.slice(0, 107).trimEnd()} ...` : fore[0].fraga;
    this.showBanner('before-reading', `Läs för att ta reda på: ${first}`,
      [['Visa', () => this.openSequence(fore)], ['Stäng', null]]);
  }

  /** Kapitlet är slut: när man bläddrar förbi kapitlets sista sida. Öppnar slut- och fore-frågorna en i taget. */
  offerChapterEnd(chapter) {
    if (this.endShown.has(chapter.key)) return false;
    const questions = this.chapterQuestions(chapter);
    const list = [...questions.filter((q) => q.nar === 'slut'), ...questions.filter((q) => q.nar === 'fore')];
    if (!list.length) return false;
    this.endShown.add(chapter.key);
    this.showBanner('chapter-end', `Kapitlet är slut: ${list.length} ${list.length === 1 ? 'fråga' : 'frågor'}`,
      [['Visa', () => this.openSequence(list)], ['Stäng', null]],
      () => this.offerBeforeReading(this.currentChapter, this.lastPlace));
    return true;
  }

  chapterQuestions(chapter) {
    return (this.list ?? []).filter((q) => q.chapterKey === chapter.key)
      .sort((a, b) => (a.part - b.part) || 0);
  }

  // Rutan med en fråga

  open(id) {
    const question = this.byId.get(id);
    if (question) this.openSequence([question], 0);
  }

  openSequence(list, index = 0) {
    if (!list.length) return;
    showQuestionBox(this, list, index);
  }

  async setStatus(question, status) {
    await setQuestionStatus(this.book.id, question.id, status);
    const old = this.answers.get(question.id) ?? { answered: 0, myAnswer: '', feedback: null };
    this.answers.set(question.id, { ...old, status, answered: (old.answered ?? 0) + 1, updated: Date.now() / 1000 });
    await this.rebuild();
    this.onRefresh?.();
    this.onPanelChange?.();
  }

  async saveMyAnswer(question, text) {
    const old = this.answers.get(question.id);
    if ((old?.myAnswer ?? '') === text) return;
    await setQuestionMyAnswer(this.book.id, question.id, text);
    this.answers.set(question.id, { status: '', answered: 0, feedback: null, ...old, myAnswer: text });
  }

  /** Jämför: frågan, svarspunkterna, källan och det skrivna svaret, aldrig kapitlets text. */
  async compare(question, myAnswer) {
    const feedback = await enqueue(`jamfor|${this.book.id}|${question.id}|${Date.now()}`,
      () => ask(buildCompare(question, myAnswer), SCHEMA_COMPARE, validCompare, { maxOutputTokens: 1024, timeout: 45000 }),
      { priority: true });
    if (typeof feedback !== 'object') throw new AIFailure('cancelled', 'Avbrutet.');
    await setQuestionFeedback(this.book.id, question.id, myAnswer, feedback);
    const old = this.answers.get(question.id);
    this.answers.set(question.id, { status: '', answered: 0, ...old, myAnswer, feedback });
    return feedback;
  }

  showInBook(question) {
    const place = question.kallaPlace;
    if (place && Number.isInteger(place.section)) this.reader.showRange(place.section, place.start, place.end);
  }

  placeLabel(question) {
    if (!Number.isInteger(question.section)) return '';
    return this.reader.placeName(question.section);
  }
}

// Rutan

function showQuestionBox(controller, list, startIndex) {
  const layer = document.getElementById('modal-layer');
  let index = startIndex;
  let current = null;
  let answerArea = null;
  let closed = false;

  const saveAnswer = async () => {
    if (current?.source === 'ai' && answerArea) await controller.saveMyAnswer(current, answerArea.value);
  };
  const close = async () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey, true);
    backdrop.remove();
    await saveAnswer();
  };
  const onKey = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
    }
  };
  const box = el('div', { class: 'dialog question-box', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Fråga',
    dataset: { testid: 'question-box' } });
  const backdrop = el('div', { class: 'modal-backdrop question-backdrop', onclick: (event) => { if (event.target === backdrop) close(); } }, box);

  const render = async () => {
    current = list[index];
    const q = current;
    const isAi = q.source === 'ai';
    const saved = controller.answers.get(q.id) ?? null;
    const configured = isAi ? await isConfigured() : false;
    if (closed) return;
    const title = isAi ? typeName(q) : (q.title || (q.typ ? typeName(q) : 'Fråga'));
    answerArea = isAi ? el('textarea', { class: 'text-input question-answer-input', rows: '4', placeholder: 'Skriv eller diktera ditt svar',
      'aria-label': 'Ditt svar', dataset: { testid: 'my-answer' } }) : null;
    if (answerArea) {
      answerArea.value = saved?.myAnswer ?? '';
      answerArea.addEventListener('keydown', (event) => event.stopPropagation());
    }
    const compareButton = isAi ? el('button', { class: 'button', dataset: { testid: 'compare' }, onclick: () => runCompare() }, 'Jämför med mitt svar') : null;
    const updateCompare = () => {
      if (compareButton) compareButton.hidden = !(configured && answerArea.value.trim());
    };
    answerArea?.addEventListener('input', updateCompare);
    const answerBox = el('div', { class: 'question-reveal', hidden: true, dataset: { testid: 'answer-box' } },
      q.svar?.length ? el('ul', { class: 'question-points' }, q.svar.map((point) => el('li', {}, point))) : el('p', { class: 'muted' }, 'Inget svar i frågan.'),
      q.kalla ? el('p', { class: 'question-source', dataset: { testid: 'source' } }, 'Ur boken: ', el('em', {}, q.kalla)) : null,
      q.kalla && q.kallaPlace ? el('button', { class: 'button', dataset: { testid: 'show-in-book' }, onclick: async () => {
        await close();
        controller.showInBook(q);
      } }, 'Visa i boken') : null);
    const reveal = el('button', { class: 'button primary', dataset: { testid: 'reveal' }, onclick: () => {
      answerBox.hidden = false;
      reveal.hidden = true;
    } }, 'Visa svaret');
    const feedbackBox = el('div', { class: 'question-feedback', dataset: { testid: 'feedback' } });
    const statusButtons = STATUSES.map(([status, label]) => el('button', {
      class: `button status-${status}${saved?.status === status ? ' selected' : ''}`, dataset: { testid: `status-${status}` },
      onclick: async () => {
        await saveAnswer();
        await controller.setStatus(q, status);
        if (index + 1 < list.length) {
          index += 1;
          render();
        } else {
          close();
        }
      } }, label));
    const showFeedback = (feedback) => {
      const section = (name, kind, items) => (items?.length ? el('div', { class: `feedback-${kind}` },
        el('strong', {}, name), el('ul', {}, items.map((item) => el('li', {}, item)))) : null);
      replace(feedbackBox,
        q.oppen ? null : section('Med', 'med', feedback.med),
        q.oppen ? null : section('Saknas', 'saknas', feedback.saknas),
        section('Fel', 'fel', feedback.fel),
        feedback.kommentar ? el('p', { class: 'feedback-comment' }, feedback.kommentar) : null);
      const suggested = SUGGESTION[feedback.omdome];
      for (const button of statusButtons) button.classList.toggle('suggested', button.dataset.testid === `status-${suggested}`);
    };
    const runCompare = async () => {
      const text = answerArea.value.trim();
      if (!text) return;
      compareButton.disabled = true;
      replace(feedbackBox, el('p', { class: 'muted' }, 'Jämför ...'));
      try {
        showFeedback(await controller.compare(q, answerArea.value));
      } catch (failure) {
        replace(feedbackBox, el('p', { class: 'question-error', dataset: { testid: 'compare-error' } }, failure?.message ?? String(failure)));
      } finally {
        compareButton.disabled = false;
      }
    };
    const place = controller.placeLabel(q);
    replace(box,
      el('div', { class: 'panel-head' },
        el('h2', { dataset: { testid: 'question-title' } }, title),
        el('button', { class: 'popup-close', onclick: () => close(), 'aria-label': 'Stäng' }, '×')),
      list.length > 1 ? el('p', { class: 'muted question-count' }, `Fråga ${index + 1} av ${list.length}`) : null,
      el('p', { class: 'question-text', dataset: { testid: 'question-text' } }, q.fraga),
      answerArea ? el('label', { class: 'question-label' }, 'Ditt svar') : null,
      answerArea,
      answerArea ? el('p', { class: 'settings-note' }, 'Windows-tangenten och H dikterar.') : null,
      el('div', { class: 'question-actions' }, reveal, compareButton),
      answerBox,
      feedbackBox,
      el('div', { class: 'question-status' }, statusButtons),
      !isAi && place ? el('p', { class: 'settings-note' }, place) : null,
      isAi ? el('p', { class: 'question-ai-note' }, 'Gjord med AI') : null);
    updateCompare();
    if (saved?.feedback && isAi) showFeedback(saved.feedback);
    (answerArea ?? reveal).focus();
  };

  layer.append(backdrop);
  document.addEventListener('keydown', onKey, true);
  render();
}

// Panelen Frågor

export function renderQuestionsPanel(panel, controller, { onClose }) {
  const head = el('div', { class: 'panel-head' }, el('h2', {}, 'Frågor'),
    el('button', { class: 'popup-close', onclick: () => onClose(), 'aria-label': 'Stäng' }, '×'));
  const body = el('div', { class: 'questions-panel', dataset: { testid: 'questions-panel' } });
  replace(panel, head, body);
  const draw = async () => {
    const blocker = await controller.aiBlocker();
    const rows = [];
    // Raden om AI-frågorna.
    if (!controller.hasFile && blocker !== 'off') {
      const chapters = controller.chapters ?? [];
      // Kapitel som är för korta (omslag, innehåll, tack) räknas inte.
      const short = chapters.filter((chapter) => controller.isShortChapter(chapter.key)).length;
      const withQuestions = chapters.filter((chapter) => controller.hasChapter(chapter.key) && !controller.isShortChapter(chapter.key)).length;
      const done = chapters.filter((chapter) => controller.hasChapter(chapter.key)).length;
      const line = el('div', { class: 'ai-line', dataset: { testid: 'ai-line' } });
      const parts = [el('p', { class: 'ai-line-text' }, `AI-frågor: ${withQuestions} av ${chapters.length - short} kapitel har frågor.`)];
      if (blocker === 'noText') {
        parts.push(el('p', { class: 'ai-message', dataset: { testid: 'ai-message' } }, 'Boken har ingen text att göra frågor av. Gör den sökbar först.'));
      } else if (blocker === 'noKey') {
        parts.push(el('p', { class: 'ai-message', dataset: { testid: 'ai-message' } }, 'Förklaring med AI är inte uppsatt än. Det tar en minut: skapa en gratis nyckel i Google AI Studio och klistra in den under Inställningar.'),
          el('button', { class: 'button', onclick: () => controller.onOpenSettings?.() }, 'Öppna Inställningar'));
      } else {
        if (aiState.whole?.book === controller.book.id) {
          parts.push(el('p', { class: 'ai-progress', dataset: { testid: 'ai-progress' } },
            `Gör frågor ... ${aiState.whole.done} av ${aiState.whole.total} kapitel.`),
          el('button', { class: 'button', dataset: { testid: 'ai-cancel' }, onclick: () => controller.cancelWholeBook() }, 'Avbryt'));
        } else if (done < chapters.length) {
          parts.push(el('button', { class: 'button primary', dataset: { testid: 'ai-whole-book' }, onclick: () => controller.wholeBook() },
            'Gör frågor till hela boken'));
        }
        if (aiState.busy?.book === controller.book.id) parts.push(el('p', { class: 'muted', dataset: { testid: 'ai-busy' } }, `Gör frågor till ${aiState.busy.title} ...`));
        if (aiState.blocked) {
          parts.push(el('p', { class: 'ai-message', dataset: { testid: 'ai-message' } }, aiState.blocked.message));
          if (['noKey', 'badKey', 'unknownModel'].includes(aiState.blocked.kind)) {
            parts.push(el('button', { class: 'button', onclick: () => controller.onOpenSettings?.() }, 'Öppna Inställningar'));
          }
        }
      }
      replace(line, ...parts);
      rows.push(line);
    } else if (blocker === 'off' && !controller.hasFile) {
      rows.push(el('p', { class: 'muted' }, 'Gör frågor med AI är avstängt (Visning eller Aa).'));
    }
    // Frågefilen.
    if (controller.file) {
      rows.push(el('div', { class: 'ai-line' },
        el('p', {}, `Frågefil: ${controller.file.name}`),
        controller.file.error ? el('p', { class: 'ai-message' }, controller.file.error) : null,
        el('button', { class: 'button', onclick: () => controller.removeFile() }, 'Ta bort frågefilen')));
    } else {
      rows.push(el('button', { class: 'link-button', dataset: { testid: 'choose-question-file' }, onclick: () => controller.chooseFile() }, 'Välj frågefil'));
    }
    // Frågorna kapitel för kapitel.
    const questionRow = (q) => {
      const status = controller.answers.get(q.id)?.status ?? '';
      return el('button', { class: 'question-row', dataset: { testid: 'question-row' }, onclick: () => controller.openSequence([q]) },
        q.number ? el('span', { class: 'question-dot small' }, String(q.number)) : null,
        el('span', { class: 'question-row-text' }, q.fraga),
        status ? el('span', { class: `question-row-status status-${status}` }, STATUS_NAMES[status]) : null);
    };
    const list = controller.list ?? [];
    if (controller.hasFile) {
      rows.push(el('div', { class: 'question-group' }, list.map((q) => [
        el('div', { class: 'settings-note' }, q.title || (Number.isInteger(q.section) ? controller.placeLabel(q) : 'Hittades inte i boken')),
        questionRow(q)])));
    } else {
      for (const chapter of controller.chapters ?? []) {
        const qs = list.filter((q) => q.chapterKey === chapter.key);
        if (!qs.length) continue;
        const group = (name, items) => (items.length ? [el('h4', { class: 'panel-subhead' }, name), items.map(questionRow)] : null);
        const inText = qs.filter((q) => q.nar === 'efter').sort((a, b) => (a.number ?? 0) - (b.number ?? 0));
        rows.push(el('section', { class: 'question-chapter', dataset: { testid: 'question-chapter' } },
          el('h3', { class: 'question-chapter-title' }, chapter.title),
          group('Före läsningen', qs.filter((q) => q.nar === 'fore')),
          group(`I texten (${controller.reader.placeName(inText[0]?.section ?? chapter.index ?? 0)})`, inText),
          group('Efter kapitlet', qs.filter((q) => q.nar === 'slut')),
          el('button', { class: 'link-button', dataset: { testid: 'ai-replace-chapter' }, onclick: () => controller.replaceChapter(chapter) },
            'Gör nya frågor till kapitlet')));
      }
      if (!list.length && blocker !== 'off') rows.push(el('p', { class: 'muted' }, 'Inga frågor än. Frågorna görs när ett kapitel visas.'));
    }
    replace(body, ...rows);
  };
  draw();
  return draw;
}

export { KIND_QUESTIONS };
