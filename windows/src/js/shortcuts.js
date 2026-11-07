// Tangentbordsgenvägar: listan (?), helskärm (F11), och webbläsarens egna tangenter som inte hör hemma
// i en app (F5 och Ctrl och R laddar om sidan, Ctrl och P skriver ut, Alt och vänsterpil går bakåt).
// Läsarens egna genvägar (bläddra, Ctrl och F, Ctrl och G, B) sköts i reader.js.

import { el } from './ui.js';

const CONTROL_KEYS = new Set(['r', 'p', 's', 'u', 'j', 'h', 'n', 'l', 'd', 'e', 'k', 't']);

/** Sant för en tangent som webbvyn annars skulle använda själv (ladda om, skriva ut, spara sidan). */
export function isBrowserKey(event) {
  const key = event.key ?? '';
  const ctrl = event.ctrlKey || event.metaKey;
  if (['F3', 'F5', 'F7', 'BrowserBack', 'BrowserForward', 'BrowserRefresh', 'BrowserHome', 'BrowserSearch'].includes(key)) return true;
  if (event.altKey && !ctrl && ['ArrowLeft', 'ArrowRight', 'Home'].includes(key)) return true;
  if (ctrl && !event.altKey && CONTROL_KEYS.has(key.toLowerCase())) return true;
  return false;
}

/** Stoppar webbläsarens egna tangenter i ett dokument (fönstret eller ett EPUB-kapitel). */
export function blockBrowserKeys(target) {
  target.addEventListener('keydown', (event) => {
    if (isBrowserKey(event)) event.preventDefault();
  }, true);
}

/** Helskärm av och på. I appen hela fönstret, i en vanlig webbläsare sidan. */
export async function toggleFullscreen() {
  const current = globalThis.__TAURI__?.window?.getCurrentWindow?.();
  if (current) {
    await current.setFullscreen(!(await current.isFullscreen()));
    return;
  }
  if (document.fullscreenElement) await document.exitFullscreen();
  else await document.documentElement.requestFullscreen();
}

export const SHORTCUTS = [
  ['Bläddra', 'Högerpil och vänsterpil, PageDown och PageUp, mellanslag (Skift och mellanslag bakåt), mushjulet'],
  ['Början och slutet av boken', 'Home och End'],
  ['Sök i boken', 'Ctrl och F (Enter går till nästa träff)'],
  ['Gå till sida', 'Ctrl och G'],
  ['Bokmärke på sidan', 'B (en gång till tar bort det)'],
  ['Markera text', 'Dra över texten med musen och välj en färg'],
  ['Slå upp ett ord', 'Dubbelklicka eller högerklicka på ordet'],
  ['Zooma (PDF)', 'Ctrl och plus eller minus, Ctrl och mushjulet, Ctrl och 0 återställer'],
  ['Byt tema', 'T (vitt, sepia, mörkt, följ systemet)'],
  ['Lägg till böcker', 'Ctrl och O'],
  ['Helskärm', 'F11'],
  ['Stäng en ruta, eller tillbaka till biblioteket', 'Esc'],
  ['Den här listan', '?'],
];

/** Visar listan med genvägar. Esc, ? eller ett klick utanför stänger den. */
export function showShortcuts() {
  const layer = document.getElementById('modal-layer');
  if (layer.querySelector('[data-testid="shortcuts"]')) return;
  const close = () => {
    backdrop.remove();
    document.removeEventListener('keydown', onKey, true);
  };
  const onKey = (event) => {
    if (event.key === 'Escape' || event.key === '?') {
      event.preventDefault();
      event.stopPropagation();
      close();
    }
  };
  const backdrop = el('div', { class: 'modal-backdrop', onclick: (event) => { if (event.target === backdrop) close(); } },
    el('div', { class: 'dialog shortcuts-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Tangentbordsgenvägar',
      dataset: { testid: 'shortcuts' } },
    el('div', { class: 'panel-head' }, el('h2', {}, 'Tangentbordsgenvägar'),
      el('button', { class: 'popup-close', onclick: close, 'aria-label': 'Stäng' }, '×')),
    el('table', { class: 'shortcuts-table' }, SHORTCUTS.map(([what, keys]) => el('tr', {},
      el('th', { scope: 'row' }, what), el('td', {}, keys))))));
  layer.append(backdrop);
  document.addEventListener('keydown', onKey, true);
}
