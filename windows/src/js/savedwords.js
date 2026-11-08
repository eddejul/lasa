// Sparade ord: varje ord som har slagits upp i en bok, med meningen det stod i. Senast först.

import { showWordPopup } from './popup.js';
import { openReview, reviewCount } from './reviewview.js';
import { deleteSavedWord, listBooks, savedWords } from './store.js';
import { el, formatDate, replace } from './ui.js';

export async function renderSavedWords(container) {
  const words = await savedWords();
  // I PDF är sidan bokens sida, i EPUB och text en plats (ungefär 1 500 tecken).
  const formats = new Map((await listBooks()).map((book) => [book.id, book.format]));
  const where = (word) => (formats.get(word.bookId) === 'pdf' || !formats.has(word.bookId)
    ? `s. ${word.page + 1}` : `plats ${word.page + 1}`);
  if (!words.length) {
    replace(container, el('div', { class: 'empty' },
      el('p', {}, 'Inga sparade ord än.'),
      el('p', {}, 'Dubbelklicka på ett ord i en bok, så sparas det här.')));
    return;
  }
  const rows = words.map((word) => {
    const heading = word.lemma.toLowerCase() === word.word.toLowerCase() ? word.lemma : `${word.word} (${word.lemma})`;
    const details = [word.language === 'en' ? 'engelska' : 'svenska', word.book, where(word), formatDate(word.updated)];
    if (word.lookups > 1) details.push(`uppslaget ${word.lookups} gånger`);
    const lookUpButton = el('button', { class: 'link-button', onclick: (event) => {
      showWordPopup({ candidates: [word.word], sentence: word.sentence, anchor: event.currentTarget.getBoundingClientRect() });
    } }, 'Slå upp');
    return el('div', { class: 'list-row saved-word', dataset: { testid: 'saved-word' } },
      el('div', { class: 'saved-word-head' },
        el('div', { class: 'list-text bold' }, heading),
        el('div', { class: 'row-buttons' }, lookUpButton,
          el('button', { class: 'link-button danger', onclick: async () => {
            await deleteSavedWord(word.id);
            renderSavedWords(container);
          } }, 'Ta bort'))),
      word.sentence ? el('div', { class: 'saved-sentence' }, word.sentence) : null,
      el('div', { class: 'list-secondary' }, details.join(' · ')));
  });
  const count = await reviewCount();
  const reviewBar = el('div', { class: 'list-section review-bar' },
    el('button', { class: 'button primary', dataset: { testid: 'review-button' },
      onclick: () => openReview({ onClose: () => renderSavedWords(container) }) },
    count ? `Repetera (${count})` : 'Repetera'),
    el('span', { class: 'list-secondary' }, count
      ? `${count} ord att repetera nu, med samma schema som på iPaden.`
      : 'Inga ord att repetera just nu.'));
  replace(container, reviewBar, el('section', { class: 'list-section' },
    el('div', { class: 'list-group' }, rows),
    el('p', { class: 'list-footer' }, `${words.length} ord. Ett ord som slås upp igen flyttas överst.`)));
}
