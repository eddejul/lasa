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

/** Ett kort meddelande nere i fönstret som försvinner av sig själv. */
export function toast(message, seconds = 4) {
  const layer = document.getElementById('modal-layer');
  const box = el('div', { class: 'toast', role: 'status' }, message);
  layer.append(box);
  setTimeout(() => box.remove(), seconds * 1000);
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
