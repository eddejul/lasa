// Gör sökbar (P1): en skannad PDF får osynlig text i spaltordning genom datorns OCR. Rust-delen (och
// dev/server.py) kör tools/ocr/sokbar_pdf.py med Python och Tesseract. Den nya filen läggs i biblioteket
// bredvid originalet, som en vanlig fil (importFiles), och originalet rörs inte.

import { invoke, ocrTake } from './backend.js';
import { importFiles } from './library.js';
import { contentId, setSetting, settings } from './store.js';
import { choiceDialog, confirmDialog, el, toast } from './ui.js';

export const DEFAULT_PYTHON = 'python';
export const DEFAULT_TESSERACT = 'C:\\Program Files\\Tesseract-OCR\\tesseract.exe';

/** Sökvägarna ur Inställningar. Tomt betyder standard (python i PATH, Tesseract i Program Files och dess
 *  egen tessdata-mapp). */
export function ocrTools(values = settings) {
  return {
    python: (values.ocrPython || '').trim() || DEFAULT_PYTHON,
    tesseract: (values.ocrTesseract || '').trim() || null,
    tessdata: (values.ocrTessdata || '').trim() || null,
  };
}

export async function saveOcrTools({ python, tesseract, tessdata }) {
  await setSetting('ocrPython', python?.trim() || null);
  await setSetting('ocrTesseract', tesseract?.trim() || null);
  await setSetting('ocrTessdata', tessdata?.trim() || null);
}

/** Kontrollerar Python, paketen, Tesseract och den svenska modellen. Ger { ok, saknas: [...], ... }. */
export async function checkOcr(tools = ocrTools()) {
  return invoke('ocr_check', tools);
}

/** Vad som saknas, i klartext, en rad per sak. */
export function missingLines(result) {
  const lines = [];
  for (const item of result?.saknas ?? []) {
    if (item === 'python') {
      lines.push('Python hittades inte. Installera Python 3 från python.org (kryssa i Add python.exe to PATH), '
        + 'eller skriv in sökvägen till python.exe under Inställningar, Gör sökbar.'
        + (result.fel ? ` (${result.fel})` : ''));
    } else if (item.startsWith('python-paket')) {
      const name = item.slice('python-paket'.length).trim();
      lines.push(`Python-paketet ${name} saknas. Skriptet behöver PyMuPDF, numpy och Pillow `
        + '(pip install pymupdf numpy pillow).');
    } else if (item === 'tesseract') {
      lines.push('Tesseract hittades inte. Installera Tesseract OCR för Windows (installationsfilen från UB Mannheim), '
        + 'eller skriv in sökvägen till tesseract.exe under Inställningar, Gör sökbar.');
    } else if (item.startsWith('sprak')) {
      const lang = item.slice('sprak'.length).trim() || 'swe';
      lines.push(`Den svenska modellen (${lang}.traineddata) saknas${result.tessdata ? ` i ${result.tessdata}` : ''}. `
        + 'Hämta den från github.com/tesseract-ocr/tessdata_best, lägg den i en mapp och skriv in mappen under '
        + 'Inställningar, Gör sökbar (Mapp med språkmodeller).');
    } else {
      lines.push(item);
    }
  }
  return lines;
}

/** Rutan när något saknas. Ger true om användaren vill till Inställningar. */
async function showMissing(result) {
  const choice = await choiceDialog({
    title: 'Gör sökbar behöver mer på datorn',
    message: missingLines(result).join(' '),
    choices: [
      { label: 'Öppna Inställningar', value: 'settings', kind: 'primary' },
      { label: 'Stäng', value: 'close' },
    ],
  });
  if (choice === 'settings') window.dispatchEvent(new CustomEvent('lasa-show-tab', { detail: 'settings' }));
}

/** Den nya filens namn: Bok.pdf blir Bok (sökbar).pdf. */
export function searchableName(fileName) {
  const base = String(fileName || 'Bok.pdf').replace(/\.pdf$/i, '');
  return `${base} (sökbar).pdf`;
}

let current = null;

/** Pågår Gör sökbar? Ger { book, done, total } eller null. */
export function ocrRunning() {
  return current ? { book: current.book, done: current.done, total: current.total } : null;
}

/** Rutan nere i fönstret medan sidorna läses: titel, sida N av M, en stapel och Avbryt. */
function progressBox(book, onCancel) {
  const text = el('span', { class: 'ocr-text' }, `Gör ${book.title} sökbar ...`);
  const fill = el('div', { class: 'progress-fill', style: 'width: 0%' });
  const cancel = el('button', { class: 'link-button ocr-cancel', dataset: { testid: 'ocr-cancel' }, onclick: () => {
    cancel.disabled = true;
    text.textContent = 'Avbryter ...';
    onCancel();
  } }, 'Avbryt');
  const box = el('div', { class: 'toast ocr-box', role: 'status', dataset: { testid: 'ocr-box' } },
    el('div', { class: 'ocr-row' }, text, cancel),
    el('div', { class: 'progress-bar' }, fill));
  let stack = document.getElementById('toast-stack');
  if (!stack) {
    stack = el('div', { id: 'toast-stack', class: 'toast-stack' });
    document.getElementById('modal-layer').append(stack);
  }
  stack.append(box);
  return {
    update({ done, total }) {
      if (cancel.disabled) return;
      text.textContent = total ? `Gör ${book.title} sökbar: sida ${Math.min(done + 1, total)} av ${total}`
        : `Gör ${book.title} sökbar ...`;
      fill.style.width = `${total ? Math.round((done / total) * 100) : 0}%`;
    },
    close() { box.remove(); },
  };
}

const wait = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** Knappen Gör sökbar på en PDF i biblioteket. */
export async function makeSearchable(book) {
  if (current) {
    toast('En bok görs redan sökbar. Vänta tills den är klar, eller avbryt den.');
    return;
  }
  let check;
  try {
    check = await checkOcr();
  } catch (error) {
    toast(`Gör sökbar gick inte att starta (${error?.message ?? error}).`);
    return;
  }
  if (!check?.ok) {
    await showMissing(check);
    return;
  }
  const ok = await confirmDialog({
    title: `Gör ${book.title} sökbar?`,
    message: `Sensus läser sidorna med Tesseract och lägger texten osynligt på sidorna, i spaltordning. Den nya filen `
      + `heter ${searchableName(book.fileName)} och läggs i biblioteket bredvid originalet, som inte ändras. `
      + 'Du kan läsa under tiden.',
    confirm: 'Gör sökbar',
  });
  if (ok) await run(book, false);
}

async function run(book, replace) {
  let job;
  try {
    job = await invoke('ocr_start', { id: contentId(book), replace, ...ocrTools() });
  } catch (error) {
    toast(`Gör sökbar gick inte att starta (${error?.message ?? error}).`);
    return;
  }
  current = { book, job, done: 0, total: 0 };
  const box = progressBox(book, () => invoke('ocr_cancel', { job }).catch(() => {}));
  let status = null;
  let taken = false;
  try {
    for (;;) {
      await wait(600);
      status = await invoke('ocr_status', { job });
      current.done = status.done;
      current.total = status.total;
      if (status.state !== 'running') break;
      box.update(status);
    }
    if (status.state === 'done') {
      const bytes = await ocrTake(job);
      taken = true;
      box.close();
      const name = searchableName(book.fileName);
      const added = await importFiles([new File([bytes], name, { type: 'application/pdf', lastModified: Date.now() })]);
      if (added) window.dispatchEvent(new CustomEvent('lasa-library-changed'));
      return;
    }
  } catch (error) {
    status = { state: 'error', message: String(error?.message ?? error) };
  } finally {
    box.close();
    if (!taken) await invoke('ocr_discard', { job }).catch(() => {});
    current = null;
  }
  if (status.state === 'hasText') {
    const [pages, total] = String(status.message || '').split(/\s+/);
    const again = await confirmDialog({
      title: 'Boken har redan text',
      message: `${pages && total ? `${pages} av ${total} sidor` : 'Sidorna'} har redan text. Kommer den från en tidigare `
        + 'OCR-läsning kan Sensus läsa om sidorna och lägga texten i spaltordning i en ny fil. Är texten bokens egen '
        + '(en PDF som inte är skannad) behövs det inte.',
      confirm: 'Läs om sidorna',
    });
    if (again) await run(book, true);
  } else if (status.state === 'missing') {
    await showMissing({ saknas: [status.message] });
  } else if (status.state === 'cancelled') {
    toast('Gör sökbar avbröts. Inga filer blev kvar.');
  } else {
    toast(`Gör sökbar gick inte (${status.message || 'okänt fel'}).`, 12);
  }
}
