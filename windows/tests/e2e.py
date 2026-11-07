"""Provkör Windows-appens gränssnitt i Chrome (huvudlöst) mot dev/server.py.

  python windows/tests/e2e.py --url http://127.0.0.1:8955/ --books <mapp med testböcker> --out <mapp för bilder>

Datamappen som servern använder ska vara tom vid start. Testet lägger till en PDF, en EPUB och en
Markdown-fil, bläddrar med tangenter och mushjul, dubbelklickar på svenska och engelska ord och läser
rutan, kontrollerar Sparade ord, att läspositionen finns kvar efter omladdning, teman och Om ordboken,
och att konsolen är tom. Skärmbilderna sparas i --out.
"""

import argparse
import os
import re
import sys
import time

from playwright.sync_api import sync_playwright

FAILURES = []


def check(condition, message):
    print(("ok   " if condition else "FEL  ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


PAGE = None


def wait_for(predicate, timeout=10.0, interval=0.1):
    # Väntar med Playwrights egen väntan, så att händelser (som nya ramar) hinner tas emot.
    end = time.time() + timeout
    while time.time() < end:
        try:
            value = predicate()
            if value:
                return value
        except Exception:  # noqa: BLE001 (sidan kan vara mitt i en omritning)
            pass
        PAGE.wait_for_timeout(interval * 1000)
    return None


# Varningar som är kända och ofarliga: foliate-js ramar har allow-scripts och allow-same-origin (skripten
# stoppas av sidans Content-Security-Policy i stället), och testbokens nav.xhtml har ett &nbsp; som inte
# är giltig XML (foliate läser då innehållet ur toc.ncx). Favicon finns inte i provservern.
KNOWN = ("can escape its sandboxing", "XML parsing error: OEBPS/nav.xhtml", "favicon", "status of 404")


# Ger mittpunkten (i fönstrets koordinater) för en förekomst av ordet i PDF:ens textlager som syns.
FIND_IN_TEXT_LAYER = """
([word, occurrence]) => {
  const spans = [...document.querySelectorAll('.pdf-spread .textLayer span')];
  let seen = 0;
  for (const span of spans) {
    const node = span.firstChild;
    if (!node || node.nodeType !== 3) continue;
    let from = 0;
    while (true) {
      const at = node.data.indexOf(word, from);
      if (at < 0) break;
      from = at + 1;
      if (seen++ < occurrence) continue;
      const range = document.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + word.length);
      const r = range.getBoundingClientRect();
      if (r.width > 0) return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    }
  }
  return null;
}
"""

# Samma sak i ett EPUB-kapitel (körs i kapitlets ram): en förekomst som ligger inom [left, right].
FIND_IN_FRAME = """
([word, left, right]) => {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const re = new RegExp('(^|[^\\\\p{L}])' + word + '(?=[^\\\\p{L}]|$)', 'u');
    const match = re.exec(node.data);
    if (!match) continue;
    const at = match.index + match[1].length;
    const range = document.createRange();
    range.setStart(node, at);
    range.setEnd(node, at + word.length);
    for (const r of range.getClientRects()) {
      if (r.width > 0 && r.left >= left && r.right <= right) return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    }
  }
  return null;
}
"""


def popup_text(page):
    return page.locator('.popup').inner_text()


def run(url, books, out):
    os.makedirs(out, exist_ok=True)
    console = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        context = browser.new_context(viewport={"width": 1278, "height": 720}, device_scale_factor=1.5)
        page = context.new_page()
        global PAGE
        PAGE = page
        page.on("console", lambda m: console.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
        page.on("pageerror", lambda e: console.append(f"pageerror: {e}"))

        page.goto(url)
        page.wait_for_selector('[data-testid="tab-library"]')
        check(page.locator('.empty').count() == 1, 'tomt bibliotek visas först')

        # Lägg till böcker
        page.set_input_files('[data-testid="file-input"]',
                             [os.path.join(books, name) for name in ("test.pdf", "test.epub", "test.md")])
        check(wait_for(lambda: page.locator('[data-testid="book"]').count() == 3, 20), 'tre böcker i biblioteket')
        titles = page.locator('.book-title').all_inner_texts()
        check('Testbok i PDF' in titles and 'Testbok för Läsa' in titles, f'titlar ur filerna: {titles}')
        check(page.locator('.book-cover.has-image').count() == 2, 'omslag för PDF (första sidan) och EPUB (omslagsbilden)')
        ids = page.locator('[data-testid="book"]').evaluate_all('els => els.map(e => e.dataset.id)')
        check(all(len(i) == 64 and all(c in '0123456789abcdef' for c in i) for i in ids), 'bok-id är sha256 i gemener')
        page.screenshot(path=os.path.join(out, "01-bibliotek.png"))

        # PDF: öppna, bläddra
        page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
        page.wait_for_selector('.pdf-spread .pdf-page canvas')
        wait_for(lambda: page.locator('.page-label').inner_text().strip())
        first_label = page.locator('.page-label').inner_text()
        check(first_label == 'Sida 1 av 9', f'sidnummer visas: {first_label}')
        # Fönstret är bara 720 punkter högt, så en hel A4-sida blir för liten och Automatiskt ger en sida
        # i läsbar storlek (högst 1,3 gånger PDF:ens storlek) som man rullar i.
        check(page.locator('.pdf-spread.scroll').count() == 1, 'Automatiskt väljer läsbar storlek i ett lågt fönster')
        width = page.evaluate("document.querySelector('.pdf-page').getBoundingClientRect().width")
        check(abs(width - 595.3 * 1.3) < 3, f'sidan är 1,3 gånger A4-bredden: {width:.0f} punkter')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: page.locator('.page-label').inner_text() == 'Sida 2 av 9'), 'högerpil bläddrar')
        page.keyboard.press('ArrowDown')
        check(wait_for(lambda: page.evaluate("document.querySelector('.pdf-spread').scrollTop") > 50),
              'nedåtpil rullar sidan i sidbredd')
        check(page.locator('.page-label').inner_text() == 'Sida 2 av 9', 'nedåtpil bläddrar inte förrän sidan är slut')
        page.screenshot(path=os.path.join(out, "02a-pdf-sidbredd.png"))
        page.locator('[data-testid="zoom-button"]').click()
        page.locator('[data-testid="fit-page"]').click()
        check(wait_for(lambda: page.locator('.page-label').inner_text() == 'Sidorna 2 och 3 av 9'),
              f'Hela sidan ger uppslag med sida 2 och 3: {page.locator(".page-label").inner_text()}')
        page.keyboard.press('Escape')
        page.wait_for_function("document.querySelectorAll('.pdf-spread .textLayer span').length > 5")
        page.screenshot(path=os.path.join(out, "02-pdf-uppslag.png"))

        # Svenskt ord i PDF, avstavat över radbrytningen
        point = page.evaluate(FIND_IN_TEXT_LAYER, ["kun-", 0])
        check(point is not None, 'hittade kun- i textlagret')
        started = time.time()
        page.mouse.dblclick(point["x"] - 6, point["y"])
        page.wait_for_selector('.popup [data-testid="header"]', timeout=10000)
        elapsed = (time.time() - started) * 1000
        text = popup_text(page)
        header = page.locator('.popup [data-testid="header"]').inner_text()
        check(header.split('\n')[0].strip() == 'kunskap', f'avstavat ord blir kunskap: {header!r}')
        check('Visa i SO och SAOL' in text, 'knappen Visa i SO och SAOL finns')
        check('Ordet är sparat i Sparade ord.' in text, 'ordet sparas')
        print(f'     rutan efter {elapsed:.0f} ms (med Playwrights fördröjning)')
        page.screenshot(path=os.path.join(out, "03-pdf-svenskt-ord.png"))
        page.locator('[data-testid="svenska-se"]').click()
        page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.popup').count() == 0), 'Esc stänger rutan')

        # Ett vanligt svenskt ord
        point = page.evaluate(FIND_IN_TEXT_LAYER, ["Undersökningen", 0])
        page.mouse.dblclick(point["x"], point["y"])
        page.wait_for_selector('.popup [data-testid="header"]')
        text = popup_text(page)
        check('undersökning' in text and 'grundform till Undersökningen' in text, f'grundform för Undersökningen: {text[:120]!r}')
        page.keyboard.press('Escape')

        # Engelskt ord i PDF (sida 5)
        page.locator('.page-label').click()
        page.wait_for_selector('.dialog input')
        page.keyboard.type('5')
        page.keyboard.press('Enter')
        check(wait_for(lambda: '4 och 5' in page.locator('.page-label').inner_text()), 'Gå till sida 5 visar sida 4 och 5')
        page.wait_for_function("[...document.querySelectorAll('.pdf-spread .textLayer span')].some(s => s.textContent.includes('library'))")
        point = page.evaluate(FIND_IN_TEXT_LAYER, ["went", 0])
        page.mouse.dblclick(point["x"], point["y"])
        page.wait_for_selector('.popup [data-testid="header"]')
        text = popup_text(page)
        header = page.locator('.popup [data-testid="header"]').inner_text()
        check(header.split('\n')[0] == 'go' and 'engelska' in header, f'went har grundformen go: {header!r}')
        check(page.locator('.popup [data-testid="translation"]').count() == 1, f'svensk översättning överst: {text[:160]!r}')
        page.screenshot(path=os.path.join(out, "04-pdf-engelskt-ord.png"))
        page.keyboard.press('Escape')

        # Mushjul
        before = page.locator('.page-label').inner_text()
        page.mouse.move(640, 400)
        page.mouse.wheel(0, 120)
        check(wait_for(lambda: page.locator('.page-label').inner_text() != before), 'mushjulet bläddrar')
        pdf_label = page.locator('.page-label').inner_text()

        # Zoom med Ctrl och plus
        page.keyboard.press('Control+Equal')
        check(wait_for(lambda: page.locator('.pdf-spread.scroll').count() == 1), 'Ctrl och plus zoomar in (sidan rullas)')
        page.screenshot(path=os.path.join(out, "04a-pdf-zoom.png"))
        page.keyboard.press('Control+Digit0')
        check(wait_for(lambda: page.locator('.pdf-spread.two').count() == 1), 'Ctrl och 0 återställer till uppslag')
        pdf_label = page.locator('.page-label').inner_text()

        # Innehållsförteckning
        page.locator('[data-testid="toc-button"]').click()
        page.wait_for_selector('.toc-item')
        toc = page.locator('.toc-item').all_inner_texts()
        check('Kapitel 2: English' in toc, f'innehållsförteckning ur PDF:en: {toc}')
        page.keyboard.press('Escape')

        # Tema
        page.locator('[data-testid="theme-button"]').click()
        page.locator('[data-testid="theme-dark"]').click()
        check(wait_for(lambda: page.evaluate("document.documentElement.dataset.theme") == 'dark'), 'mörkt tema')
        time.sleep(0.4)
        page.screenshot(path=os.path.join(out, "05-pdf-morkt.png"))
        page.locator('[data-testid="theme-button"]').click()
        page.locator('[data-testid="theme-sepia"]').click()

        # Läspositionen överlever omladdning
        page.wait_for_timeout(700)
        page.reload()
        page.wait_for_selector('[data-testid="book"]')
        check(page.evaluate("document.documentElement.dataset.theme") == 'sepia', 'temat sparas')
        page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
        page.wait_for_selector('.pdf-spread .pdf-page canvas')
        check(wait_for(lambda: page.locator('.page-label').inner_text() == pdf_label), f'samma sida efter omladdning: {pdf_label}')
        page.screenshot(path=os.path.join(out, "06-pdf-sepia.png"))
        page.locator('.toolbar-button', has_text='Bibliotek').click()
        page.wait_for_selector('[data-testid="book"]')

        # EPUB
        page.locator('.book-card', has_text='Testbok för Läsa').locator('.book-cover').click()
        check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'EPUB-kapitel laddat')
        wait_for(lambda: page.locator('.page-label').inner_text().strip())
        label = page.locator('.page-label').inner_text()
        slider = page.locator('.page-slider').input_value()
        # Omslaget kan ta två sidor i uppslaget, så platsen ändras inte alltid efter en tryckning.
        moved = False
        for _ in range(3):
            page.keyboard.press('ArrowRight')
            if wait_for(lambda: page.locator('.page-label').inner_text() != label
                        or page.locator('.page-slider').input_value() != slider, 3):
                moved = True
                break
        check(moved, f'EPUB bläddrar med piltangent ({label} till {page.locator(".page-label").inner_text()})')
        page.wait_for_timeout(600)
        page.screenshot(path=os.path.join(out, "07-epub.png"))

        def epub_word(word):
            stage = page.locator('.reader-stage').bounding_box()
            for frame in page.frames:
                if not frame.url.startswith('blob:'):
                    continue
                box = frame.frame_element().bounding_box()
                left = stage["x"] - box["x"] + 10
                right = stage["x"] + stage["width"] - box["x"] - 10
                found = frame.evaluate(FIND_IN_FRAME, [word, left, right])
                if found:
                    return {"x": box["x"] + found["x"], "y": box["y"] + found["y"]}
            return None

        # Bläddra tills ett svenskt ord syns
        point = None
        for _ in range(8):
            point = epub_word("staden")
            if point:
                break
            page.keyboard.press('ArrowRight')
            page.wait_for_timeout(500)
        check(point is not None, 'hittade staden på en EPUB-sida')
        if point:
            page.mouse.dblclick(point["x"], point["y"])
            page.wait_for_selector('.popup [data-testid="header"]')
            text = popup_text(page)
            check('stad' in text.split('\n')[0] and 'grundform till staden' in text, f'svenskt ord i EPUB: {text[:120]!r}')
            page.screenshot(path=os.path.join(out, "08-epub-svenskt-ord.png"))
            page.keyboard.press('Escape')
            page.mouse.click(5, 5)

        # Engelska kapitlet via innehållsförteckningen
        page.locator('[data-testid="toc-button"]').click()
        page.locator('.toc-item').filter(has_text=re.compile(r'^(kap4|Kapitel 4: English)$')).click()
        page.wait_for_timeout(1200)
        point = epub_word("bridge") or epub_word("library") or epub_word("harbour")
        check(point is not None, 'hittade ett engelskt ord i kapitel 4')
        if point:
            page.mouse.click(point["x"], point["y"], button="right")
            page.wait_for_selector('.popup [data-testid="header"]')
            text = popup_text(page)
            check('engelska' in text and 'PÅ SVENSKA' in text.upper(), f'engelskt ord i EPUB med högerklick: {text[:160]!r}')
            page.screenshot(path=os.path.join(out, "09-epub-engelskt-ord.png"))
            page.keyboard.press('Escape')
        epub_label = page.locator('.page-label').inner_text()

        # Sparade ord som ruta över läsaren, och Slå upp därifrån
        page.locator('.toolbar-button', has_text='Sparade ord').click()
        page.wait_for_selector('.modal-panel [data-testid="saved-word"]')
        page.locator('.modal-panel [data-testid="saved-word"]').first.get_by_text('Slå upp').click()
        page.wait_for_selector('.popup [data-testid="header"]')
        box = page.locator('.popup').bounding_box()
        on_top = page.evaluate("([x, y]) => !!document.elementFromPoint(x, y)?.closest('.popup')",
                              [box["x"] + box["width"] / 2, box["y"] + 20])
        check(on_top, 'ordrutan syns ovanpå Sparade ord i läsaren')
        page.keyboard.press('Escape')
        page.wait_for_timeout(200)
        if page.locator('.modal-backdrop').count():
            page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.modal-backdrop').count() == 0), 'Esc stänger rutan över läsaren')

        # Typsnitt och storlek
        page.locator('.toolbar-button', has_text='Aa').click()
        page.locator('.font-choice', has_text='Verdana').click()
        page.locator('.reader-panel [aria-label="Större text"]').click()
        page.wait_for_timeout(800)
        page.screenshot(path=os.path.join(out, "10-epub-verdana.png"))
        page.keyboard.press('Escape')

        # Position i EPUB efter omladdning
        page.wait_for_timeout(700)
        epub_label = page.locator('.page-label').inner_text()
        page.reload()
        page.wait_for_selector('[data-testid="book"]')
        page.locator('.book-card', has_text='Testbok för Läsa').locator('.book-cover').click()
        check(wait_for(lambda: page.locator('.page-label').inner_text() == epub_label, 15),
              f'EPUB öppnas på samma plats efter omladdning: {epub_label} / {page.locator(".page-label").inner_text()}')
        page.locator('.toolbar-button', has_text='Bibliotek').click()
        page.wait_for_selector('[data-testid="book"]')

        # Markdown
        page.locator('.book-card').filter(has=page.get_by_text('test', exact=True)).first.locator('.book-cover').click()
        check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'Markdown-filen öppnas')
        page.wait_for_timeout(800)
        page.screenshot(path=os.path.join(out, "11-markdown.png"))
        page.locator('.toolbar-button', has_text='Bibliotek').click()

        # Sparade ord
        page.locator('[data-testid="tab-saved"]').click()
        page.wait_for_selector('[data-testid="saved-word"]')
        saved = page.locator('[data-testid="saved-word"]').all_inner_texts()
        check(len(saved) >= 4, f'{len(saved)} sparade ord')
        check(any('kunskap' in s for s in saved), 'kunskap finns bland sparade ord')
        page.screenshot(path=os.path.join(out, "12-sparade-ord.png"))

        # Om ordboken
        page.locator('[data-testid="tab-about"]').click()
        page.wait_for_selector('.about')
        about = page.locator('.about').inner_text()
        check('Byggd' in about and 'Synlex' in about and 'PDF.js' in about and 'foliate-js' in about, 'Om ordboken med källor och program')
        page.screenshot(path=os.path.join(out, "13-om-ordboken.png"), full_page=True)

        # En EPUB med skript: Content-Security-Policy ska stoppa dem (skripten skulle annars nå appen).
        console_before = len(console)
        page.locator('[data-testid="tab-library"]').click()
        page.set_input_files('[data-testid="file-input"]', [os.path.join(books, "skript.epub")])
        check(wait_for(lambda: page.locator('[data-testid="book"]').count() == 4, 20), 'EPUB med skript lades till')
        page.locator('.book-card', has_text='Skriptbok').locator('.book-cover').click()
        page.wait_for_timeout(2500)
        check(page.evaluate("document.title") != 'HACKAD' and not page.evaluate("window.hacked"),
              'skript i EPUB körs inte')
        blocked = [line for line in console[console_before:] if 'Content Security Policy' in line]
        check(bool(blocked), f'webbläsaren rapporterar att skripten stoppades ({len(blocked)} rader)')
        del console[console_before:]
        page.locator('.toolbar-button', has_text='Bibliotek').click()

        problems = [line for line in console if not any(known in line for known in KNOWN)]
        check(not problems, 'konsolen är tom' + ('' if not problems else ': ' + ' | '.join(problems[:8])))
        browser.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8955/")
    parser.add_argument("--books", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    run(args.url, args.books, args.out)
    print(f"\n{len(FAILURES)} fel")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
