import UIKit

/// En markering på en sidbild i en EPUB eller textfil: vilken markering och var den ligger i sidans koordinater.
struct ReflowMarkRect {
    let id: String
    let rect: CGRect
}

/// Ett textintervall som fingret har dragit över, eller en sökträff, i ett kapitel.
struct ReflowTextRange {
    let start: Int
    let length: Int
    let text: String
    /// Sidan i kapitlet där intervallet börjar (för sökträffar) och rutorna på den sidan.
    let page: Int
    let rects: [CGRect]
}

/// Markeringar, anteckningar och sökning i kapitlens webbvyer (fas 4).
///
/// Kapitlets text räknas som all text i body i dokumentordning, utan skript och stilar, i UTF-16 som i Swift.
/// En markering läggs in som span-element runt texten. Det ändrar inte layouten, bara bakgrunden,
/// så sidantalet är detsamma. Skriptet körs i samma JavaScript-värld som `ReflowStyle.script`.
enum ReflowMarks {

    /// Stilen för markeringarna. Reglerna är mer specifika än temats, som gör alla bakgrunder genomskinliga.
    static var css: String {
        var css = """
        span.lasa-mark { border-radius: 2px; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
        span.lasa-mark.lasa-note {
          text-decoration: underline !important;
          text-decoration-thickness: 2px !important;
          text-underline-offset: 3px !important;
        }

        """
        // O4: dina ord i texten. Helt streck för ord man övar, prickat för ord man kan.
        css += """
        span.lasa-word {
          text-decoration: underline !important;
          text-decoration-color: rgba(128, 120, 108, 0.85) !important;
          text-decoration-thickness: 1.5px !important;
          text-underline-offset: 3px !important;
          -webkit-text-decoration-skip: none;
          text-decoration-skip-ink: none;
        }
        span.lasa-word.lasa-word-known {
          text-decoration-style: dotted !important;
          text-decoration-color: rgba(140, 130, 115, 0.8) !important;
        }

        """
        for color in HighlightColor.allCases {
            css += "span.lasa-mark.lasa-\(color.rawValue) { background-color: \(color.css) !important; }\n"
            css += "span.lasa-mark.lasa-note.lasa-\(color.rawValue) { text-decoration-color: \(color.cssStrong) !important; }\n"
        }
        return css
    }

    /// Markeringarna i ett kapitel som argument till `lasaMarks.apply`.
    static func arguments(for highlights: [Highlight]) -> [[String: Any]] {
        highlights.map { highlight in
            [
                "id": highlight.id,
                "start": highlight.start,
                "length": highlight.length,
                "text": highlight.text,
                "color": highlight.color.rawValue,
                "note": highlight.hasNote,
            ]
        }
    }

    static func markRects(from value: Any?) -> [ReflowMarkRect] {
        guard let info = value as? [String: Any], let list = info["marks"] as? [Any] else { return [] }
        return list.compactMap { item in
            guard let entry = item as? [String: Any],
                  let id = entry["id"] as? String,
                  let rect = ReflowValues.rect(from: entry) else {
                return nil
            }
            return ReflowMarkRect(id: id, rect: rect)
        }
    }

    static func textRange(from value: Any?) -> ReflowTextRange? {
        guard let info = value as? [String: Any],
              let start = ReflowValues.number(info["start"]),
              let length = ReflowValues.number(info["length"]), length > 0 else {
            return nil
        }
        let rects = (info["rects"] as? [Any] ?? []).compactMap { ReflowValues.rect(from: $0) }
        return ReflowTextRange(start: Int(start),
                               length: Int(length),
                               text: info["text"] as? String ?? "",
                               page: Int(ReflowValues.number(info["page"]) ?? 0),
                               rects: rects)
    }

    /// Båda skripten i en körning: läsarens (`ReflowStyle.script`) och markeringarnas. Argument: `css`.
    static var installScript: String {
        "(function () {\n" + ReflowStyle.script + "\n})();\n" + script
    }

    /// Delar kapitlet i sidor och lägger in markeringarna och strecken under sparade ord (O4).
    /// Argument som `lasa.setup` plus `marks` och `words`.
    static let setupBody = """
        var result = await lasa.setup(css, scale, w, h);
        if (window.lasaMarks) {
          lasaMarks.apply(marks || []);
          lasaMarks.applyWords(words || null);
        }
        return result;
        """

    /// Lägger in markeringarna och strecken igen. Argument: `marks` och `words`.
    static let reloadBody = """
        lasaMarks.apply(marks || []);
        lasaMarks.applyWords(words || null);
        return true;
        """

    /// Läggs in efter `ReflowStyle.script`, en gång per kapitel. Argument: `css`.
    static let script = #"""
    if (window.lasaMarks) {
      return true;
    }
    window.lasaMarks = (function () {
      'use strict';
      var XHTML = 'http://www.w3.org/1999/xhtml';
      var root = document.documentElement;
      var wordPattern = /[\p{L}\p{N}\p{M}]/u;
      var joiners = '-‐‑\'’';
      var trailing = '.,;:!?…»”")';
      var nodes = null;
      var starts = null;
      var indexOfNode = null;
      var total = 0;

      function installStyle(css) {
        if (document.getElementById('lasa-marks-style')) {
          return;
        }
        var style = document.createElementNS(XHTML, 'style');
        style.setAttribute('id', 'lasa-marks-style');
        style.textContent = css;
        (document.head || document.getElementsByTagName('head')[0] || root).appendChild(style);
      }

      function skipped(node) {
        var parent = node.parentNode;
        var body = document.body;
        while (parent && parent.nodeType === 1) {
          if (parent === body) {
            return false;
          }
          var name = (parent.localName || '').toLowerCase();
          if (name === 'script' || name === 'style' || name === 'head') {
            return true;
          }
          parent = parent.parentNode;
        }
        return false;
      }

      function collect() {
        nodes = [];
        starts = [];
        indexOfNode = new Map();
        total = 0;
        var walker = document.createTreeWalker(document.body || root, NodeFilter.SHOW_TEXT, null);
        var node;
        while ((node = walker.nextNode())) {
          if (skipped(node)) {
            continue;
          }
          indexOfNode.set(node, nodes.length);
          nodes.push(node);
          starts.push(total);
          total += node.data.length;
        }
      }

      function ensure() {
        if (!nodes) {
          collect();
        }
      }

      function locate(offset) {
        ensure();
        if (!nodes.length) {
          return null;
        }
        var lo = 0;
        var hi = nodes.length - 1;
        while (lo < hi) {
          var mid = (lo + hi + 1) >> 1;
          if (starts[mid] <= offset) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        var node = nodes[lo];
        return { node: node, offset: Math.min(Math.max(offset - starts[lo], 0), node.data.length) };
      }

      function offsetOf(node, inside) {
        ensure();
        var index = indexOfNode.get(node);
        return index === undefined ? -1 : starts[index] + inside;
      }

      function charAt(offset) {
        if (offset < 0) {
          return '';
        }
        var place = locate(offset);
        if (!place || place.offset >= place.node.data.length) {
          return '';
        }
        return place.node.data[place.offset];
      }

      function isWord(ch) {
        return !!ch && wordPattern.test(ch);
      }

      function isWordAt(offset) {
        var ch = charAt(offset);
        if (isWord(ch)) {
          return true;
        }
        return !!ch && joiners.indexOf(ch) >= 0 && isWord(charAt(offset - 1)) && isWord(charAt(offset + 1));
      }

      function rangeFor(start, end) {
        var a = locate(start);
        var b = locate(end);
        if (!a || !b) {
          return null;
        }
        var range = document.createRange();
        range.setStart(a.node, a.offset);
        range.setEnd(b.node, b.offset);
        return range;
      }

      function clean(text) {
        return text.replace(/­/g, '').replace(/\s+/g, ' ').trim();
      }

      function rectsOf(range) {
        var out = [];
        var w = lasa.pageWidth();
        var h = window.innerHeight;
        var list = range.getClientRects();
        for (var k = 0; k < list.length && out.length < 200; k++) {
          var r = list[k];
          if (r.width < 1 || r.height < 1 || r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) {
            continue;
          }
          out.push({ x: r.left, y: r.top, w: r.width, h: r.height });
        }
        return out;
      }

      function insidePage(r) {
        var w = lasa.pageWidth();
        var h = window.innerHeight;
        return r.width > 0 && r.right > 1 && r.left < w - 1 && r.bottom > 0 && r.top < h;
      }

      function charVisible(node, i) {
        var r = document.createRange();
        r.setStart(node, i);
        r.setEnd(node, i + 1);
        var list = r.getClientRects();
        for (var k = 0; k < list.length; k++) {
          if (insidePage(list[k])) {
            return true;
          }
        }
        return false;
      }

      // Var texten som syns på sidan börjar och slutar. Sidan ska vara vald med lasa.ensurePage.
      function visibleRange() {
        ensure();
        var w = lasa.pageWidth();
        var first = -1;
        var last = -1;
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          if (!node.data.length || /^\s*$/.test(node.data)) {
            continue;
          }
          var whole = document.createRange();
          whole.selectNodeContents(node);
          var list = whole.getClientRects();
          var visible = false;
          for (var k = 0; k < list.length; k++) {
            if (insidePage(list[k])) {
              visible = true;
              break;
            }
          }
          if (!visible) {
            if (first >= 0 && list.length && list[0].left >= w - 1) {
              break;
            }
            continue;
          }
          if (first < 0) {
            first = i;
          }
          last = i;
        }
        if (first < 0) {
          return null;
        }
        var a = nodes[first];
        var startIn = 0;
        while (startIn < a.data.length && !charVisible(a, startIn)) {
          startIn++;
        }
        var b = nodes[last];
        var endIn = b.data.length;
        while (endIn > 0 && !charVisible(b, endIn - 1)) {
          endIn--;
        }
        var start = starts[first] + startIn;
        return { start: start, end: Math.max(start, starts[last] + endIn) };
      }

      // Om tecknet vid en plats (eller det före) står på sidan som syns, nära fingrets höjd.
      function nearFinger(offset, y) {
        for (var k = 0; k < 2; k++) {
          var o = offset - k;
          if (o < 0 || o >= total) {
            continue;
          }
          var range = rangeFor(o, o + 1);
          if (!range) {
            continue;
          }
          var list = range.getClientRects();
          for (var i = 0; i < list.length; i++) {
            var r = list[i];
            if (insidePage(r) && Math.abs((r.top + r.bottom) / 2 - y) < 48) {
              return true;
            }
          }
        }
        return false;
      }

      // Samma vikning som FoldedText i Swift: små bokstäver, ett mellanslag mellan orden, inga avstavningar.
      function isSpaceCode(c) {
        return c === 0x20 || c === 0x09 || c === 0xA0 || c === 0x0A || c === 0x0D || c === 0x2028 ||
          c === 0x2029 || c === 0x0B || c === 0x0C;
      }

      function isBreakCode(c) {
        return c === 0x0A || c === 0x0D || c === 0x2028 || c === 0x2029;
      }

      function isLowerCode(c) {
        var ch = String.fromCharCode(c);
        return ch !== ch.toUpperCase() && ch === ch.toLowerCase();
      }

      function lowerCode(c) {
        if (c >= 0x41 && c <= 0x5A) {
          return c + 32;
        }
        if (c < 0xC0) {
          return c;
        }
        var lowered = String.fromCharCode(c).toLowerCase();
        return lowered.length === 1 ? lowered.charCodeAt(0) : c;
      }

      function fold(text) {
        var out = [];
        var map = [];
        var n = text.length;
        for (var i = 0; i < n; i++) {
          var c = text.charCodeAt(i);
          if (c === 0xAD) {
            continue;
          }
          if (isSpaceCode(c)) {
            if (out.length && out[out.length - 1] !== 0x20) {
              out.push(0x20);
              map.push(i);
            }
            continue;
          }
          if ((c === 0x2D || c === 0x2010 || c === 0x2011) && out.length && out[out.length - 1] !== 0x20) {
            var j = i + 1;
            var sawBreak = false;
            while (j < n && isSpaceCode(text.charCodeAt(j))) {
              if (isBreakCode(text.charCodeAt(j))) {
                sawBreak = true;
              }
              j++;
            }
            if (sawBreak && j < n && isLowerCode(text.charCodeAt(j))) {
              i = j - 1;
              continue;
            }
          }
          out.push(lowerCode(c));
          map.push(i);
        }
        var parts = [];
        for (var k = 0; k < out.length; k += 4096) {
          parts.push(String.fromCharCode.apply(null, out.slice(k, k + 4096)));
        }
        return { text: parts.join(''), map: map };
      }

      function foldedQuery(text) {
        return fold(text).text.trim();
      }

      function allText() {
        ensure();
        var parts = [];
        for (var i = 0; i < nodes.length; i++) {
          parts.push(nodes[i].data);
        }
        return parts.join('');
      }

      // MARK: Markeringar

      function unwrapAll() {
        var spans = document.querySelectorAll('span.lasa-mark');
        var parents = [];
        for (var i = 0; i < spans.length; i++) {
          var span = spans[i];
          var parent = span.parentNode;
          if (!parent) {
            continue;
          }
          while (span.firstChild) {
            parent.insertBefore(span.firstChild, span);
          }
          parent.removeChild(span);
          if (parents.indexOf(parent) < 0) {
            parents.push(parent);
          }
        }
        for (var k = 0; k < parents.length; k++) {
          parents[k].normalize();
        }
        nodes = null;
      }

      // Stämmer inte texten på den sparade platsen (boken har bytts eller gjorts om) letas den upp i närheten.
      function place(mark) {
        var start = mark.start;
        var end = mark.start + mark.length;
        if (!mark.text) {
          return { start: start, end: end };
        }
        var wanted = foldedQuery(mark.text);
        var range = rangeFor(start, end);
        if (range && foldedQuery(range.toString()) === wanted) {
          return { start: start, end: end };
        }
        var folded = fold(allText());
        var guess = 0;
        for (var i = 0; i < folded.map.length; i++) {
          if (folded.map[i] >= start) {
            guess = i;
            break;
          }
        }
        var best = -1;
        var from = 0;
        while (true) {
          var found = folded.text.indexOf(wanted, from);
          if (found < 0) {
            break;
          }
          if (best < 0 || Math.abs(found - guess) < Math.abs(best - guess)) {
            best = found;
          }
          from = found + 1;
        }
        if (best < 0 || !wanted.length) {
          return null;
        }
        return { start: folded.map[best], end: folded.map[best + wanted.length - 1] + 1 };
      }

      function wrap(mark) {
        ensure();
        var spot = place(mark);
        if (!spot || spot.end <= spot.start) {
          return false;
        }
        var targets = [];
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          var nodeStart = starts[i];
          var nodeEnd = nodeStart + node.data.length;
          if (nodeEnd <= spot.start) {
            continue;
          }
          if (nodeStart >= spot.end) {
            break;
          }
          var s = Math.max(spot.start, nodeStart) - nodeStart;
          var e = Math.min(spot.end, nodeEnd) - nodeStart;
          if (e <= s || /^\s*$/.test(node.data.slice(s, e))) {
            continue;
          }
          targets.push({ node: node, s: s, e: e });
        }
        var className = 'lasa-mark lasa-' + mark.color + (mark.note ? ' lasa-note' : '');
        for (var k = 0; k < targets.length; k++) {
          var target = targets[k];
          var piece = target.node;
          if (target.e < piece.data.length) {
            piece.splitText(target.e);
          }
          if (target.s > 0) {
            piece = piece.splitText(target.s);
          }
          var span = document.createElementNS(XHTML, 'span');
          span.setAttribute('class', className);
          span.setAttribute('data-lasa-id', mark.id);
          piece.parentNode.insertBefore(span, piece);
          span.appendChild(piece);
        }
        nodes = null;
        return targets.length > 0;
      }

      function apply(marks) {
        unwrapAll();
        var applied = 0;
        for (var i = 0; i < marks.length; i++) {
          try {
            if (wrap(marks[i])) {
              applied++;
            }
          } catch (error) {
            nodes = null;
          }
        }
        return { applied: applied };
      }


      // MARK: Dina ord i texten (O4)

      // Sparade ord får ett streck: helt för ord man övar, prickat för ord man kan. words: form (gemener)
      // till 'w:' eller 'k:' plus id. Ordmönstret är detsamma som SavedWordMatcher i Swift.
      function unwrapWords() {
        var spans = document.querySelectorAll('span.lasa-word');
        var parents = [];
        for (var i = 0; i < spans.length; i++) {
          var span = spans[i];
          var parent = span.parentNode;
          if (!parent) {
            continue;
          }
          while (span.firstChild) {
            parent.insertBefore(span.firstChild, span);
          }
          parent.removeChild(span);
          if (parents.indexOf(parent) < 0) {
            parents.push(parent);
          }
        }
        for (var k = 0; k < parents.length; k++) {
          parents[k].normalize();
        }
        nodes = null;
      }

      function applyWords(words) {
        unwrapWords();
        if (!words || !Object.keys(words).length) {
          return 0;
        }
        var list = [];
        var walker = document.createTreeWalker(document.body || root, NodeFilter.SHOW_TEXT, null);
        var node;
        while ((node = walker.nextNode())) {
          if (!skipped(node)) {
            list.push(node);
          }
        }
        var pattern = /[\p{L}\p{M}]+(?:['’\-‐‑][\p{L}\p{M}]+)*/gu;
        var count = 0;
        for (var i = 0; i < list.length && count < 4000; i++) {
          var text = list[i];
          var found = [];
          var match;
          pattern.lastIndex = 0;
          while ((match = pattern.exec(text.data))) {
            var value = words[match[0].toLowerCase().replace(/’/g, "'")];
            if (value) {
              found.push([match.index, match.index + match[0].length, value]);
            }
          }
          // Bakifrån, så att platserna i textnoden stämmer när den delas.
          for (var k = found.length - 1; k >= 0; k--) {
            var item = found[k];
            var piece = text;
            if (item[1] < piece.data.length) {
              piece.splitText(item[1]);
            }
            if (item[0] > 0) {
              piece = piece.splitText(item[0]);
            }
            var span = document.createElementNS(XHTML, 'span');
            span.setAttribute('class', item[2].charAt(0) === 'k' ? 'lasa-word lasa-word-known' : 'lasa-word');
            span.setAttribute('data-lasa-word', item[2].slice(2));
            piece.parentNode.insertBefore(span, piece);
            span.appendChild(piece);
            count++;
          }
        }
        nodes = null;
        return count;
      }

      function visibleWords(out, w, h) {
        var spans = document.querySelectorAll('span.lasa-word');
        for (var i = 0; i < spans.length && out.length < 300; i++) {
          var id = 'ord:' + spans[i].getAttribute('data-lasa-word');
          var rects = spans[i].getClientRects();
          for (var k = 0; k < rects.length; k++) {
            var r = rects[k];
            if (r.width < 1 || r.height < 1 || r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) {
              continue;
            }
            out.push({ id: id, x: r.left, y: r.top, w: r.width, h: r.height });
          }
        }
      }

      function visible() {
        var out = [];
        var w = lasa.pageWidth();
        var h = window.innerHeight;
        // Strecken först, så att en markering över ett sparat ord går före när man trycker.
        try {
          visibleWords(out, w, h);
        } catch (error) {
          out = [];
        }
        var spans = document.querySelectorAll('span.lasa-mark');
        for (var i = 0; i < spans.length && out.length < 700; i++) {
          var id = spans[i].getAttribute('data-lasa-id');
          var rects = spans[i].getClientRects();
          for (var k = 0; k < rects.length; k++) {
            var r = rects[k];
            if (r.width < 1 || r.height < 1 || r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) {
              continue;
            }
            out.push({ id: id, x: r.left, y: r.top, w: r.width, h: r.height });
          }
        }
        // K6: finns ett citat till en fråga på sidan följer textens kolumn med, så att pricken hamnar i marginalen.
        for (var q = 0; q < out.length; q++) {
          if (out[q].id && out[q].id.indexOf('fraga:') === 0) {
            var side = parseFloat(getComputedStyle(root).paddingLeft) || 0;
            out.push({ id: 'fraga-kolumn', x: side, y: 0, w: Math.max(1, w - 2 * side), h: h });
            break;
          }
        }
        return out;
      }

      // MARK: Markera med fingret

      function caretOffset(x, y) {
        var range = document.caretRangeFromPoint(x, y);
        if (!range || !range.startContainer || range.startContainer.nodeType !== 3) {
          return -1;
        }
        var offset = offsetOf(range.startContainer, range.startOffset);
        // Under sista raden ger webbvyn en plats någon annanstans, ibland på förra sidan.
        return offset >= 0 && nearFinger(offset, y) ? offset : -1;
      }

      function select(index, x1, y1, x2, y2) {
        lasa.ensurePage(index);
        ensure();
        var a = caretOffset(x1, y1);
        var b = caretOffset(x2, y2);
        if (a < 0 && b < 0) {
          return null;
        }
        if (a < 0 || b < 0) {
          // Ena fingret utanför texten: markera till sidans början eller slut, åt det håll fingret drog.
          var bounds = visibleRange();
          if (!bounds) {
            return null;
          }
          if (a < 0) {
            a = y1 <= y2 ? bounds.start : Math.max(bounds.start, bounds.end - 1);
          }
          if (b < 0) {
            b = y2 >= y1 ? Math.max(bounds.start, bounds.end - 1) : bounds.start;
          }
        }
        var start = Math.min(a, b);
        var end = Math.max(a, b);
        if (!isWordAt(start) && isWordAt(start - 1)) {
          start -= 1;
        }
        while (start > 0 && isWordAt(start - 1)) {
          start -= 1;
        }
        while (start < total && !isWordAt(start)) {
          start += 1;
        }
        if (end <= start) {
          end = start + 1;
        }
        if (!isWordAt(end - 1) && end - 1 > start) {
          while (end - 1 > start && !isWordAt(end - 1)) {
            end -= 1;
          }
        }
        while (end < total && isWordAt(end)) {
          end += 1;
        }
        if (end < total && trailing.indexOf(charAt(end)) >= 0) {
          end += 1;
        }
        if (start >= total) {
          return null;
        }
        var range = rangeFor(start, end);
        if (!range) {
          return null;
        }
        return { start: start, length: end - start, text: clean(range.toString()), page: index, rects: rectsOf(range) };
      }

      function text(start, length) {
        var range = rangeFor(start, start + length);
        return range ? clean(range.toString()) : '';
      }

      // MARK: Sökning

      // Letar upp en sökträff: helst den med samma text runt omkring som i träfflistan, annars den n:te.
      function find(query, occurrence, context) {
        var wanted = foldedQuery(query);
        if (!wanted.length) {
          return null;
        }
        var folded = fold(allText());
        var hits = [];
        var from = 0;
        while (hits.length < 5000) {
          var found = folded.text.indexOf(wanted, from);
          if (found < 0) {
            break;
          }
          hits.push(found);
          from = found + 1;
        }
        if (!hits.length) {
          return null;
        }
        var around = context ? fold(context).text : '';
        function matches(position) {
          if (!around) {
            return false;
          }
          var a = Math.max(0, position - 12);
          var piece = folded.text.slice(a, position + wanted.length + 12);
          return around.indexOf(piece) >= 0;
        }
        var chosen = hits[Math.min(Math.max(occurrence, 0), hits.length - 1)];
        if (!matches(chosen)) {
          for (var i = 0; i < hits.length; i++) {
            if (matches(hits[i])) {
              chosen = hits[i];
              break;
            }
          }
        }
        var start = folded.map[chosen];
        var end = folded.map[chosen + wanted.length - 1] + 1;
        return reveal(start, end - start);
      }

      // Sidan i kapitlet där ett intervall börjar, och intervallets rutor på den sidan.
      function reveal(start, length) {
        ensure();
        var range = rangeFor(start, start + Math.max(length, 1));
        if (!range) {
          return null;
        }
        lasa.setOffset(0);
        var first = range.getClientRects();
        var r = first.length ? first[0] : range.getBoundingClientRect();
        var page = Math.max(0, Math.floor((r.left + 1) / lasa.pageWidth()));
        lasa.ensurePage(page);
        return { start: start, length: length, text: clean(range.toString()), page: page, rects: rectsOf(range) };
      }

      // Sidbilden får också markeringarnas rutor, så att ett tryck på en markering kan hittas utan webbvyn.
      var originalShowPage = lasa.showPage;
      lasa.showPage = async function (index) {
        var result = await originalShowPage(index);
        try {
          result.marks = visible();
        } catch (error) {
          result.marks = [];
        }
        return result;
      };

      return { installStyle: installStyle, apply: apply, applyWords: applyWords, select: select, text: text,
               find: find, reveal: reveal, visible: visible, visibleRange: visibleRange };
    })();
    lasaMarks.installStyle(css);
    return true;
    """#
}
