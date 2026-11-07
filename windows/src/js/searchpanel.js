// Panelen Sök i boken (Ctrl och F): sökfält, hur långt sökningen har kommit, och träffarna med utdrag.
// Ett klick på en träff visar den i boken och ringar in den. Enter går till nästa träff, Skift och Enter
// till föregående. Själva sökningen görs av läsaren (PdfReader.search eller ReflowReader.search).

import { el, replace } from './ui.js';

/** Sökningens läge för en öppen bok, så att träffarna finns kvar när panelen öppnas igen. */
export function newSearchState() {
  return { query: '', hits: [], token: 0, running: false, progress: 0, selected: -1 };
}

export function renderSearchPanel(panel, reader, state, { onClose }) {
  const input = el('input', { type: 'search', class: 'text-input search-input', value: state.query,
    placeholder: 'Ord eller fras', 'aria-label': 'Sök i boken', spellcheck: 'false', dataset: { testid: 'search-input' } });
  const status = el('p', { class: 'search-status muted', role: 'status', dataset: { testid: 'search-status' } });
  const list = el('div', { class: 'search-results', dataset: { testid: 'search-results' } });

  const statusText = () => {
    if (!state.query) return 'Skriv minst två tecken. Sökningen bryr sig inte om stora och små bokstäver.';
    const count = state.hits.length;
    const found = count === 0 ? 'Inga träffar' : (count === 1 ? '1 träff' : `${count} träffar`);
    if (state.running) return `Söker ... ${Math.round(state.progress * 100)} %. ${found} hittills.`;
    return count >= 500 ? `${found}, sökningen slutade vid 500.` : `${found}.`;
  };

  const row = (hit, index) => {
    const button = el('button', { class: `search-hit${index === state.selected ? ' selected' : ''}`, dataset: { testid: 'search-hit-row' },
      onclick: () => select(index) },
    el('span', { class: 'search-hit-label' }, hit.label),
    el('span', { class: 'search-hit-text' }, hit.excerpt.pre, el('mark', {}, hit.excerpt.match), hit.excerpt.post));
    return button;
  };

  const renderAll = () => {
    status.textContent = statusText();
    replace(list, state.hits.map(row));
  };

  async function select(index) {
    if (index < 0 || index >= state.hits.length) return;
    state.selected = index;
    for (const [i, child] of [...list.children].entries()) child.classList.toggle('selected', i === index);
    list.children[index]?.scrollIntoView({ block: 'nearest' });
    await reader.showHit(state.hits[index]);
  }

  async function run() {
    const query = input.value.trim();
    if (query === state.query && (state.running || state.hits.length)) return;
    state.query = query.length >= 2 ? query : '';
    state.hits = [];
    state.selected = -1;
    state.progress = 0;
    const token = ++state.token;
    reader.clearSearchHit?.();
    if (!state.query) {
      state.running = false;
      renderAll();
      return;
    }
    state.running = true;
    renderAll();
    const isCurrent = () => token === state.token;
    try {
      await reader.search(state.query, {
        isCurrent,
        onResult: (hit) => {
          if (!isCurrent()) return;
          state.hits.push(hit);
          const view = state.view;
          if (view?.list.isConnected) view.list.append(view.row(hit, state.hits.length - 1));
        },
        onProgress: (progress) => {
          if (!isCurrent()) return;
          state.progress = progress;
          if (state.view) state.view.status.textContent = statusText();
        },
      });
    } catch (error) {
      console.warn('Sökningen misslyckades', error);
    }
    if (!isCurrent()) return;
    state.running = false;
    if (state.view) state.view.status.textContent = statusText();
  }

  let timer = null;
  input.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(run, 350);
  });
  input.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    clearTimeout(timer);
    if (input.value.trim() !== state.query) {
      run();
      return;
    }
    if (!state.hits.length) return;
    const next = event.shiftKey ? state.selected - 1 : state.selected + 1;
    select((next + state.hits.length) % state.hits.length);
  });

  replace(panel,
    el('div', { class: 'panel-head' }, el('h2', {}, 'Sök i boken'),
      el('button', { class: 'popup-close', onclick: onClose, 'aria-label': 'Stäng', title: 'Stäng (Esc)' }, '×')),
    input, status, list,
    el('p', { class: 'list-footer search-help' }, 'Enter går till nästa träff, Skift och Enter till föregående.'));
  // Sökningen kan pågå medan panelen stängs och öppnas igen: träffarna läggs i den panel som visas.
  state.view = { list, status, row };
  renderAll();
  input.focus();
  input.select();
}
