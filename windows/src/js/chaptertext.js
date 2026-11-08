// Kapitlets text i en EPUB eller textfil, som iPaden räknar den (docs/SYNK.md): all text i body i
// dokumentordning utom i script och style, räknad i UTF-16. Markeringar och sökträffar sparas som
// teckenintervall i den texten, och görs om till en Range i kapitlet när de ska visas.

function skipped(node, root) {
  for (let element = node.parentNode; element && element !== root; element = element.parentNode) {
    const name = element.localName;
    if (name === 'script' || name === 'style') return true;
  }
  return false;
}

/** Textnoderna i kapitlet med var de börjar i kapitlets text. */
export function chapterNodes(doc) {
  const root = doc.body ?? doc.documentElement;
  const nodes = [];
  if (!root) return { root, nodes, text: '' };
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let text = '';
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (skipped(node, root)) continue;
    nodes.push({ node, start: text.length });
    text += node.data;
  }
  return { root, nodes, text };
}

export function chapterText(doc) {
  return chapterNodes(doc).text;
}

/** En Range för [start, end) i kapitlets text, eller null. */
export function rangeFromOffsets(doc, start, end, info = chapterNodes(doc)) {
  const { nodes } = info;
  if (!nodes.length || end <= start) return null;
  const locate = (offset, isEnd) => {
    for (const { node, start: from } of nodes) {
      const to = from + node.data.length;
      if (isEnd ? offset <= to && offset > from : offset < to && offset >= from) return [node, offset - from];
    }
    return null;
  };
  const a = locate(start, false);
  const b = locate(end, true);
  if (!a || !b) return null;
  const range = doc.createRange();
  range.setStart(a[0], a[1]);
  range.setEnd(b[0], b[1]);
  return range;
}

/** [start, end) i kapitlets text för en Range i kapitlet, eller null om den inte ligger i texten. */
export function offsetsFromRange(doc, range, info = chapterNodes(doc)) {
  const position = (container, offset) => {
    if (container.nodeType === Node.TEXT_NODE) {
      const found = info.nodes.find((item) => item.node === container);
      return found ? found.start + offset : null;
    }
    // Gränsen ligger mellan element: ta första textnoden efter den.
    const boundary = doc.createRange();
    boundary.setStart(container, offset);
    for (const item of info.nodes) {
      if (boundary.comparePoint(item.node, 0) >= 0) return item.start;
    }
    return info.text.length;
  };
  const start = position(range.startContainer, range.startOffset);
  const end = position(range.endContainer, range.endOffset);
  if (start === null || end === null || end <= start) return null;
  return { start, end };
}

/** Söker efter en markerings text nära den sparade platsen, när platsen inte stämmer (som på iPaden). */
export function relocate(text, mark) {
  const expected = mark.text ?? '';
  if (!expected) return null;
  const squeeze = (value) => value.replace(/\s+/g, ' ').trim();
  if (squeeze(text.slice(mark.start, mark.start + mark.length)) === squeeze(expected)) {
    return { start: mark.start, end: mark.start + mark.length };
  }
  // Leta efter texten med blanktecken som valfria, närmast den sparade platsen.
  const pattern = new RegExp(squeeze(expected).split(' ').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\s+'), 'g');
  let best = null;
  for (const match of text.matchAll(pattern)) {
    const distance = Math.abs(match.index - mark.start);
    if (!best || distance < best.distance) best = { start: match.index, end: match.index + match[0].length, distance };
  }
  return best ? { start: best.start, end: best.end } : null;
}
