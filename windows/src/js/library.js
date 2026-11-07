// Biblioteket: lista, lägg till (knapp eller dra in filer) och ta bort.
// Filerna kopieras in i appens egen mapp. Varje bok får ett id som är SHA-256 av filens innehåll
// (gemener, 64 tecken), samma id som iPaden använder för synken i fas 6.

import { deleteBookFile, storeBookFile } from './backend.js';
import { closePdf, openPdf } from './pdfjs.js';
import { addBook, getBook, listBooks, removeBook } from './store.js';
import { confirmDialog, el, replace, toast } from './ui.js';

export const ACCEPTED = ['pdf', 'epub', 'txt', 'md'];
export const ACCEPT_ATTRIBUTE = '.pdf,.epub,.txt,.md,.markdown';

export function extensionOf(name) {
  const ext = String(name).split('.').pop().toLowerCase();
  return ext === 'markdown' ? 'md' : ext;
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

/** Titel, författare och omslag ur filen. Titeln blir filnamnet om filen inte har någon. */
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
      const book = await makeBook(new File([bytes], 'bok.epub', { type: 'application/epub+zip' }));
      result.title = textOf(book.metadata?.title).trim() || result.title;
      result.author = textOf(book.metadata?.author).trim();
      const cover = await Promise.resolve(book.getCover?.()).catch(() => null);
      if (cover) result.cover = await blobCover(cover).catch(() => '');
      book.destroy?.();
    }
  } catch (error) {
    console.warn('Kunde inte läsa bokens uppgifter', error);
  }
  return result;
}

/** Lägger till filer i biblioteket. Ger antalet nya böcker. */
export async function importFiles(files) {
  let added = 0;
  for (const file of files) {
    const ext = extensionOf(file.name);
    if (!ACCEPTED.includes(ext)) {
      toast(`${file.name} kan inte läsas. Läsa tar PDF, EPUB, txt och md.`);
      continue;
    }
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      const id = await sha256(bytes);
      if (await getBook(id)) {
        toast(`${file.name} finns redan i biblioteket.`);
        continue;
      }
      const meta = await readMetadata(bytes, ext, file.name);
      await storeBookFile(id, ext, bytes);
      await addBook({ id, title: meta.title, author: meta.author, format: ext === 'md' || ext === 'txt' ? 'text' : ext,
        ext, fileName: file.name, size: bytes.length, cover: meta.cover });
      added += 1;
    } catch (error) {
      console.error(error);
      toast(`${file.name} kunde inte läggas till (${error?.message ?? error}).`);
    }
  }
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
      el('p', {}, 'Klicka på Lägg till böcker, eller dra in PDF-, EPUB- eller textfiler (txt, md) i fönstret.')));
    return;
  }
  const cards = books.map((book) => el('div', { class: 'book-card', dataset: { testid: 'book', id: book.id } },
    el('button', { class: `book-cover format-${book.format}${book.cover ? ' has-image' : ''}`, onclick: () => onOpen(book.id),
      title: `Öppna ${book.title}` },
    book.cover ? el('img', { class: 'book-cover-image', src: book.cover, alt: '' }) : null,
    el('span', { class: 'book-format' }, FORMAT_NAMES[book.format] ?? book.format),
    book.cover ? null : el('span', { class: 'book-cover-title' }, book.title)),
    el('div', { class: 'book-info' },
      el('button', { class: 'book-title', onclick: () => onOpen(book.id) }, book.title),
      book.author ? el('div', { class: 'book-author' }, book.author) : null,
      el('div', { class: 'book-progress' },
        el('div', { class: 'progress-bar' }, el('div', { class: 'progress-fill', style: `width: ${Math.round((book.progress || 0) * 100)}%` })),
        el('span', {}, progressText(book))),
      el('button', { class: 'link-button danger', onclick: async () => {
        const ok = await confirmDialog({ title: `Ta bort ${book.title}?`,
          message: 'Boken och läspositionen tas bort ur Läsa. Originalfilen där du hämtade den finns kvar, och sparade ord ligger kvar.',
          confirm: 'Ta bort', danger: true });
        if (!ok) return;
        await deleteBookFile(book.id, book.ext);
        await removeBook(book.id);
        renderLibrary(container, { onOpen });
      } }, 'Ta bort'))));
  replace(container, el('div', { class: 'book-grid' }, cards));
}
