// Ordet och meningen runt det, ur en sidas text. Samma regler som på iPaden:
// App/Dictionary/PDFWordFinder.swift (PDF) och ReflowValues.sentence i App/Reader/ReflowRenderer.swift (EPUB).
// Positionerna räknas i UTF-16, som NSString på iPaden, så att samma text ger samma svar.

const HYPHENS = new Set([0x2d, 0xad, 0x2010, 0x2011]);
const APOSTROPHES = new Set([0x27, 0x2019]);
const SENTENCE_ENDS = new Set([0x2e, 0x21, 0x3f, 0x2026]); // . ! ? …
const MAX_SENTENCE_LENGTH = 320;
// Bokstäver, tecken som hör till en bokstav (accenter) och siffror, som CharacterSet.letters,
// .nonBaseCharacters och .decimalDigits.
const WORD_CHARACTER = /^[\p{L}\p{M}\p{Nd}]$/u;

export function isWordCharacter(text, index) {
  if (index < 0 || index >= text.length) return false;
  const code = text.charCodeAt(index);
  if (code >= 0xd800 && code <= 0xdfff) return false;
  return WORD_CHARACTER.test(text[index]);
}

/** Bindestreck eller apostrof inne i ett ord, med bokstäver på båda sidor (e-post, don't). */
function isInnerJoiner(text, index) {
  if (index <= 0 || index + 1 >= text.length) return false;
  const code = text.charCodeAt(index);
  if (!HYPHENS.has(code) && !APOSTROPHES.has(code)) return false;
  return isWordCharacter(text, index - 1) && isWordCharacter(text, index + 1);
}

function isLineBreak(code) {
  return code === 0x0a || code === 0x0d || code === 0x2028 || code === 0x2029;
}

function isSpace(code) {
  return code === 0x20 || code === 0x09 || isLineBreak(code) || code === 0xa0;
}

/** Hela ordet runt ett tecken: [början, slut). */
export function wordRange(text, index) {
  let start = index;
  while (start > 0 && (isWordCharacter(text, start - 1) || isInnerJoiner(text, start - 1))) start -= 1;
  let end = index + 1;
  while (end < text.length && (isWordCharacter(text, end) || isInnerJoiner(text, end))) end += 1;
  return [start, end];
}

/** Ordets andra halva efter ett avstavningsstreck och en radbrytning ("kun-" och "skap"). PDF:er skriver
 *  ibland radbrytningen som ett mellanslag, så det räcker med blanktecken. */
function continuation(end, text) {
  if (end >= text.length || !HYPHENS.has(text.charCodeAt(end))) return null;
  let index = end + 1;
  while (index < text.length && isSpace(text.charCodeAt(index))) index += 1;
  if (!(index > end + 1 || text.charCodeAt(end) === 0xad)) return null;
  if (index >= text.length || !isWordCharacter(text, index)) return null;
  const start = index;
  while (index < text.length && (isWordCharacter(text, index) || isInnerJoiner(text, index))) index += 1;
  return [start, index];
}

/** Ordets första halva före en radbrytning, om ordet man klickade på är andra halvan. */
function beginning(start, text) {
  let index = start - 1;
  while (index >= 0 && isSpace(text.charCodeAt(index))) index -= 1;
  if (!(index > 0 && HYPHENS.has(text.charCodeAt(index)))) return null;
  if (!(index < start - 1 || text.charCodeAt(index) === 0xad)) return null;
  const end = index;
  index -= 1;
  if (index < 0 || !isWordCharacter(text, index)) return null;
  while (index > 0 && (isWordCharacter(text, index - 1) || isInnerJoiner(text, index - 1))) index -= 1;
  return [index, end];
}

/** Meningen runt ordet: bakåt till förra punkten och framåt till nästa, högst 320 tecken. */
function surroundingSentence(first, last, text) {
  let start = first;
  const earliest = Math.max(0, first - MAX_SENTENCE_LENGTH / 2);
  while (start > earliest) {
    const code = text.charCodeAt(start - 1);
    if (SENTENCE_ENDS.has(code) && start < text.length && isSpace(text.charCodeAt(start))) break;
    if (isLineBreak(code) && start >= 2 && isLineBreak(text.charCodeAt(start - 2))) break;
    start -= 1;
  }
  let end = last;
  const latest = Math.min(text.length, last + MAX_SENTENCE_LENGTH / 2);
  while (end < latest) {
    const code = text.charCodeAt(end);
    end += 1;
    if (SENTENCE_ENDS.has(code) && (end >= text.length || isSpace(text.charCodeAt(end)))) break;
    if (isLineBreak(code) && end < text.length && isLineBreak(text.charCodeAt(end))) break;
  }
  return [start, end];
}

/** Texten på en rad: avstavningar ihop, radbrytningar och dubbla mellanslag blir ett mellanslag. */
function clean(text) {
  let result = text.replaceAll('­', '');
  for (const hyphen of ['-', '‐', '‑']) {
    result = result.replaceAll(hyphen + '\r\n', '').replaceAll(hyphen + '\n', '');
  }
  result = result.split(/\s+/u).filter((part) => part).join(' ');
  if (/^\s/u.test(text)) result = ' ' + result;
  if (/\s$/u.test(text) && !result.endsWith(' ')) result += ' ';
  return result;
}

/**
 * Ordet som innehåller tecknet `index` i sidans text, eller null om tecknet inte hör till ett ord.
 * Svaret har formerna att slå upp i tur och ordning (ett avstavat ord över en radbrytning först
 * ihopslaget, sedan med bindestreck, sist bara delen man klickade på), meningen på en rad och var
 * ordet står i meningen, och delarna [början, slut) i sidans text för markeringen.
 */
export function wordInPageText(text, index) {
  if (!isWordCharacter(text, index)) return null;
  const core = wordRange(text, index);
  const parts = [core];
  const next = continuation(core[1], text);
  if (next) parts.push(next);
  else {
    const previous = beginning(core[0], text);
    if (previous) parts.unshift(previous);
  }
  const pieces = parts.map(([a, b]) => text.slice(a, b));
  const joined = pieces.join('');
  if (!/\p{L}/u.test(joined)) return null;
  const candidates = [joined];
  if (parts.length > 1) {
    candidates.push(pieces.join('-'));
    candidates.push(text.slice(core[0], core[1]));
  }
  if (joined.includes('-')) {
    // Ett bindestreck mitt i raden kan vara en avstavning som PDF:en har tappat radbrytningen för.
    candidates.push(joined.replaceAll('-', ''));
  }

  const first = parts[0][0];
  const last = parts[parts.length - 1][1];
  const [sentenceStart, sentenceEnd] = surroundingSentence(first, last, text);
  const before = clean(text.slice(sentenceStart, first));
  const after = clean(text.slice(last, sentenceEnd));
  // Ordet börjar med en bokstav, så mellanslag först i meningen kommer bara från texten före.
  const leading = before.length - before.replace(/^ +/, '').length;
  const sentence = (before + joined + after).slice(leading).trim();
  return {
    location: core[0],
    candidates: [...new Set(candidates)],
    sentence,
    rangeInSentence: [before.length - leading, joined.length],
    parts,
  };
}

/** Meningen runt ett ord i en EPUB eller textfil, ur texten före och efter ordet i samma stycke.
 *  Samma som ReflowValues.sentence på iPaden. Ger [mening, [början, längd]]. */
export function sentenceAround(before, word, after) {
  const ends = new Set(['.', '!', '?', '…']);
  const head = Array.from(before);
  let start = 0;
  for (let k = head.length - 2; k >= 0; k--) {
    if (ends.has(head[k]) && head[k + 1] === ' ') {
      start = k + 2;
      break;
    }
  }
  const lead = head.slice(start).join('').replace(/^ +/, '');
  const tail = Array.from(after);
  let end = tail.length;
  for (let index = 0; index < tail.length; index++) {
    if (ends.has(tail[index]) && (index + 1 === tail.length || tail[index + 1] === ' ')) {
      end = index + 1;
      break;
    }
  }
  const sentence = (lead + word + tail.slice(0, end).join('')).replace(/ +$/, '');
  return [sentence, [lead.length, word.length]];
}

/** Formerna att slå upp för ett ord ur en EPUB: ordet, och utan bindestreck om det har ett. */
export function reflowCandidates(word) {
  const candidates = [word];
  if (word.includes('-')) candidates.push(word.replaceAll('-', ''));
  return candidates;
}
