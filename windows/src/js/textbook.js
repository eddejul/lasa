// Textfiler (txt och md) blir enkla HTML-kapitel som visas i samma läsare som EPUB (foliate-js).
// Samma regler som App/Books/TextBookConverter.swift på iPaden: kapitel vid rubriker, annars ungefär
// var 60 000:e tecken, och radbruten text (som i Projekt Runeberg) slås ihop till stycken.

const MAX_CHAPTER_CHARACTERS = 60000;

/** UTF-8 först, sedan UTF-16 med BOM, sedan Windows-1252 (vanligt i äldre svenska textfiler). */
export function decodeText(bytes) {
  let text = null;
  if ((bytes[0] === 0xff && bytes[1] === 0xfe) || (bytes[0] === 0xfe && bytes[1] === 0xff)) {
    try {
      text = new TextDecoder(bytes[0] === 0xff ? 'utf-16le' : 'utf-16be', { fatal: true }).decode(bytes);
    } catch {
      text = null;
    }
  }
  if (text === null) {
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      text = new TextDecoder('windows-1252').decode(bytes);
    }
  }
  return text.startsWith('﻿') ? text.slice(1) : text;
}

export function escapeHtml(text) {
  return String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

const STYLE = `
body { font-family: Georgia, "Iowan Old Style", serif; line-height: 1.5; text-align: justify; hyphens: auto; }
p { margin: 0 0 0.6em 0; }
h1, h2, h3, h4, h5, h6 { line-height: 1.25; text-align: left; hyphens: manual; margin: 1.2em 0 0.6em 0; }
h1 { font-size: 1.6em; }
h2 { font-size: 1.35em; }
h3 { font-size: 1.15em; }
body > h1:first-child, body > h2:first-child { margin-top: 0.3em; }
pre { white-space: pre-wrap; font-family: Consolas, monospace; font-size: 0.85em; text-align: left; }
code { font-family: Consolas, monospace; font-size: 0.9em; }
blockquote { margin: 0.8em 1.2em; font-style: italic; }
ul, ol { margin: 0 0 0.6em 0; padding-left: 1.4em; }
hr { border: none; border-top: 1px solid currentColor; opacity: 0.3; margin: 1.2em 0; }
`;

function page(title, language, body) {
  return `<!DOCTYPE html>
<html lang="${language}">
<head>
<meta charset="utf-8"/>
<title>${escapeHtml(title)}</title>
<style>${STYLE}</style>
</head>
<body>
${body}
</body>
</html>`;
}

// Vanlig text

const CHAPTER_WORDS = /^(kapitel|chapter|del|part|avsnitt|bok|book|prolog|epilog|prologue|epilogue|förord|efterord|inledning|appendix|bilaga)\b/iu;
const ROMAN = /^[IVXLC]{1,8}\.?$/;

/** En rad som ser ut som en kapitelrubrik: "KAPITEL 3", "Del två", "IV", eller kort och bara versaler. */
function isHeading(line) {
  const length = Array.from(line).length;
  if (length > 60) return false;
  if (CHAPTER_WORDS.test(line) || ROMAN.test(line)) return true;
  const letters = Array.from(line).filter((c) => /\p{L}/u.test(c));
  return letters.length >= 4 && length <= 40 && !letters.some((c) => /\p{Ll}/u.test(c)) && !line.endsWith('.');
}

function plainBlocks(text) {
  const lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').map((line) => line.trim());
  const filled = lines.filter((line) => line);
  const wrapped = filled.filter((line) => line.length >= 45 && line.length <= 90).length;
  const hardWrapped = filled.length >= 10 && filled.length < lines.length && wrapped / Math.max(filled.length, 1) > 0.5;

  const blocks = [];
  let paragraph = [];
  const emit = (line) => {
    if (isHeading(line)) blocks.push({ level: 2, title: line, html: escapeHtml(line), length: line.length });
    else blocks.push({ level: 0, title: '', html: `<p>${escapeHtml(line)}</p>`, length: line.length });
  };
  const flush = () => {
    if (!paragraph.length) return;
    if (hardWrapped) {
      if (paragraph.length === 1) emit(paragraph[0]);
      else {
        const joined = paragraph.join(' ');
        blocks.push({ level: 0, title: '', html: `<p>${escapeHtml(joined)}</p>`, length: joined.length });
      }
    } else paragraph.forEach(emit);
    paragraph = [];
  };
  for (const line of lines) {
    if (!line) flush();
    else paragraph.push(line);
  }
  flush();
  return blocks;
}

// Markdown: rubriker, stycken, listor, citat, kodblock, linjer, fetstil, kursiv och länkar.

const INLINE_RULES = [
  [/`([^`]+)`/g, '<code>$1</code>'],
  [/!\[([^\]]*)\]\([^)]*\)/g, '$1'],
  [/\[([^\]]+)\]\((https?:\/\/[^)\s]+)[^)]*\)/g, '<a href="$2">$1</a>'],
  [/\[([^\]]+)\]\([^)]*\)/g, '$1'],
  [/\*\*([^*]+)\*\*/g, '<strong>$1</strong>'],
  [/__([^_]+)__/g, '<strong>$1</strong>'],
  [/\*([^*\s][^*]*)\*/g, '<em>$1</em>'],
  [/(^|[^A-Za-z0-9])_([^_\s][^_]*)_(?=[^A-Za-z0-9]|$)/g, '$1<em>$2</em>'],
];

function inline(text) {
  let result = escapeHtml(text);
  for (const [pattern, replacement] of INLINE_RULES) result = result.replace(pattern, replacement);
  return result;
}

const plain = (text) => text.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '').replaceAll('*', '');

function markdownHeading(line) {
  const hashes = line.length - line.replace(/^#+/, '').length;
  if (hashes < 1 || hashes > 6) return null;
  const rest = line.slice(hashes);
  if (rest && rest[0] !== ' ') return null;
  const text = rest.trim().replace(/#+$/, '').trim();
  return text ? { level: hashes, text } : null;
}

function isRule(line) {
  const compact = line.replaceAll(' ', '');
  return compact.length >= 3 && '-*_'.includes(compact[0]) && [...compact].every((c) => c === compact[0]);
}

function listItem(line) {
  if ('-*+'.includes(line[0]) && line[1] === ' ') return { ordered: false, text: line.slice(2).trim() };
  const match = /^(\d{1,3})([.)]) (.*)$/.exec(line);
  return match ? { ordered: true, text: match[3].trim() } : null;
}

function markdownBlocks(text) {
  const lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  const blocks = [];
  let paragraph = [];
  let index = 0;
  const flushParagraph = () => {
    if (!paragraph.length) return;
    const joined = paragraph.join(' ');
    blocks.push({ level: 0, title: '', html: `<p>${inline(joined)}</p>`, length: joined.length });
    paragraph = [];
  };
  while (index < lines.length) {
    const trimmed = lines[index].trim();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      flushParagraph();
      const fence = trimmed.slice(0, 3);
      const code = [];
      index += 1;
      while (index < lines.length && !lines[index].trim().startsWith(fence)) code.push(lines[index++]);
      index += 1;
      const joined = code.join('\n');
      blocks.push({ level: 0, title: '', html: `<pre><code>${escapeHtml(joined)}</code></pre>`, length: joined.length });
      continue;
    }
    if (!trimmed) {
      flushParagraph();
      index += 1;
      continue;
    }
    const heading = markdownHeading(trimmed);
    if (heading) {
      flushParagraph();
      blocks.push({ level: heading.level, title: plain(heading.text), html: inline(heading.text), length: heading.text.length });
      index += 1;
      continue;
    }
    if (isRule(trimmed)) {
      flushParagraph();
      blocks.push({ level: 0, title: '', html: '<hr/>', length: 0 });
      index += 1;
      continue;
    }
    if (trimmed.startsWith('>')) {
      flushParagraph();
      const quote = [];
      while (index < lines.length && lines[index].trim().startsWith('>')) {
        quote.push(lines[index].trim().slice(1).trim());
        index += 1;
      }
      const joined = quote.filter((q) => q).join(' ');
      blocks.push({ level: 0, title: '', html: `<blockquote><p>${inline(joined)}</p></blockquote>`, length: joined.length });
      continue;
    }
    const first = listItem(trimmed);
    if (first) {
      flushParagraph();
      const items = [first.text];
      index += 1;
      while (index < lines.length) {
        const raw = lines[index];
        const line = raw.trim();
        if (!line) break;
        const item = listItem(line);
        if (item && item.ordered === first.ordered) items.push(item.text);
        else if (raw.startsWith(' ') || raw.startsWith('\t')) items[items.length - 1] += ' ' + line;
        else break;
        index += 1;
      }
      const tag = first.ordered ? 'ol' : 'ul';
      blocks.push({ level: 0, title: '', html: `<${tag}>${items.map((i) => `<li>${inline(i)}</li>`).join('')}</${tag}>`,
        length: items.reduce((sum, i) => sum + i.length, 0) });
      continue;
    }
    paragraph.push(trimmed);
    index += 1;
  }
  flushParagraph();
  return blocks;
}

/** Gör om en textfil till kapitel och innehållsförteckning. */
export function convertText(bytes, { title, ext, language = 'sv' }) {
  const text = decodeText(bytes);
  const blocks = ext === 'md' ? markdownBlocks(text) : plainBlocks(text);
  const chapters = [];
  const toc = [];
  let body = '';
  let length = 0;
  let headingNumber = 0;
  const splitLevel = blocks.some((b) => b.level === 1) ? 1 : 2;
  const flush = () => {
    if (!body) return;
    chapters.push({ html: page(title, language, body), size: Math.max(length, 1) });
    body = '';
    length = 0;
  };
  for (const block of blocks) {
    if (block.level) {
      if (block.level <= splitLevel) flush();
      headingNumber += 1;
      const id = `rubrik-${headingNumber}`;
      if (block.level <= 2 && block.title) {
        toc.push({ label: block.title, chapter: chapters.length, fragment: body ? id : null, level: Math.max(block.level - splitLevel, 0) });
      }
      body += `<h${block.level} id="${id}">${block.html}</h${block.level}>\n`;
      length += block.length;
    } else {
      if (length > MAX_CHAPTER_CHARACTERS) flush();
      body += block.html + '\n';
      length += block.length;
    }
  }
  flush();
  if (!chapters.length) chapters.push({ html: page(title, language, '<p></p>'), size: 1 });
  return { chapters, toc, text };
}

/** En bok i den form som foliate-js läser (samma gränssnitt som dess EPUB-objekt). */
export function makeTextBook(bytes, { title, ext }) {
  const { chapters, toc } = convertText(bytes, { title, ext });
  const urls = [];
  const sections = chapters.map((chapter, index) => ({
    id: `kapitel-${index + 1}`,
    linear: 'yes',
    size: chapter.size,
    load: () => {
      urls[index] ??= URL.createObjectURL(new Blob([chapter.html], { type: 'text/html' }));
      return urls[index];
    },
    unload: () => {
      if (urls[index]) URL.revokeObjectURL(urls[index]);
      urls[index] = null;
    },
    createDocument: () => new DOMParser().parseFromString(chapter.html, 'text/html'),
  }));

  // Rubriker på nivå 2 under en rubrik på nivå 1 blir underpunkter.
  const items = [];
  for (const entry of toc) {
    const item = { label: entry.label, href: `kapitel-${entry.chapter + 1}${entry.fragment ? '#' + entry.fragment : ''}` };
    if (entry.level > 0 && items.length) (items[items.length - 1].subitems ??= []).push(item);
    else items.push(item);
  }

  const split = (href) => {
    const [id, fragment] = String(href).split('#');
    return [id, fragment ?? null];
  };
  return {
    sections,
    toc: items,
    metadata: { title, language: 'sv' },
    dir: 'ltr',
    rendition: { layout: 'reflowable' },
    splitTOCHref: split,
    getTOCFragment: (doc, id) => doc.getElementById(id),
    resolveHref: (href) => {
      const [id, fragment] = split(href);
      const index = sections.findIndex((section) => section.id === id);
      if (index < 0) return null;
      return { index, anchor: (doc) => (fragment ? doc.getElementById(fragment) : 0) };
    },
    isExternal: (href) => /^\w+:/.test(href),
  };
}
