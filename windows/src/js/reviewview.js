// Repetera sparade ord (W5): samma kort och ordning som WordReviewViewController.swift på iPaden.
// Ordet och meningen det stod i, Visa svaret, och fyra betyg med när ordet kommer igen.
// Tangenter: mellanslag eller Enter visar svaret, 1 till 4 ger betyg, Esc stänger.

import { dictionary } from './context.js';
import { synonymLine, translationLine } from './popup.js';
import { GRADES, againCard, buildQueue, graded, intervalLabel, nextReview } from './review.js';
import { hidden, recordReview, reviewWords } from './store.js';
import { el, replace } from './ui.js';

const now = () => Date.now() / 1000;

/** Antalet ord att repetera nu, till knappen Repetera. */
export async function reviewCount() {
  return buildQueue(await reviewWords(), now()).length;
}

/** Svaret ur ordboken: översättningen för engelska ord, betydelsen och synonymerna för svenska. */
async function answerFor(word) {
  let lookup = null;
  try {
    lookup = await dictionary.lookup(word.lemma, { sentence: word.sentence, language: word.language, hidden: hidden.keys });
  } catch {
    lookup = null;
  }
  const entry = lookup?.entries?.[0];
  if (!entry) return 'Ordboken har inget svar för ordet.';
  const lines = [];
  if (word.language === 'en') {
    const translation = translationLine(entry);
    lines.push(translation || 'Ingen svensk översättning i ordboken.');
    if (entry.senses[0]?.definition) lines.push(entry.senses[0].definition);
  } else if (entry.senses[0]) {
    const sense = entry.senses[0];
    if (sense.definition) lines.push(sense.definition);
    const synonyms = synonymLine(sense);
    if (synonyms) lines.push(`Liknande ord: ${synonyms}`);
  }
  return lines.length ? lines.join('\n\n') : 'Ordboken har inget svar för ordet.';
}

/** Meningen med ordet i fetstil. */
function sentenceWith(text, word) {
  const at = text.toLowerCase().indexOf(word.toLowerCase());
  if (at < 0) return [text];
  return [text.slice(0, at), el('strong', {}, text.slice(at, at + word.length)), text.slice(at + word.length)];
}

/** Öppnar repetitionen som en ruta över allt. onClose anropas när den stängs. */
export async function openReview({ onClose = null } = {}) {
  const queue = buildQueue(await reviewWords(), now());
  let index = 0;
  let reviewed = 0;
  let revealed = false;
  let busy = false; // ett betyg sparas: inga tangenter förrän nästa kort visas
  const layer = document.getElementById('modal-layer');
  const body = el('div', { class: 'review', dataset: { testid: 'review' } });

  const close = () => {
    backdrop.remove();
    document.removeEventListener('keydown', onKey, true);
    onClose?.();
  };

  async function show() {
    revealed = false;
    if (index >= queue.length) {
      replace(body, el('p', { class: 'review-done', dataset: { testid: 'review-done' } }, reviewed === 0
        ? 'Inga ord att repetera just nu.\nOrd du slår upp i böckerna hamnar här.'
        : `Klart för i dag.\nDu repeterade ${reviewed} ord.`),
      el('div', { class: 'review-buttons' }, el('button', { class: 'button primary', onclick: close }, 'Stäng')));
      return;
    }
    const card = queue[index];
    const { word } = card;
    const sentence = word.sentence && word.sentence !== word.word
      ? el('p', { class: 'review-sentence' }, sentenceWith(word.sentence, word.word)) : null;
    const showButton = el('button', { class: 'button primary review-show', dataset: { testid: 'review-show' }, onclick: reveal }, 'Visa svaret');
    replace(body,
      el('p', { class: 'review-progress', dataset: { testid: 'review-progress' } },
        `${queue.length - index} kvar${card.isNew ? ', nytt ord' : ''}`),
      el('div', { class: 'review-card' },
        el('div', { class: 'review-word', dataset: { testid: 'review-word' } }, word.lemma),
        el('div', { class: 'review-language' }, word.language === 'en' ? 'engelska' : 'svenska'),
        sentence,
        el('div', { class: 'review-answer', hidden: true, dataset: { testid: 'review-answer' } })),
      el('div', { class: 'review-buttons' }, showButton));
    showButton.focus();
  }

  async function reveal() {
    if (busy || index >= queue.length || revealed) return;
    revealed = true;
    const card = queue[index];
    const answer = body.querySelector('.review-answer');
    answer.textContent = await answerFor(card.word);
    answer.hidden = false;
    replace(body.querySelector('.review-buttons'), GRADES.map((grade, i) => el('button', {
      class: `button review-grade grade-${grade.id}`, dataset: { testid: `grade-${grade.id}` }, title: `${grade.title} (${i + 1})`,
      onclick: () => grade_(grade.id),
    }, el('span', { class: 'grade-title' }, grade.title),
    el('span', { class: 'grade-when' }, intervalLabel(nextReview(grade.id, card).interval)))));
  }

  async function grade_(grade) {
    if (busy || index >= queue.length || !revealed) return;
    const card = queue[index];
    busy = true;
    try {
      await recordReview(card.word.lemma, card.word.language, graded(grade, card, now()));
      reviewed += 1;
      // Ett ord man glömt kommer igen i slutet av omgången.
      if (grade === 'again') queue.push(againCard(card));
      index += 1;
    } finally {
      busy = false;
    }
    show();
  }

  const onKey = (event) => {
    if (event.target?.closest?.('.dialog:not(.review-dialog)')) return;
    const key = event.key;
    let handled = true;
    if (key === 'Escape') close();
    else if ((key === ' ' || key === 'Enter') && !revealed && index < queue.length) reveal();
    else if (['1', '2', '3', '4'].includes(key) && revealed) grade_(GRADES[Number(key) - 1].id);
    else handled = false;
    if (handled) {
      event.preventDefault();
      event.stopPropagation();
    }
  };

  const backdrop = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === backdrop) close(); } },
    el('div', { class: 'dialog review-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Repetera' },
      el('div', { class: 'panel-head' }, el('h2', {}, 'Repetera'),
        el('button', { class: 'popup-close', onclick: close, 'aria-label': 'Stäng', title: 'Stäng (Esc)' }, '×')),
      body,
      el('p', { class: 'list-footer review-help' }, 'Mellanslag visar svaret, 1 till 4 ger betyg. Samma schema som på iPaden, och repetitionen synkas.')));
  layer.append(backdrop);
  document.addEventListener('keydown', onKey, true);
  show();
}
