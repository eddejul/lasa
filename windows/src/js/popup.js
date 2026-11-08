// Ordrutan: visas vid ordet när man dubbelklickar (eller högerklickar) på det.
//
// Samma innehåll och ordning som WordPopupViewController.swift på iPaden. Överst ett tydligt svar:
// för ett engelskt ord den svenska översättningen, för ett svenskt ord betydelsen (när Folkets lexikon
// har en) med de vanligaste synonymerna. Övriga betydelser och ordklasser ligger bakom ett klick.

import { openUrl } from './backend.js';
import { dictionary, lookupStats } from './context.js';
import { explain, isConfigured as aiConfigured } from './gemini.js';
import { englishPos, guessLanguage } from './language.js';
import { RARE_ZIPF, TOP_SYNONYMS, normalize } from './lookup.js';
import { hidden, hidePair, isSaved, saveWord, unsaveWord } from './store.js';
import { el, replace } from './ui.js';

const LANGUAGE_NAMES = { sv: 'svenska', en: 'engelska' };
const other = (language) => (language === 'sv' ? 'en' : 'sv');

let current = null; // { element, stack, context, anchor, onClose }
let openAboutHandler = null;

/** Hur Om ordboken öppnas från rutan (main.js visar den som en ruta över läsaren). */
export function setAboutHandler(handler) {
  openAboutHandler = handler;
}

export function isWordPopupOpen() {
  return current !== null;
}

export function closeWordPopup() {
  if (!current) return;
  const { element, onClose } = current;
  current = null;
  element.remove();
  document.removeEventListener('keydown', onKeyDown, true);
  document.removeEventListener('mousedown', onOutside, true);
  window.removeEventListener('resize', closeWordPopup);
  onClose?.();
}

function onKeyDown(event) {
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopPropagation();
    if (current?.stack.length > 1) goBack();
    else closeWordPopup();
  }
}

function onOutside(event) {
  if (current && !current.element.contains(event.target)) closeWordPopup();
}

// Text som rutan och listorna delar

/** De vanliga synonymerna som visas direkt, eller de första tre om alla är ovanliga. */
function shownSynonyms(sense) {
  const common = sense.synonyms.slice(0, TOP_SYNONYMS).filter((s) => s.freq >= RARE_ZIPF);
  return common.length ? common : sense.synonyms.slice(0, 3);
}

export const synonymLine = (sense) => shownSynonyms(sense).map((s) => s.word).join(', ');

export const translationLine = (entry) => entry.translations
  .map((t) => (t.comment ? `${t.text} (${t.comment})` : t.text)).join(', ');

function summary(entry) {
  if (entry.translations.length) return translationLine(entry);
  const sense = entry.senses[0];
  if (!sense) return null;
  return sense.definition ?? synonymLine(sense);
}

/** Synlex-betyget som ord: 3 till 5. */
function strength(score) {
  if (score >= 4.5) return 'mycket nära';
  if (score >= 3.8) return 'nära';
  return 'ungefär';
}

// Uppslag

async function lookUp(word, { sentence = '', language = null, start = -1 } = {}) {
  const preferredPos = start >= 0 ? englishPos(sentence, start) : null;
  return dictionary.lookup(word, { sentence, language, hidden: hidden.keys, guess: guessLanguage, preferredPos });
}

/**
 * Slår upp ordet och visar rutan vid `anchor` (en ruta i fönstrets koordinater).
 * candidates: formerna att pröva i tur och ordning (ett avstavat ord först ihopslaget).
 * book: { id, title } när ordet kommer ur en bok, då sparas det i Sparade ord.
 */
export async function showWordPopup({ candidates, sentence = '', rangeInSentence = null, book = null, page = 0, anchor,
  started = performance.now(), onClose = null }) {
  closeWordPopup();
  const start = rangeInSentence ? rangeInSentence[0] : -1;
  let lookup = null;
  for (const candidate of candidates) {
    lookup = await lookUp(candidate, { sentence, start });
    if (lookup) break;
  }
  const lookupMs = performance.now() - started;
  const context = { sentence, start, book, page, triedWord: candidates[0] ?? '' };
  if (lookup && book) {
    await saveWord({ word: lookup.word, lemma: lookup.entries[0].lemma, language: lookup.language,
      sentence, book: book.title, page, bookId: book.id });
  }
  const element = el('div', { class: 'popup', role: 'dialog', 'aria-label': 'Ordet' });
  document.getElementById('popup-layer').append(element);
  // AI-knappen syns bara när en nyckel finns (Inställningar).
  const ai = lookup ? await aiConfigured().catch(() => false) : false;
  current = { element, stack: [{ type: 'word', lookup, context }], anchor, onClose, ai };
  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('mousedown', onOutside, true);
  window.addEventListener('resize', closeWordPopup);
  await render();
  lookupStats.record(lookupMs, performance.now() - started);
  return lookup;
}

function push(page) {
  current.stack.push(page);
  render();
}

function goBack() {
  if (!current || current.stack.length < 2) return;
  current.stack.pop();
  render();
}

async function render() {
  if (!current) return;
  const page = current.stack[current.stack.length - 1];
  // Har ett par dolts sedan sidan visades ska det försvinna här också.
  if (page.type === 'word' && page.lookup && page.hiddenVersion !== hidden.keys.size) {
    if (page.hiddenVersion !== undefined) {
      const fresh = await lookUp(page.lookup.word, { sentence: page.context.sentence, start: page.context.start ?? -1,
        language: page.lookup.language });
      if (fresh) {
        const same = fresh.entries.filter((e) => e.lemma === page.lookup.entries[0]?.lemma && e.pos === page.lookup.entries[0]?.pos);
        page.lookup = page.lookup.entries.length === 1 && same.length ? { ...fresh, entries: same } : fresh;
      }
    }
    page.hiddenVersion = hidden.keys.size;
  }
  const title = page.type === 'word' ? (page.lookup?.word ?? page.context.triedWord) : page.entry.lemma;
  const body = el('div', { class: 'popup-body' });
  const header = el('div', { class: 'popup-header' },
    current.stack.length > 1 ? el('button', { class: 'popup-back', onclick: goBack, 'aria-label': 'Tillbaka' }, '‹ Tillbaka') : null,
    el('div', { class: 'popup-title' }, title),
    el('button', { class: 'popup-close', onclick: closeWordPopup, 'aria-label': 'Stäng', title: 'Stäng (Esc)' }, '×'));
  if (page.type === 'word') await renderWord(page, body);
  else if (page.type === 'senses') renderSenses(page, body);
  else if (page.type === 'synonyms') renderSynonyms(page, body);
  replace(current.element, header, body);
  place();
}

function section(title, rows, footer = null) {
  return el('section', { class: 'popup-section' },
    title ? el('h3', {}, title) : null,
    el('div', { class: 'popup-group' }, rows),
    footer ? el('p', { class: 'popup-footer' }, footer) : null);
}

function row({ text, secondary = null, big = false, bold = false, muted = false, onclick = null, action = false, danger = false, testid = null }) {
  const classes = ['popup-row'];
  if (onclick) classes.push('clickable');
  if (action) classes.push('action');
  if (danger) classes.push('danger');
  const content = [
    el('div', { class: `popup-text${big ? ' big' : ''}${bold ? ' bold' : ''}${muted ? ' muted' : ''}` }, text),
    secondary ? el('div', { class: 'popup-secondary' }, secondary) : null,
  ];
  if (onclick) {
    return el('button', { class: classes.join(' '), onclick, dataset: testid ? { testid } : undefined },
      el('div', { class: 'popup-row-content' }, content), action ? null : el('span', { class: 'chevron' }, '›'));
  }
  return el('div', { class: classes.join(' '), dataset: testid ? { testid } : undefined }, content);
}

async function renderWord(page, body) {
  const { lookup, context } = page;
  const entry = lookup?.entries[0] ?? null;
  const language = lookup?.language ?? 'sv';
  const sections = [];

  if (lookup && entry) {
    const details = [entry.posName].filter((d) => d);
    if (lookup.compound) details.push(`efterled i ${lookup.word}`);
    else if (normalize(entry.lemma) !== lookup.key) details.push(`grundform till ${lookup.word}`);
    if (language === 'en') details.push('engelska');
    const top = [row({ text: entry.lemma, secondary: details.join(', '), big: true, bold: true, testid: 'header' })];
    if (lookup.compound) {
      top.push(row({ text: `${lookup.compound[0]} + ${lookup.compound[1]}`,
        secondary: 'Sammansatt ord som inte finns i ordboken. Det visar efterledet.' }));
    }
    sections.push(section(null, top));

    if (language === 'en') {
      sections.push(section('På svenska', [entry.translations.length
        ? row({ text: translationLine(entry), big: true, testid: 'translation',
          secondary: entry.via ? `Ordet saknas i lexikonet. Översättningen gäller ${entry.via}, som betyder samma sak.` : null })
        : row({ text: 'Ingen svensk översättning i ordboken.', muted: true })]));
    }
    const first = entry.senses[0];
    if (first) {
      const synonyms = synonymLine(first);
      const meaning = first.definition
        ? row({ text: first.definition, testid: 'meaning',
          secondary: synonyms ? (language === 'en' ? 'Liknande engelska ord: ' : 'Liknande ord: ') + synonyms : null,
          onclick: first.synonyms.length ? () => push({ type: 'synonyms', entry, sense: first, language }) : null })
        : row({ text: synonyms, testid: 'meaning',
          onclick: first.synonyms.length ? () => push({ type: 'synonyms', entry, sense: first, language }) : null });
      const rows = [meaning];
      if (entry.senses.length > 1) {
        const count = entry.senses.length - 1;
        rows.push(row({ text: count === 1 ? '1 betydelse till' : `${count} betydelser till`, action: true,
          onclick: () => push({ type: 'senses', entry, language }), testid: 'more-senses' }));
      }
      const title = language === 'en' ? 'Förklaring på engelska' : (first.definition ? 'Betydelse' : 'Andra ord för det');
      sections.push(section(title, rows));
    } else if (!entry.translations.length) {
      sections.push(section(null, [row({ text: 'Ordboken har ingen betydelse eller synonym för ordet.', muted: true })]));
    }
    if (current?.ai) {
      sections.push(section('Förklaring med AI', [aiRow(page)], 'Meningen och ordet skickas till Google Gemini.'));
    }
    if (lookup.entries.length > 1) {
      sections.push(section('Även som', lookup.entries.slice(1).map((otherEntry) => row({
        text: [otherEntry.lemma, otherEntry.posName].filter((t) => t).join(', '),
        secondary: summary(otherEntry),
        onclick: () => push({ type: 'word', lookup: { ...lookup, entries: [otherEntry], otherLanguageAvailable: false },
          context: { ...context, book: null } }),
      }))));
    }
  } else {
    sections.push(section(null, [row({ text: `Hittade inte ${context.triedWord} i ordboken.`, testid: 'not-found',
      secondary: 'Ordet kan vara ett namn, ett ovanligt sammansatt ord eller felstavat i PDF:en.' })]));
  }

  const actions = [];
  if (language === 'sv') {
    actions.push(row({ text: 'Visa i SO och SAOL', action: true, testid: 'svenska-se',
      onclick: () => openUrl(svenskaSeUrl(entry?.lemma ?? context.triedWord)) }));
  }
  if (lookup?.otherLanguageAvailable) {
    actions.push(row({ text: `Visa som ${LANGUAGE_NAMES[other(language)]}`, action: true, testid: 'switch-language',
      onclick: async () => {
        const switched = await lookUp(lookup.word, { sentence: context.sentence, start: context.start ?? -1, language: other(language) });
        if (switched) {
          page.lookup = switched;
          page.hiddenVersion = hidden.keys.size;
          render();
        }
      } }));
  }
  if (context.book && entry && await isSaved(entry.lemma, language)) {
    actions.push(row({ text: 'Ta bort från Sparade ord', action: true, danger: true, testid: 'unsave',
      onclick: async () => {
        await unsaveWord(entry.lemma, language);
        page.context = { ...context, removed: true };
        render();
      } }));
  }
  actions.push(row({ text: 'Om ordboken', action: true, testid: 'about',
    onclick: () => {
      closeWordPopup();
      openAboutHandler?.();
    } }));
  const footer = context.book && lookup && !context.removed ? 'Ordet är sparat i Sparade ord.' : null;
  sections.push(section(null, actions, footer));
  body.append(...sections);
}

/** AI-knappen: knappen, väntan, svaret eller felet (som på iPaden). */
function aiRow(page) {
  const ai = page.ai ?? { state: 'idle' };
  if (ai.state === 'loading') return row({ text: 'Frågar Gemini ...', muted: true, testid: 'ai' });
  if (ai.state === 'done') {
    const details = [];
    if (ai.answer.bestWord) details.push(`Passar bäst här: ${ai.answer.bestWord}`);
    if (ai.answer.senseText) details.push(`Betydelsen i ordboken: ${ai.answer.senseText}`);
    return row({ text: ai.answer.explanation, secondary: details.join('\n') || null, testid: 'ai-answer' });
  }
  if (ai.state === 'failed') {
    return row({ text: ai.message, danger: true, secondary: 'Klicka för att försöka igen.', onclick: () => askAI(page), testid: 'ai-error' });
  }
  return row({ text: 'Förklara i meningen', action: true, onclick: () => askAI(page), testid: 'ai' });
}

async function askAI(page) {
  if (!page.lookup || page.ai?.state === 'loading' || page.ai?.state === 'done') return;
  page.ai = { state: 'loading' };
  render();
  try {
    page.ai = { state: 'done', answer: await explain(page.lookup, page.context.sentence) };
  } catch (error) {
    page.ai = { state: 'failed', message: String(error?.message ?? error) };
  }
  if (current?.stack.includes(page)) render();
}

export function svenskaSeUrl(word) {
  return `https://svenska.se/tre/?sok=${encodeURIComponent(word)}&pz=1`;
}

function renderSenses(page, body) {
  const { entry, language } = page;
  const title = [entry.posName, language === 'en' ? 'förklaringar på engelska' : null].filter((t) => t).join(', ');
  const rows = entry.senses.map((sense, index) => {
    const synonyms = synonymLine(sense);
    const open = sense.synonyms.length ? () => push({ type: 'synonyms', entry, sense, language }) : null;
    if (sense.definition) {
      return row({ text: `${index + 1}. ${sense.definition}`, secondary: synonyms ? `Liknande ord: ${synonyms}` : null, onclick: open });
    }
    return row({ text: `${index + 1}. ${synonyms}`, secondary: sense.id ? null : 'Betydelsen är inte angiven i källan.', onclick: open });
  });
  body.append(section(title, rows));
}

function renderSynonyms(page, body) {
  const { entry, sense, language } = page;
  page.synonyms ??= [...sense.synonyms];
  const rows = page.synonyms.map((synonym) => {
    const notes = [];
    if (synonym.score !== null && synonym.score !== undefined) notes.push(strength(synonym.score));
    if (synonym.freq < RARE_ZIPF) notes.push('ovanligt');
    return el('div', { class: 'popup-row synonym-row', dataset: { testid: 'synonym' } },
      el('button', { class: 'synonym-word', onclick: async () => {
        const result = await lookUp(synonym.word, { language });
        push({ type: 'word', lookup: result, context: { sentence: '', book: null, page: 0, triedWord: synonym.word } });
      } },
      el('span', { class: synonym.freq < RARE_ZIPF ? 'muted' : null }, synonym.word),
      notes.length ? el('span', { class: 'popup-note' }, notes.join(', ')) : null),
      el('button', { class: 'hide-synonym', title: 'Dölj den här synonymen', onclick: async () => {
        await hidePair(language, entry.lemma, synonym.word);
        page.synonyms = page.synonyms.filter((s) => s !== synonym);
        render();
      } }, 'Fel synonym'));
  });
  body.append(section(sense.definition ?? 'Liknande ord', rows,
    'Vanliga ord först. Klicka på ett ord för att slå upp det. Klicka på Fel synonym vid ett ord som inte passar, '
    + 'så döljs det. Det döljs bara i appen och kan visas igen under Om ordboken.'));
}

/** Lägger rutan under ordet, eller över det om det inte finns plats, och alltid inom fönstret. */
function place() {
  if (!current) return;
  const { element, anchor } = current;
  const margin = 10;
  const width = Math.min(380, window.innerWidth - 2 * margin);
  element.style.width = `${width}px`;
  element.style.maxHeight = `${Math.min(560, window.innerHeight - 2 * margin)}px`;
  const height = element.offsetHeight;
  const below = window.innerHeight - anchor.bottom - margin;
  const above = anchor.top - margin;
  let top;
  if (height + 8 <= below) top = anchor.bottom + 8;
  else if (height + 8 <= above) top = anchor.top - 8 - height;
  else top = Math.max(margin, window.innerHeight - margin - height);
  let left = anchor.left + anchor.width / 2 - width / 2;
  left = Math.max(margin, Math.min(window.innerWidth - margin - width, left));
  element.style.top = `${Math.round(top)}px`;
  element.style.left = `${Math.round(left)}px`;
}
