// Små hjälpare för gränssnittet.

/** Skapar ett element. Barn som är null, undefined eller false hoppas över, listor plattas ut. */
export function el(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes ?? {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') element.className = value;
    else if (key === 'text') element.textContent = value;
    else if (key.startsWith('on') && typeof value === 'function') element.addEventListener(key.slice(2), value);
    else if (key === 'dataset') Object.assign(element.dataset, value);
    else if (value === true) element.setAttribute(key, '');
    else element.setAttribute(key, value);
  }
  append(element, children);
  return element;
}

/** Lägger till barn utan att null, false eller listor blir text. */
export function append(parent, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    parent.append(child instanceof Node ? child : String(child));
  }
  return parent;
}

export function replace(parent, ...children) {
  parent.replaceChildren();
  return append(parent, children);
}

/** En enkel ruta med text och två knappar, i stället för window.confirm. Ger true eller false. */
export function confirmDialog({ title, message, confirm = 'OK', cancel = 'Avbryt', danger = false }) {
  return new Promise((resolve) => {
    const layer = document.getElementById('modal-layer');
    const close = (answer) => {
      dialog.remove();
      document.removeEventListener('keydown', onKey, true);
      resolve(answer);
    };
    const onKey = (event) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        close(false);
      }
    };
    const confirmButton = el('button', { class: danger ? 'button danger' : 'button primary', onclick: () => close(true) }, confirm);
    const dialog = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === dialog) close(false); } },
      el('div', { class: 'dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
        el('h2', {}, title),
        message ? el('p', {}, message) : null,
        el('div', { class: 'dialog-buttons' },
          el('button', { class: 'button', onclick: () => close(false) }, cancel),
          confirmButton)));
    layer.append(dialog);
    document.addEventListener('keydown', onKey, true);
    confirmButton.focus();
  });
}

/** En fråga med flera svar (choices: { label, value, kind: 'primary' | 'danger' }). Ger svarets value, eller
 *  null om rutan stängs med Esc eller ett klick utanför. Svaren står i den ordning de ges. details är rader
 *  ({ label, value }) som visas under meddelandet, till exempel två filnamn sida vid sida. */
export function choiceDialog({ title, message, details = [], choices }) {
  return new Promise((resolve) => {
    const layer = document.getElementById('modal-layer');
    const close = (answer) => {
      dialog.remove();
      document.removeEventListener('keydown', onKey, true);
      resolve(answer);
    };
    const onKey = (event) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        close(null);
      }
    };
    const buttons = choices.map((choice) => el('button', {
      class: `button${choice.kind ? ` ${choice.kind}` : ''}`, onclick: () => close(choice.value),
      dataset: { choice: String(choice.value) },
    }, choice.label));
    const dialog = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === dialog) close(null); } },
      el('div', { class: 'dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': title, dataset: { testid: 'choice-dialog' } },
        el('h2', {}, title),
        message ? el('p', {}, message) : null,
        details.length ? el('dl', { class: 'dialog-details', dataset: { testid: 'choice-details' } },
          details.map((row) => [el('dt', {}, row.label), el('dd', {}, row.value)])) : null,
        el('div', { class: 'dialog-buttons dialog-choices' }, buttons)));
    layer.append(dialog);
    document.addEventListener('keydown', onKey, true);
    (buttons.find((button, index) => choices[index].kind === 'primary') ?? buttons[0])?.focus();
  });
}

/** En ruta med ett textfält. Ger texten, eller null om den avbryts. */
export function promptDialog({ title, message, value = '', placeholder = '', confirm = 'OK' }) {
  return new Promise((resolve) => {
    const layer = document.getElementById('modal-layer');
    const input = el('input', { type: 'text', value, placeholder, class: 'text-input', 'aria-label': title });
    const close = (answer) => {
      dialog.remove();
      resolve(answer);
    };
    const form = el('form', { class: 'dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': title,
      onsubmit: (event) => { event.preventDefault(); close(input.value); } },
    el('h2', {}, title),
    message ? el('p', {}, message) : null,
    input,
    el('div', { class: 'dialog-buttons' },
      el('button', { type: 'button', class: 'button', onclick: () => close(null) }, 'Avbryt'),
      el('button', { type: 'submit', class: 'button primary' }, confirm)));
    const dialog = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === dialog) close(null); } }, form);
    input.addEventListener('keydown', (event) => {
      event.stopPropagation();
      if (event.key === 'Escape') {
        event.preventDefault();
        close(null);
      }
    });
    layer.append(dialog);
    input.focus();
    input.select();
  });
}

/** Ett kort meddelande nere i fönstret som försvinner av sig själv. Längre meddelanden (fel) står kvar
 *  längre, och ett klick på meddelandet tar bort det direkt. Flera meddelanden läggs på varandra. */
export function toast(message, seconds = null) {
  const text = String(message);
  const time = seconds ?? Math.min(12, Math.max(4, text.length / 18));
  const box = el('div', { class: 'toast', role: 'status', title: 'Klicka för att stänga' }, text);
  box.addEventListener('click', () => box.remove());
  toastStack().append(box);
  setTimeout(() => box.remove(), time * 1000);
}

function toastStack() {
  let stack = document.getElementById('toast-stack');
  if (!stack) {
    stack = el('div', { id: 'toast-stack', class: 'toast-stack' });
    document.getElementById('modal-layer').append(stack);
  }
  return stack;
}

/** Ett meddelande som står kvar medan något pågår ("Lägger till 3 av 7"). set byter texten, close tar bort det. */
export function statusBox(message = '') {
  const box = el('div', { class: 'toast status-box', role: 'status', dataset: { testid: 'status-box' } }, message);
  toastStack().append(box);
  return {
    set(text) { box.textContent = text; },
    close() { box.remove(); },
  };
}

export function formatDate(seconds) {
  const date = new Date(seconds * 1000);
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  if (sameDay) return 'i dag';
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) return 'i går';
  return date.toLocaleDateString('sv-SE', { day: 'numeric', month: 'short', year: 'numeric' });
}
