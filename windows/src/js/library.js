// Biblioteket: lista, lägg till (knapp eller dra in filer) och ta bort.
// Filerna kopieras in i appens egen mapp och heter efter SHA-256 av innehållet (gemener, 64 tecken), samma
// kontrollsumma som iPaden använder för synken. Varje bok har dessutom ett eget id som aldrig ändras (G3).

import { deleteBookFile, storeBookFile } from './backend.js';
import { bookErrorMessage, isUnreadable, unreadable } from './bookerrors.js';
import { closePdf, openPdf } from './pdfjs.js';
import { matchFile, uniqueName } from './bookmatch.js';
import { addBook, bookRegistry, contentId, listBooks, markBookMissing, restoreBook, setBookFile } from './store.js';
import { htmlTitle } from './textbook.js';
import { choiceDialog, confirmDialog, el, replace, statusBox, toast } from './ui.js';

// Samma filtyper som på iPaden: PDF, EPUB och text (txt, md, rtf, html).
export const ACCEPTED = ['pdf', 'epub', 'txt', 'md', 'rtf', 'html'];
export const ACCEPT_ATTRIBUTE = '.pdf,.epub,.txt,.md,.markdown,.rtf,.html,.htm';
const TEXT_FORMATS = ['txt', 'md', 'rtf', 'html'];

export function extensionOf(name) {
  const ext = String(name).split('.').pop().toLowerCase();
  if (ext === 'markdown') return 'md';
  if (ext === 'htm') return 'html';
  return ext;
}

export async function sha256(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

const stripExtension = (name) => String(name).replace(/\.[^.]+$/, '');

function textOf(value) {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(textOf).filter((t) => t).join(', ');
  if (typeof value === 'object') {
    if ('name' in value) return textOf(value.name);
    const values = Object.values(value);
    return values.length ? textOf(values[0]) : '';
  }
  return String(value);
}

const COVER_WIDTH = 240;

/** En liten JPEG av en bild eller canvas, för omslaget i biblioteket. */
function thumbnail(source, width, height) {
  const scale = COVER_WIDTH / width;
  const canvas = document.createElement('canvas');
  canvas.width = COVER_WIDTH;
  canvas.height = Math.round(height * scale);
  const context = canvas.getContext('2d');
  context.fillStyle = '#ffffff';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL('image/jpeg', 0.82);
}

async function pdfCover(pdf) {
  const page = await pdf.getPage(1);
  const base = page.getViewport({ scale: 1 });
  const viewport = page.getViewport({ scale: (COVER_WIDTH * 1.5) / base.width });
  const canvas = document.createElement('canvas');
  canvas.width = Math.floor(viewport.width);
  canvas.height = Math.floor(viewport.height);
  await page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport }).promise;
  return thumbnail(canvas, canvas.width, canvas.height);
}

async function blobCover(blob) {
  const url = URL.createObjectURL(blob);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    if (!image.naturalWidth) return '';
    return thumbnail(image, image.naturalWidth, image.naturalHeight);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** Titel, författare och omslag ur filen. Titeln blir filnamnet om filen inte har någon.
 *  En PDF tas över av pdf.js (bytes går inte att använda efteråt), så att boken inte kopieras.
 *  Kastar ett fel bara om filen aldrig kommer att gå att öppna (låst eller trasig, se bookerrors.js). */
async function readMetadata(bytes, ext, fileName) {
  const result = { title: stripExtension(fileName), author: '', cover: '' };
  try {
    if (ext === 'pdf') {
      const pdf = await openPdf(bytes);
      try {
        const { info } = await pdf.getMetadata();
        result.title = (info?.Title || '').trim() || result.title;
        result.author = (info?.Author || '').trim();
        result.cover = await pdfCover(pdf).catch(() => '');
      } finally {
        await closePdf(pdf);
      }
    } else if (ext === 'epub') {
      const { makeBook } = await import('../vendor/foliate-js/view.js');
      let book;
      try {
        book = await makeBook(new File([bytes], 'bok.epub', { type: 'application/epub+zip' }));
      } catch (error) {
        console.warn(error);
        throw unreadable('filen är trasig eller ingen riktig EPUB, så den går inte att öppna.');
      }
      result.title = textOf(book.metadata?.title).trim() || result.title;
      result.author = textOf(book.metadata?.author).trim();
      const cover = await Promise.resolve(book.getCover?.()).catch(() => null);
      if (cover) result.cover = await blobCover(cover).catch(() => '');
      book.destroy?.();
    } else if (ext === 'html') {
      result.title = htmlTitle(bytes) || result.title;
    }
  } catch (error) {
    if (isUnreadable(error)) throw error;
    console.warn('Kunde inte läsa bokens uppgifter', error);
  }
  return result;
}

const sameName = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

/** Frågan när en annan bok i biblioteket heter likadant (som på iPaden, BookImporter.swift). */
function askNameTaken(name) {
  return choiceDialog({
    title: `Det finns redan en bok som heter ${name}`,
    message: 'Ersätt den, eller behåll båda? Ersätter du den kan markeringar, anteckningar och läsposition följa med till den nya filen.',
    choices: [
      { label: 'Ersätt och behåll markeringarna', value: 'keep', kind: 'primary' },
      { label: 'Ersätt och börja om', value: 'startOver', kind: 'danger' },
      { label: 'Behåll båda', value: 'both' },
      { label: 'Avbryt', value: 'cancel' },
    ],
  });
}

/** Ny version av boken, behåll markeringarna? (som på iPaden, LibraryViewController.swift). */
function askNewVersion(name, old) {
  const message = sameName(name, old)
    ? `${name} är en ny version av en bok som du tagit bort ur biblioteket. Ska markeringar, anteckningar och läsposition följa med?`
    : `${name} liknar ${old}, som du tagit bort ur biblioteket. Ska markeringar, anteckningar och läsposition följa med?`;
  return choiceDialog({
    title: 'Ny version av boken',
    message,
    choices: [
      { label: 'Behåll markeringarna', value: 'keep', kind: 'primary' },
      { label: 'Nej, börja om', value: 'new' },
    ],
  });
}

/** Lägger till filer i biblioteket. Ger antalet nya (eller nya versioner av) böcker. Medan filerna läses in
 *  visas hur långt det har kommit ("Lägger till 3 av 7"). Varje fil jämförs med bokregistret (G3,
 *  bookmatch.js): samma innehåll läggs inte till igen, ett upptaget namn ger frågan Ersätt eller Behåll båda,
 *  och en bok som tagits bort kommer tillbaka med markeringar och läsposition. */
export async function importFiles(files, { ids = null } = {}) {
  let added = 0;
  const list = [...files];
  const status = list.length ? statusBox() : null;
  for (const [index, file] of list.entries()) {
    status?.set(list.length > 1 ? `Lägger till ${index + 1} av ${list.length}: ${file.name}` : `Lägger till ${file.name} ...`);
    const ext = extensionOf(file.name);
    if (!ACCEPTED.includes(ext)) {
      toast(`${file.name} kan inte läsas. Sensus tar PDF, EPUB och text (txt, md, rtf, html).`);
      continue;
    }
    let stored = null;
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      const size = bytes.length;
      const hash = await sha256(bytes);
      const modified = Math.floor((file.lastModified || 0) / 1000);
      const records = await bookRegistry();
      const match = matchFile({ name: file.name, sha256: hash }, records);
      if (match.kind === 'exists') {
        if (ids) ids.push(match.book.id);
        else toast(sameName(match.book.fileName, file.name) ? `${file.name} finns redan i biblioteket.`
          : `${file.name} finns redan i biblioteket som ${match.book.fileName}.`);
        continue;
      }
      let action = match.kind === 'restore' ? 'restore' : 'new';
      let fileName = file.name;
      if (match.kind === 'nameTaken') {
        action = await askNameTaken(file.name);
        if (!action || action === 'cancel') continue;
        if (action === 'both') fileName = uniqueName(file.name, records);
      } else if (match.kind === 'newVersion') {
        action = await askNewVersion(file.name, match.book.fileName);
        if (!action) continue;
      }
      // Filen sparas först, eftersom pdf.js tar över byten när titel och omslag läses. Den heter efter
      // kontrollsumman (<sha256>.<ext>), bokens id står bara i databasen.
      await storeBookFile(hash, ext, bytes);
      stored = { id: hash, ext };
      let id = match.book?.id;
      if (action === 'restore') {
        await restoreBook(id, file.name, modified);
      } else {
        const meta = await readMetadata(bytes, ext, fileName);
        const book = { title: meta.title, author: meta.author, format: TEXT_FORMATS.includes(ext) ? 'text' : ext, ext,
          fileName, size, cover: meta.cover, sha256: hash, modified };
        if (action === 'keep') {
          // Ny version med samma id: markeringar, anteckningar och läsposition följer med.
          await setBookFile(id, book);
          if (contentId(match.book) !== hash) await deleteBookFile(contentId(match.book), match.book.ext).catch(() => {});
        } else {
          id = crypto.randomUUID().toLowerCase();
          await addBook({ id, ...book });
          if (action === 'startOver') {
            // Ersätt och börja om: den gamla boken tas bort ur biblioteket (raden och markeringarna finns kvar).
            await markBookMissing(match.book.id);
            await deleteBookFile(contentId(match.book), match.book.ext).catch(() => {});
          }
        }
      }
      stored = null;
      added += 1;
      ids?.push(id);
    } catch (error) {
      console.error(error);
      toast(isUnreadable(error) ? bookErrorMessage(error, file.name)
        : `${file.name} kunde inte läggas till (${error?.message ?? error}).`);
      if (stored) await deleteBookFile(stored.id, stored.ext).catch(() => {});
    }
  }
  status?.close();
  if (added) toast(added === 1 ? 'En bok lades till.' : `${added} böcker lades till.`);
  return added;
}

const FORMAT_NAMES = { pdf: 'PDF', epub: 'EPUB', text: 'Text' };

function progressText(book) {
  if (!book.opened) return 'Inte öppnad än';
  const percent = Math.round((book.progress || 0) * 100);
  return percent >= 100 ? 'Utläst' : `${percent} % läst`;
}

/** Ritar biblioteket i `container`. onOpen(id) öppnar en bok. */
export async function renderLibrary(container, { onOpen }) {
  const books = await listBooks();
  if (!books.length) {
    replace(container, el('div', { class: 'empty' },
      el('p', {}, 'Inga böcker än.'),
      el('p', {}, 'Klicka på Lägg till böcker (Ctrl och O), eller dra in PDF-, EPUB- eller textfiler (txt, md, rtf, html) i fönstret.')));
    return;
  }
  // Två böcker med samma titel (Behåll båda) visar filnamnet under titeln.
  const titles = books.map((book) => book.title);
  const twice = new Set(titles.filter((title, index) => titles.indexOf(title) !== index));
  const cards = books.map((book) => el('div', { class: 'book-card', dataset: { testid: 'book', id: book.id, sha256: contentId(book) } },
    el('button', { class: `book-cover format-${book.format}${book.cover ? ' has-image' : ''}`, onclick: () => onOpen(book.id),
      title: `Öppna ${book.title}` },
    book.cover ? el('img', { class: 'book-cover-image', src: book.cover, alt: '' }) : null,
    el('span', { class: 'book-format' }, FORMAT_NAMES[book.format] ?? book.format),
    book.cover ? null : el('span', { class: 'book-cover-title' }, book.title)),
    el('div', { class: 'book-info' },
      el('button', { class: 'book-title', onclick: () => onOpen(book.id) }, book.title),
      book.author ? el('div', { class: 'book-author' }, book.author) : null,
      twice.has(book.title) ? el('div', { class: 'book-file', dataset: { testid: 'book-file' } }, book.fileName) : null,
      el('div', { class: 'book-progress' },
        el('div', { class: 'progress-bar' }, el('div', { class: 'progress-fill', style: `width: ${Math.round((book.progress || 0) * 100)}%` })),
        el('span', {}, progressText(book))),
      el('button', { class: 'link-button danger', onclick: async () => {
        const ok = await confirmDialog({ title: `Ta bort ${book.title}?`,
          message: 'Boken tas bort ur Sensus. Originalfilen där du hämtade den finns kvar, och sparade ord ligger kvar. '
            + 'Lägger du till samma bok igen, eller en ny version av den, kommer markeringar och läsposition tillbaka.',
          confirm: 'Ta bort', danger: true });
        if (!ok) return;
        await deleteBookFile(contentId(book), book.ext);
        await markBookMissing(book.id);
        renderLibrary(container, { onOpen });
      } }, 'Ta bort'))));
  replace(container, el('div', { class: 'book-grid' }, cards));
}
