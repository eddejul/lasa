// Enhetstester för textfilerna: RTF-läsaren (samma regler som App/Books/RTFText.swift).
//   node --test windows/tests/textbook.test.mjs

import assert from 'node:assert/strict';
import test from 'node:test';

import { convertText, rtfPlainText } from '../src/js/textbook.js';

const bytes = (text) => Uint8Array.from(text, (c) => c.charCodeAt(0));

test('RTF: stycken, åäö som \\\'hh och tabeller som hoppas över', () => {
  const rtf = "{\\rtf1\\ansi\\ansicpg1252{\\fonttbl{\\f0 Times;}}{\\colortbl;\\red0;}\\f0 {\\b Rubrik}\\par "
    + "Det var en klar morgon i b\\'f6rjan av september \\emdash  slut.\\par}";
  assert.equal(rtfPlainText(bytes(rtf)), 'Rubrik\nDet var en klar morgon i början av september — slut.\n');
});

test('RTF: \\u med ersättningstecken, \\~ och grupper med \\*', () => {
  const rtf = '{\\rtf1\\uc1 caf\\u233?\\~x{\\*\\generator Word;}y\\u-3913?z}';
  assert.equal(rtfPlainText(bytes(rtf)), 'café xyz');
});

test('RTF: \\\\, \\{ och \\} är tecknen själva, radbrytningar i filen räknas inte', () => {
  const rtf = '{\\rtf1 a\\\\b\\{c\\}\r\nd\\tab e}';
  assert.equal(rtfPlainText(bytes(rtf)), 'a\\b{c}d\te');
});

test('RTF blir kapitel med stycken', () => {
  const rtf = '{\\rtf1 F\\\'f6rsta stycket.\\par Andra stycket.\\par}';
  const { chapters } = convertText(bytes(rtf), { title: 'Prov', ext: 'rtf' });
  assert.equal(chapters.length, 1);
  assert.match(chapters[0].html, /<p>Första stycket\.<\/p>/);
  assert.match(chapters[0].html, /<p>Andra stycket\.<\/p>/);
});
