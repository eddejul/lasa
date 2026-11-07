import UIKit

/// CSS och JavaScript som läggs in i kapitlen.
///
/// Kapitlet delas i kolumner lika breda som en sida (CSS-kolumner på html-elementet). Sidan som ska synas
/// väljs genom att flytta hela dokumentet i sidled med en transform, så att webbvyn aldrig rullar.
/// Allt körs i en egen JavaScript-värld (`.defaultClient`), skild från bokens egna skript.
enum ReflowStyle {

    static func css(layout: ReflowLayout, theme: ReaderTheme) -> String {
        let padding = layout.padding
        let horizontal = padding.left + padding.right
        let vertical = padding.top + padding.bottom
        var css = """
        html {
          margin: 0 !important;
          padding: \(px(padding.top)) \(px(padding.right)) \(px(padding.bottom)) \(px(padding.left)) !important;
          width: 100vw !important; min-width: 100vw !important; max-width: 100vw !important;
          height: 100vh !important; min-height: 100vh !important; max-height: 100vh !important;
          box-sizing: border-box !important;
          -webkit-column-width: calc(100vw - \(px(horizontal))) !important;
          column-width: calc(100vw - \(px(horizontal))) !important;
          -webkit-column-gap: \(px(horizontal)) !important;
          column-gap: \(px(horizontal)) !important;
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
        case .sepia:
            css += colorOverrides(paper: "#f4ecd8", text: "#3b2f23", link: "#8a4b1f", extra: "")
        case .dark:
            css += colorOverrides(paper: "#1c1c1c", text: "#d2d2d2", link: "#8ab4f8",
                                  extra: "img, svg, video { opacity: 0.88; }\n")
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
    window.lasa = (function () {
      'use strict';
      var XHTML = 'http://www.w3.org/1999/xhtml';
      var root = document.documentElement;
      var baseRoot = null;
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

      function setStyle(css, scale) {
        if (baseRoot === null) {
          baseRoot = parseFloat(getComputedStyle(root).fontSize) || 16;
        }
        var style = document.getElementById('lasa-style');
        if (!style) {
          style = make('style');
          style.setAttribute('id', 'lasa-style');
          container().appendChild(style);
        }
        style.textContent = css.split('__ROOT__').join((baseRoot * scale).toFixed(2) + 'px');
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
          requestAnimationFrame(function () { requestAnimationFrame(finish); });
          setTimeout(finish, 150);
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
        setStyle(css, scale);
        await frame();
        return measure();
      }

      function links() {
        var out = [];
        var w = pageWidth();
        var h = window.innerHeight;
        var anchors = document.querySelectorAll('a[href]');
        for (var i = 0; i < anchors.length && out.length < 300; i++) {
          var href = anchors[i].href;
          if (typeof href !== 'string' || !href) {
            continue;
          }
          var rects = anchors[i].getClientRects();
          for (var k = 0; k < rects.length; k++) {
            var r = rects[k];
            if (r.width < 1 || r.height < 1 || r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) {
              continue;
            }
            out.push({ x: r.left, y: r.top, w: r.width, h: r.height, href: href });
          }
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

      function wordAt(index, x, y) {
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
        if (i >= text.length || !isWord(text[i])) {
          i -= 1;
        }
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

        var wordRange = document.createRange();
        wordRange.setStart(node, start);
        wordRange.setEnd(node, end);
        var rects = [];
        var hit = false;
        var list = wordRange.getClientRects();
        for (var k = 0; k < list.length; k++) {
          var r = list[k];
          if (r.width < 1 || r.height < 1) {
            continue;
          }
          rects.push({ x: r.left, y: r.top, w: r.width, h: r.height });
          if (x >= r.left - 8 && x <= r.right + 8 && y >= r.top - 8 && y <= r.bottom + 8) {
            hit = true;
          }
        }
        if (!hit) {
          return null;
        }

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

      return { setup: setup, restyle: restyle, showPage: showPage, wordAt: wordAt, pageOf: pageOf, measure: measure };
    })();
    return true;
    """#
}
