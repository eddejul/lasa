import UIKit

/// CSS och JavaScript som läggs in i kapitlen.
///
/// Kapitlet delas i kolumner lika breda som en sida (CSS-kolumner på html-elementet). Sidan som ska synas
/// väljs genom att flytta hela dokumentet i sidled med en transform, så att webbvyn aldrig rullar.
/// Allt körs i en egen JavaScript-värld (`.defaultClient`), skild från bokens egna skript.
enum ReflowStyle {

    static func css(layout: ReflowLayout, theme: ReaderTheme) -> String {
        let padding = layout.padding
        let vertical = padding.top + padding.bottom
        let typography = layout.typography
        // U2: sidmarginalen växer när sidan är bred, så att raden blir högst ungefär 66 tecken (29,5 em
        // med Normal). Kolumn plus mellanrum är alltid 100vw, så att bläddringen i skriptet stämmer.
        let side = "max(\(px(max(padding.left, padding.right)))," +
            " calc((100vw - \(String(format: "%.1f", typography.margin.measure))em) / 2))"
        var css = """
        html {
          margin: 0 !important;
          padding: \(px(padding.top)) \(side) \(px(padding.bottom)) \(side) !important;
          width: 100vw !important; min-width: 100vw !important; max-width: 100vw !important;
          height: 100vh !important; min-height: 100vh !important; max-height: 100vh !important;
          box-sizing: border-box !important;
          -webkit-column-width: calc(100vw - 2 * \(side)) !important;
          column-width: calc(100vw - 2 * \(side)) !important;
          -webkit-column-gap: calc(2 * \(side)) !important;
          column-gap: calc(2 * \(side)) !important;
          line-height: \(String(format: "%.2f", typography.lineSpacing.lineHeight)) !important;
          column-fill: auto !important;
          -webkit-text-size-adjust: none !important;
          font-size: __ROOT__ !important;
          overflow: visible !important;
        }
        body {
          margin: 0 !important;
          padding: 0 !important;
          width: auto !important; min-width: 0 !important; max-width: none !important;
          height: auto !important; min-height: 0 !important; max-height: none !important;
          overflow: visible !important;
          -webkit-column-count: auto !important; column-count: auto !important;
          -webkit-column-width: auto !important; column-width: auto !important;
          background-color: transparent !important;
        }
        img, svg, video, canvas, object, embed, iframe, table {
          max-width: 100% !important;
          box-sizing: border-box !important;
        }
        img, svg, video, canvas, object, embed {
          max-height: calc(100vh - \(px(vertical))) !important;
          object-fit: contain;
          -webkit-column-break-inside: avoid;
          break-inside: avoid;
        }
        img {
          height: auto;
        }
        figure {
          -webkit-column-break-inside: avoid;
          break-inside: avoid;
        }
        h1, h2, h3, h4, h5, h6 {
          -webkit-column-break-after: avoid;
          break-after: avoid;
        }
        p, li {
          orphans: 2;
          widows: 2;
        }

        """

        switch theme {
        case .white:
            css += "html { background-color: #ffffff !important; }\n"
        case .paper:
            css += colorOverrides(paper: "#fbf8f2", text: "#1e1c19", link: "#2d5b84", extra: "")
        case .sepia:
            css += colorOverrides(paper: "#f4ecd8", text: "#3b2f23", link: "#8a4b1f", extra: "")
        case .dark:
            css += colorOverrides(paper: "#1c1c1c", text: "#d2d2d2", link: "#8ab4f8",
                                  extra: "img, svg, video { opacity: 0.88; }\n")
        }

        // Radavståndet i brödtexten, och justering med avstavning på bokens språk (-webkit- krävs i iOS 15).
        // Stycken som boken själv centrerar eller högerställer lämnas.
        let lineHeight = String(format: "%.2f", typography.lineSpacing.lineHeight)
        css += "p, li, blockquote, dd, dt, td { line-height: \(lineHeight) !important; }\n"
        if typography.justify {
            css += "p:not([align]):not([style*=\"center\"]):not([style*=\"right\"]), li { text-align: justify "
                + "!important; -webkit-hyphens: auto !important; hyphens: auto !important; }\n"
        } else {
            css += "p:not([align]):not([style*=\"center\"]):not([style*=\"right\"]), li { text-align: start "
                + "!important; -webkit-hyphens: manual !important; hyphens: manual !important; }\n"
        }

        if let family = layout.typography.font.cssFamily {
            css += "body, body *:not(pre):not(code):not(kbd):not(samp):not(tt) "
                + "{ font-family: \(family) !important; }\n"
        }
        return css
    }

    private static func colorOverrides(paper: String, text: String, link: String, extra: String) -> String {
        """
        html { background-color: \(paper) !important; color: \(text) !important; }
        body, body *:not(a) { color: inherit !important; background-color: transparent !important; }
        a, a * { color: \(link) !important; background-color: transparent !important; }
        \(extra)
        """
    }

    private static func px(_ value: CGFloat) -> String {
        String(format: "%.1fpx", Double(value))
    }

    /// Funktionerna som läsaren anropar. Läggs in en gång per kapitel, efter att kapitlet laddats.
    static let script = #"""
    if (window.lasa) {
      return true;
    }
    window.lasa = (function () {
      'use strict';
      var XHTML = 'http://www.w3.org/1999/xhtml';
      var root = document.documentElement;
      var offset = 0;
      var wordPattern = /[\p{L}\p{N}\p{M}]/u;
      var joiners = '-‐‑\'’­';

      function make(name) {
        return document.createElementNS(XHTML, name);
      }

      function container() {
        return document.head || document.getElementsByTagName('head')[0] || root;
      }

      function setViewport(width) {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = make('meta');
          meta.setAttribute('name', 'viewport');
          container().appendChild(meta);
        }
        meta.setAttribute('content', 'width=' + width +
          ', initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, shrink-to-fit=no');
      }

      // Bokens egen grundstorlek mäts en gång, innan läsarens stil finns, och sparas på stilelementet.
      // Annars skulle varje ny storlek räknas från den förra.
      function setStyle(css, scale) {
        var style = document.getElementById('lasa-style');
        if (!style) {
          var base = parseFloat(getComputedStyle(root).fontSize) || 16;
          style = make('style');
          style.setAttribute('id', 'lasa-style');
          style.setAttribute('data-base', String(base));
          container().appendChild(style);
        }
        var baseRoot = parseFloat(style.getAttribute('data-base')) || 16;
        style.textContent = css.split('__ROOT__').join((baseRoot * scale).toFixed(2) + 'px');
        // U2: avstavning kräver språket på html. Saknas det och boken bara har xml:lang, används det.
        // Utan språk blir det ingen avstavning, och texten justeras ändå.
        if (!root.getAttribute('lang')) {
          var XML = 'http://www.w3.org/XML/1998/namespace';
          var body = document.body;
          var lang = root.getAttributeNS(XML, 'lang') ||
            (body && (body.getAttribute('lang') || body.getAttributeNS(XML, 'lang')));
          if (lang) {
            root.setAttribute('lang', lang);
          }
        }
      }

      function frame() {
        return new Promise(function (resolve) {
          var done = false;
          function finish() {
            if (!done) {
              done = true;
              resolve();
            }
          }
          requestAnimationFrame(finish);
          setTimeout(finish, 80);
        });
      }

      function resources() {
        var waits = [];
        if (document.fonts && document.fonts.ready) {
          waits.push(document.fonts.ready);
        }
        Array.prototype.forEach.call(document.images || [], function (image) {
          if (!image.complete) {
            waits.push(new Promise(function (resolve) {
              image.addEventListener('load', resolve);
              image.addEventListener('error', resolve);
            }));
          }
        });
        var timeout = new Promise(function (resolve) { setTimeout(resolve, 2500); });
        return Promise.race([Promise.all(waits), timeout]);
      }

      function pageWidth() {
        return window.innerWidth || root.clientWidth || 1;
      }

      function setOffset(x) {
        offset = x;
        if (x === 0) {
          root.style.removeProperty('transform');
        } else {
          root.style.setProperty('transform', 'translateX(' + (-x) + 'px)', 'important');
        }
      }

      function measure() {
        var saved = offset;
        setOffset(0);
        var scroller = document.scrollingElement || root;
        var width = Math.max(scroller.scrollWidth, root.scrollWidth);
        var w = pageWidth();
        var count = Math.max(1, Math.round(width / w));
        setOffset(saved);
        return { count: count, width: w, height: window.innerHeight, scrollWidth: width };
      }

      async function setup(css, scale, w, h) {
        linkCache = null;
        setViewport(Math.round(w));
        setStyle(css, scale);
        await resources();
        await frame();
        var result = measure();
        if (Math.abs(result.width - w) > 1) {
          await frame();
          await frame();
          result = measure();
        }
        return result;
      }

      async function restyle(css, scale) {
        linkCache = null;
        setStyle(css, scale);
        await frame();
        return measure();
      }

      // Alla länkars rutor i kapitlet, räknade en gång per layout. x räknas från kapitlets början,
      // så att varje sida bara behöver välja sina. Förskjutningen är en ren transform, så rutan
      // flyttas bara i sidled med den.
      var linkCache = null;

      // V5: en fotnotssiffra eller hänvisning (epub:type noteref, role doc-noteref, eller en länk inom boken
      // vars text bara är en siffra eller ett tecken som * och [12]).
      function isNoteRef(anchor, href) {
        var type = (anchor.getAttributeNS('http://www.idpf.org/2007/ops', 'type') || anchor.getAttribute('epub:type') || '')
          + ' ' + (anchor.getAttribute('role') || '');
        if (/noteref|biblioref/.test(type)) {
          return true;
        }
        if (href.indexOf('#') < 0) {
          return false;
        }
        var text = (anchor.textContent || '').replace(/\s+/g, '');
        return /^[\[(]?(\d{1,3}|[*†‡§]{1,3})[\])]?$/.test(text);
      }

      function allLinks() {
        var w = pageWidth();
        var h = window.innerHeight;
        var scroller = document.scrollingElement || root;
        var key = w + 'x' + h + 'x' + Math.max(scroller.scrollWidth, root.scrollWidth);
        if (linkCache && linkCache.key === key) {
          return linkCache.items;
        }
        var items = [];
        var anchors = document.querySelectorAll('a[href]');
        for (var i = 0; i < anchors.length; i++) {
          var href = anchors[i].href;
          if (typeof href !== 'string' || !href) {
            continue;
          }
          var note = isNoteRef(anchors[i], href);
          var rects = anchors[i].getClientRects();
          for (var k = 0; k < rects.length; k++) {
            var r = rects[k];
            if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= h) {
              continue;
            }
            items.push({ x: r.left + offset, y: r.top, w: r.width, h: r.height, href: href, note: note });
          }
        }
        linkCache = { key: key, items: items };
        return items;
      }

      // Länkarna på sidan som syns.
      function links() {
        var out = [];
        var w = pageWidth();
        var items = allLinks();
        for (var i = 0; i < items.length && out.length < 300; i++) {
          var item = items[i];
          var x = item.x - offset;
          if (x + item.w <= 0 || x >= w) {
            continue;
          }
          out.push({ x: x, y: item.y, w: item.w, h: item.h, href: item.href, note: item.note });
        }
        return out;
      }

      async function showPage(index) {
        setOffset(index * pageWidth());
        await frame();
        return { offset: offset, links: links() };
      }

      function isWord(ch) {
        return !!ch && wordPattern.test(ch);
      }

      function isJoiner(text, i) {
        return i > 0 && i + 1 < text.length && joiners.indexOf(text[i]) >= 0 &&
          isWord(text[i - 1]) && isWord(text[i + 1]);
      }

      function clean(text) {
        return text.replace(/­/g, '').replace(/\s+/g, ' ');
      }

      function blockOf(node) {
        var element = node.parentElement;
        while (element && element !== root) {
          var display = getComputedStyle(element).display;
          if (display && display.indexOf('inline') !== 0 && display !== 'contents') {
            return element;
          }
          element = element.parentElement;
        }
        return document.body || root;
      }

      // Ordet som innehåller tecknet på plats i, som [början, slut], eller null.
      function wordSpan(text, i) {
        if (i < 0 || i >= text.length || !isWord(text[i])) {
          return null;
        }
        var start = i;
        var end = i + 1;
        while (start > 0 && (isWord(text[start - 1]) || isJoiner(text, start - 1))) {
          start -= 1;
        }
        while (end < text.length && (isWord(text[end]) || isJoiner(text, end))) {
          end += 1;
        }
        return [start, end];
      }

      // Avståndet från punkten till närmaste ruta, och rutorna.
      function measureSpan(node, span, x, y) {
        var wordRange = document.createRange();
        wordRange.setStart(node, span[0]);
        wordRange.setEnd(node, span[1]);
        var rects = [];
        var best = Infinity;
        var list = wordRange.getClientRects();
        for (var k = 0; k < list.length; k++) {
          var r = list[k];
          if (r.width < 1 || r.height < 1) {
            continue;
          }
          rects.push({ x: r.left, y: r.top, w: r.width, h: r.height });
          var dx = Math.max(r.left - x, 0, x - r.right);
          var dy = Math.max(r.top - y, 0, y - r.bottom);
          best = Math.min(best, Math.sqrt(dx * dx + dy * dy));
        }
        return { distance: best, rects: rects };
      }

      // Ordet närmast fingret, inte bara ordet till vänster om markören, och bara om det ligger inom tolerance.
      function wordAt(index, x, y, tolerance) {
        var target = index * pageWidth();
        if (offset !== target) {
          setOffset(target);
        }
        var range = document.caretRangeFromPoint(x, y);
        if (!range) {
          return null;
        }
        var node = range.startContainer;
        if (!node || node.nodeType !== 3) {
          return null;
        }
        var text = node.data;
        var i = range.startOffset;
        var chosen = null;
        var tried = {};
        [i, i - 1, i + 1].forEach(function (position) {
          var span = wordSpan(text, position);
          if (!span || tried[span[0]]) {
            return;
          }
          tried[span[0]] = true;
          var measured = measureSpan(node, span, x, y);
          if (!chosen || measured.distance < chosen.distance) {
            chosen = { span: span, distance: measured.distance, rects: measured.rects };
          }
        });
        if (!chosen || chosen.distance > tolerance) {
          return null;
        }
        var start = chosen.span[0];
        var end = chosen.span[1];
        var rects = chosen.rects;

        var before = '';
        var after = '';
        try {
          var block = blockOf(node);
          var pre = document.createRange();
          pre.setStart(block, 0);
          pre.setEnd(node, start);
          before = pre.toString();
          var post = document.createRange();
          post.setStart(node, end);
          post.setEnd(block, block.childNodes.length);
          after = post.toString();
        } catch (error) {
        }
        return {
          word: text.slice(start, end).replace(/­/g, ''),
          before: clean(before).slice(-200),
          after: clean(after).slice(0, 200),
          rects: rects
        };
      }

      function pageOf(id) {
        var element = document.getElementById(id);
        if (!element) {
          var named = document.getElementsByName(id);
          element = named.length ? named[0] : null;
        }
        if (!element) {
          return -1;
        }
        var saved = offset;
        setOffset(0);
        var rects = element.getClientRects();
        var r = rects.length ? rects[0] : element.getBoundingClientRect();
        var page = Math.max(0, Math.floor((r.left + 1) / pageWidth()));
        setOffset(saved);
        return page;
      }

      function ensurePage(index) {
        var target = index * pageWidth();
        if (offset !== target) {
          setOffset(target);
        }
      }

      return { setup: setup, restyle: restyle, showPage: showPage, wordAt: wordAt, pageOf: pageOf, measure: measure,
               ensurePage: ensurePage, setOffset: setOffset, pageWidth: pageWidth };
    })();
    return true;
    """#
}
