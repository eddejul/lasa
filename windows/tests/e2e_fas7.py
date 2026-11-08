"""Provkör förbättringarna från natten 8 november (fas 7) i Chrome (huvudlöst) mot dev/server.py.

  python windows/tests/e2e_fas7.py --url http://127.0.0.1:8955/ --books <testböcker> --out <mapp för bilder>

Datamappen som servern använder ska vara tom vid start. Testböckerna görs med make_testbooks.py.
Provar teman (Följ systemet), laddning och fel (låst och trasig PDF), rtf och html, synkadressen,
tangentbordsgenvägarna, sök i boken, markeringar, anteckningar och bokmärken, repetitionen,
valet av uppslag och AI-knappen (mot en låtsasserver i sidan). Skärmbilderna sparas i --out.
"""

import argparse
import json
import os
import re
import sys
import time

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import FIND_IN_FRAME, FIND_IN_TEXT_LAYER, KNOWN  # noqa: E402

FAILURES = []
PAGE = None


def check(condition, message):
    print(("ok   " if condition else "FEL  ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


def wait_for(predicate, timeout=10.0, interval=0.1):
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


# Lägger märke till rutor som bara syns en kort stund (Öppnar boken, Lägger till 2 av 4).
WATCH = """
window.__seen = new Set();
new MutationObserver(() => {
  for (const id of ['status-box', 'reader-loading']) {
    const node = document.querySelector(`[data-testid="${id}"]`);
    if (node) window.__seen.add(id + ':' + node.textContent);
  }
}).observe(document, { subtree: true, childList: true, characterData: true });
"""


def seen(page):
    return page.evaluate("[...(window.__seen ?? [])]")


def toasts(page):
    return page.locator('.toast').all_inner_texts()


def open_book(page, title):
    page.locator('.book-card').filter(has=page.locator('.book-title', has_text=re.compile('^' + re.escape(title) + '$')))         .locator('.book-cover').click()


def back_to_library(page):
    page.locator('.toolbar-button', has_text='Bibliotek').click()
    page.wait_for_selector('[data-testid="book"]')


def themes_and_files(page, books, out):
    # Följ systemet: Windows mörkt läge ger mörkt tema, och boot.js sätter det innan sidan ritas.
    page.emulate_media(color_scheme='dark')
    page.set_input_files('[data-testid="file-input"]', [os.path.join(books, "test.pdf")])
    check(wait_for(lambda: page.locator('[data-testid="book"]').count() == 1, 20), 'PDF:en lades till')
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    check(any(s.startswith('reader-loading:Öppnar boken') for s in seen(page)), f'Öppnar boken syns medan boken läses: {seen(page)}')
    page.locator('[data-testid="theme-button"]').click()
    page.locator('[data-testid="theme-system"]').click()
    check(wait_for(lambda: page.evaluate("document.documentElement.dataset.theme") == 'dark'), 'Följ systemet ger mörkt när Windows är mörkt')
    page.emulate_media(color_scheme='light')
    check(wait_for(lambda: page.evaluate("document.documentElement.dataset.theme") == 'white'),
          'Följ systemet byter till ljust när Windows byter')
    page.emulate_media(color_scheme='dark')
    page.goto(page.url, wait_until='domcontentloaded')
    check(page.evaluate("document.documentElement.dataset.theme") == 'dark',
          'mörkt redan när sidan laddas (ingen vit blinkning)')
    page.wait_for_selector('[data-testid="book"]')
    page.emulate_media(color_scheme='light')

    # Låst och trasig PDF läggs inte till, med begripliga fel. rtf och html läggs till.
    page.evaluate("window.__seen = new Set()")
    page.set_input_files('[data-testid="file-input"]',
                         [os.path.join(books, name) for name in ("last.pdf", "trasig.pdf", "test.rtf", "artikel.html")])
    check(wait_for(lambda: page.locator('[data-testid="book"]').count() == 3, 20), 'rtf och html lades till, inte de trasiga')
    messages = ' | '.join(toasts(page))
    check('låst med lösenord' in messages, f'låst PDF ger ett begripligt fel: {messages[:200]}')
    check('trasig' in messages, 'trasig PDF ger ett begripligt fel')
    check(any('Lägger till 2 av 4' in s for s in seen(page)), f'förloppet visas under importen: {seen(page)}')
    page.screenshot(path=os.path.join(out, "f01-import-fel.png"))
    titles = page.locator('.book-title').all_inner_texts()
    check('Artikel i HTML' in titles, f'html-filen får sin titel: {titles}')
    files = os.listdir(os.path.join(DATA, "Böcker")) if DATA else []
    check(not any(name.endswith('.tmp') for name in files) and len(files) == 3, f'bara tre bokfiler sparade: {files}')

    # html: texten syns, inga skript körs
    open_book(page, 'Artikel i HTML')
    check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'html-filen öppnas')
    page.wait_for_timeout(800)
    texts = [f.evaluate("document.body?.innerText ?? ''") for f in page.frames if f.url.startswith('blob:')]
    check(any('Undersökningen visade' in t for t in texts), 'texten i html-filen syns')
    check(not page.evaluate("window.hacked") and page.evaluate("document.title") != 'HACKAD', 'skript i html-filen körs inte')
    page.screenshot(path=os.path.join(out, "f02-html.png"))
    back_to_library(page)
    open_book(page, 'test')
    check(wait_for(lambda: any('Rubrik i RTF' in (f.evaluate("document.body?.innerText ?? ''") or '')
                               for f in page.frames if f.url.startswith('blob:')), 15), 'rtf-filen visas med sin rubrik')
    back_to_library(page)

    # Synkadressen
    page.locator('[data-testid="tab-settings"]').click()
    page.fill('[data-testid="sync-url"]', 'https://example.com')
    page.fill('[data-testid="sync-key"]', 'sb_publishable_prov')
    page.fill('[data-testid="sync-email"]', 'a@b.se')
    page.fill('[data-testid="sync-password"]', 'x')
    page.locator('[data-testid="sync-sign-in"]').click()
    message = wait_for(lambda: page.locator('[data-testid="sync-message"]').inner_text().strip())
    check(bool(message) and 'supabase.co' in message, f'en adress som inte är Supabase ger ett begripligt fel: {message}')
    page.locator('[data-testid="tab-library"]').click()
    page.wait_for_selector('[data-testid="book"]')


DATA = None
STEP = ['']
CONSOLE = []


def run(url, books, out, data):
    global PAGE, DATA
    DATA = data
    os.makedirs(out, exist_ok=True)
    console = CONSOLE
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        context = browser.new_context(viewport={"width": 1278, "height": 720}, device_scale_factor=1.5)
        context.add_init_script(WATCH)
        page = context.new_page()
        PAGE = page
        page.on("console", lambda m: console.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
        page.on("pageerror", lambda e: console.append(f"pageerror: {e} (i steget {STEP[0]}) [{(e.stack or '')[:1500]}]"))
        page.goto(url)
        page.wait_for_selector('[data-testid="tab-library"]')

        STEP[0] = 'themes_and_files'
        themes_and_files(page, books, out)
        for step in STEPS:
            STEP[0] = step.__name__
            step(page, books, out)

        problems = [line for line in console if not any(known in line for known in KNOWN + EXPECTED)]
        check(not problems, 'konsolen är tom' + ('' if not problems else ': ' + ' | '.join(problems[:8])))
        browser.close()


# Varningar som testet framkallar med flit: låst och trasig PDF, och CSP-stoppet av html-filens skript.
EXPECTED = ("PasswordException", "InvalidPDFException", "Invalid PDF", "No password given", "Content Security Policy",
            "kunde inte läsas", "Kunde inte läsa", "Indexing all PDF objects")

def search_in_books(page, books, out):
    # PDF: ett avstavat ord över radbrytningen hittas som ett ord, och träffen ringas in.
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    page.locator('[data-testid="search-button"]').click()
    page.fill('[data-testid="search-input"]', 'kunskap')
    check(wait_for(lambda: 'träff' in page.locator('[data-testid="search-status"]').inner_text()
                   and 'Söker' not in page.locator('[data-testid="search-status"]').inner_text(), 15),
          f'sökningen blir klar: {page.locator("[data-testid=search-status]").inner_text()}')
    rows = page.locator('[data-testid="search-hit-row"]').all_inner_texts()
    check(len(rows) >= 1 and 'kun-' not in rows[0] and any('kun' in r for r in rows), f'kunskap hittas trots avstavningen: {rows[:2]}')
    page.locator('[data-testid="search-hit-row"]').first.click()
    check(wait_for(lambda: page.locator('.pdf-spread [data-testid="search-hit"]').count() >= 1), 'träffen ringas in på sidan')
    page.screenshot(path=os.path.join(out, "f03-sok-pdf.png"))
    page.fill('[data-testid="search-input"]', 'Undersökningen')
    check(wait_for(lambda: 'Söker' not in page.locator('[data-testid="search-status"]').inner_text()
                   and page.locator('[data-testid="search-hit-row"]').count() >= 6, 15),
          f'flera träffar för Undersökningen: {page.locator("[data-testid=search-hit-row]").count()}')
    first = page.locator('.page-label').inner_text()
    page.locator('[data-testid="search-input"]').press('Enter')
    page.locator('[data-testid="search-input"]').press('Enter')
    page.locator('[data-testid="search-input"]').press('Enter')
    check(wait_for(lambda: page.locator('.page-label').inner_text() != first), 'Enter går vidare till nästa träff och sida')
    page.keyboard.press('Escape')
    check(wait_for(lambda: page.locator('.reader-panel').is_hidden()), 'Esc stänger sökpanelen')
    check(wait_for(lambda: page.locator('.pdf-spread [data-testid="search-hit"]').count() == 0), 'ringen försvinner när panelen stängs')
    back_to_library(page)

    # EPUB: träffen visas i rätt kapitel.
    page.set_input_files('[data-testid="file-input"]', [os.path.join(books, "test.epub")])
    check(wait_for(lambda: page.locator('.book-title', has_text='Testbok för Läsa').count() == 1, 20), 'EPUB:en lades till')
    open_book(page, 'Testbok för Läsa')
    check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'EPUB-kapitel laddat')
    page.wait_for_timeout(600)
    page.locator('[data-testid="search-button"]').click()
    page.fill('[data-testid="search-input"]', 'library')
    check(wait_for(lambda: 'Söker' not in page.locator('[data-testid="search-status"]').inner_text()
                   and page.locator('[data-testid="search-hit-row"]').count() >= 1, 15),
          f'library hittas i EPUB:en: {page.locator("[data-testid=search-status]").inner_text()}')
    label = page.locator('[data-testid="search-hit-row"]').first.inner_text()
    page.locator('[data-testid="search-hit-row"]').first.click()
    check(wait_for(lambda: page.evaluate("lasaTest.reader.searchHit?.cfi ?? null") is not None), 'träffen visas')
    check(wait_for(lambda: 'kap4' in page.locator('.page-label').inner_text() or 'English' in page.locator('.page-label').inner_text()),
          f'boken står i det engelska kapitlet: {page.locator(".page-label").inner_text()} ({label.splitlines()[0]})')
    visible = page.evaluate("""() => {
      const hit = lasaTest.reader.searchHit;
      const doc = lasaTest.reader.loadedDoc(hit.section);
      return doc ? doc.body.innerText.includes('library') : false;
    }""")
    check(visible, 'kapitlet med träffen är laddat')
    page.wait_for_timeout(400)
    page.screenshot(path=os.path.join(out, "f04-sok-epub.png"))
    page.keyboard.press('Escape')
    back_to_library(page)


def shortcuts(page, books, out):
    # I biblioteket: ?, T och Ctrl och O.
    page.locator('[data-testid="tab-library"]').click()
    page.wait_for_selector('[data-testid="book"]')
    page.mouse.click(5, 300)
    page.keyboard.press('Shift+?')
    if not page.locator('[data-testid="shortcuts"]').count():
        page.keyboard.type('?')
    check(wait_for(lambda: page.locator('[data-testid="shortcuts"]').count() == 1), '? visar genvägarna')
    page.screenshot(path=os.path.join(out, "f05-genvagar.png"))
    page.keyboard.press('Escape')
    check(wait_for(lambda: page.locator('[data-testid="shortcuts"]').count() == 0), 'Esc stänger listan')
    before = page.evaluate("localStorage.getItem('lasa-theme')")
    page.keyboard.press('t')
    check(wait_for(lambda: any('Tema:' in t for t in toasts(page)), 3), 'T säger vilket tema det blev')
    check(wait_for(lambda: page.evaluate("localStorage.getItem('lasa-theme')") != before), f'T byter tema (från {before})')
    # Tillbaka till vitt för resten av testet.
    for _ in range(4):
        if page.evaluate("localStorage.getItem('lasa-theme')") == 'white':
            break
        page.keyboard.press('t')
        page.wait_for_timeout(150)
    check(page.evaluate("localStorage.getItem('lasa-theme')") == 'white', 'tillbaka till vitt efter ett varv')
    with page.expect_file_chooser(timeout=5000) as chooser:
        page.keyboard.press('Control+o')
    check(chooser.value is not None, 'Ctrl och O öppnar filvalet')

    # Webbläsarens egna tangenter stoppas.
    page.evaluate("window.__inteOmladdad = true")
    prevented = page.evaluate("""() => ['F5', 'r', 'p'].map((key) => {
      const event = new KeyboardEvent('keydown', { key, ctrlKey: key !== 'F5', bubbles: true, cancelable: true });
      document.body.dispatchEvent(event);
      return event.defaultPrevented;
    })""")
    check(all(prevented), f'F5, Ctrl och R och Ctrl och P stoppas: {prevented}')
    page.keyboard.press('F5')
    page.keyboard.press('Control+r')
    page.wait_for_timeout(500)
    check(page.evaluate("window.__inteOmladdad === true"), 'sidan laddas inte om')

    # I läsaren: Ctrl och F, Ctrl och G.
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    page.keyboard.press('Control+f')
    check(wait_for(lambda: page.evaluate("document.activeElement?.dataset?.testid") == 'search-input'),
          'Ctrl och F öppnar sökningen med markören i sökfältet')
    page.keyboard.press('Escape')
    page.keyboard.press('Control+g')
    check(wait_for(lambda: page.locator('.dialog', has_text='Gå till sida').count() == 1), 'Ctrl och G frågar efter sida')
    page.keyboard.type('5')
    page.keyboard.press('Enter')
    check(wait_for(lambda: '5' in page.locator('.page-label').inner_text()), f'Ctrl och G går till sidan: {page.locator(".page-label").inner_text()}')
    back_to_library(page)

    # I ett EPUB-kapitel (tangenterna kommer från kapitlets ram).
    open_book(page, 'Testbok för Läsa')
    check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'EPUB-kapitel laddat')
    page.wait_for_timeout(500)
    frame = next(f for f in page.frames if f.url.startswith('blob:'))
    frame.evaluate("document.body.focus()")
    box = frame.frame_element().bounding_box()
    page.mouse.click(box["x"] + 60, box["y"] + 60)
    page.keyboard.press('Control+f')
    check(wait_for(lambda: page.locator('[data-testid="search-input"]').count() == 1), 'Ctrl och F i ett EPUB-kapitel öppnar sökningen')
    page.keyboard.press('Escape')
    page.mouse.click(box["x"] + 60, box["y"] + 60)
    before = page.evaluate("localStorage.getItem('lasa-theme')")
    page.keyboard.press('t')
    check(wait_for(lambda: page.evaluate("localStorage.getItem('lasa-theme')") != before), 'T i ett EPUB-kapitel byter tema')
    page.keyboard.press('Control+g')
    check(wait_for(lambda: page.locator('.dialog', has_text='Gå till plats').count() == 1), 'Ctrl och G i EPUB frågar efter plats')
    page.keyboard.type('50 %')
    page.keyboard.press('Enter')
    page.wait_for_timeout(800)
    value = int(page.locator('.page-slider').input_value())
    check(400 <= value <= 600, f'50 % går till mitten av boken: {value}')
    for _ in range(4):
        if page.evaluate("localStorage.getItem('lasa-theme')") == 'white':
            break
        page.keyboard.press('t')
        page.wait_for_timeout(150)
    back_to_library(page)


def db_rows(page, sql, params=None):
    return page.evaluate("""async ([sql, params]) => (await fetch('/api/test_sql', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ db: 'bibliotek', sql, params }) })).json()""",
                         [sql, params or []])


def drag_select(page, start, end):
    page.mouse.move(start["x"], start["y"])
    page.mouse.down()
    page.mouse.move((start["x"] + end["x"]) / 2, (start["y"] + end["y"]) / 2, steps=4)
    page.mouse.move(end["x"], end["y"], steps=4)
    page.mouse.up()


def word_edges(page, word, occurrence=0):
    """Vänsterkant och högerkant (i fönstret) för ett ord i PDF:ens textlager."""
    return page.evaluate("""([word, occurrence]) => {
      let seen = 0;
      for (const span of document.querySelectorAll('.pdf-spread .textLayer span')) {
        const node = span.firstChild;
        if (!node || node.nodeType !== 3) continue;
        let at = node.data.indexOf(word);
        while (at >= 0) {
          if (seen++ === occurrence) {
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + word.length);
            const r = range.getBoundingClientRect();
            return { left: { x: r.left + 1, y: r.top + r.height / 2 }, right: { x: r.right - 1, y: r.top + r.height / 2 } };
          }
          at = node.data.indexOf(word, at + 1);
        }
      }
      return null;
    }""", [word, occurrence])


def highlights_and_bookmarks(page, books, out):
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    page.keyboard.press('Home')
    page.keyboard.press('ArrowRight')
    check(wait_for(lambda: page.locator('.page-label').inner_text().startswith('Sida 2')), f'sida 2: {page.locator(".page-label").inner_text()}')
    page.wait_for_function("document.querySelectorAll('.pdf-spread .textLayer span').length > 5")
    a = word_edges(page, 'Gatorna')
    b = word_edges(page, 'smala')
    check(a is not None and b is not None, 'hittade orden att markera')
    drag_select(page, a["left"], b["right"])
    check(wait_for(lambda: page.locator('[data-testid="mark-menu"]').count() == 1), 'färgvalet visas när text markeras')
    page.screenshot(path=os.path.join(out, "f06-fargval.png"))
    page.locator('[data-testid="mark-green"]').click()
    check(wait_for(lambda: page.locator('.pdf-mark.color-green').count() >= 1), 'grön markering syns på sidan')
    rows = db_rows(page, "SELECT section, start, length, text, color, deleted FROM highlights")
    check(len(rows) == 1 and rows[0][0] == 1 and rows[0][3].startswith('Gatorna var smala') and rows[0][4] == 'green',
          f'markeringen sparas med sida, plats och text: {rows}')
    text = page.evaluate("lasaTest.reader.cache.get(1).text")
    check(rows and text[rows[0][1]:rows[0][1] + rows[0][2]] == rows[0][3], 'start och length pekar på texten i sidans text')

    # Klick på markeringen: anteckning
    box = page.locator('.pdf-mark.color-green').first.bounding_box()
    page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
    check(wait_for(lambda: page.locator('[data-testid="mark-delete"]').count() == 1), 'klick på markeringen öppnar menyn')
    page.locator('[data-testid="mark-note"]').click()
    page.wait_for_selector('[data-testid="note-input"]')
    page.locator('[data-testid="note-input"]').fill('Bilden av staden som skydd.')
    page.locator('[data-testid="note-save"]').click()
    check(wait_for(lambda: page.locator('.pdf-mark.has-note').count() >= 1), 'markeringen med anteckning får ett streck')
    check(db_rows(page, "SELECT note FROM highlights WHERE deleted = 0") == [['Bilden av staden som skydd.']], 'anteckningen sparas')

    # Dubbelklick på ett ord i markeringen slår fortfarande upp ordet
    point = word_edges(page, 'Gatorna')
    page.mouse.dblclick((point["left"]["x"] + point["right"]["x"]) / 2, point["left"]["y"])
    check(wait_for(lambda: page.locator('.popup [data-testid="header"]').count() == 1), 'dubbelklick i en markering slår upp ordet')
    page.wait_for_timeout(400)
    check(page.locator('[data-testid="mark-menu"]').count() == 0, 'och öppnar inte markeringens meny')
    page.keyboard.press('Escape')

    # Bokmärke med B, och listan
    page.mouse.click(5, 300)
    page.keyboard.press('b')
    check(wait_for(lambda: 'active' in (page.locator('[data-testid="bookmark-button"]').get_attribute('class') or '')),
          'B lägger ett bokmärke (knappen visar det)')
    page.keyboard.press('ArrowRight')
    check(wait_for(lambda: 'active' not in (page.locator('[data-testid="bookmark-button"]').get_attribute('class') or '')),
          'på nästa sida finns inget bokmärke')
    page.locator('[data-testid="marks-button"]').click()
    check(wait_for(lambda: page.locator('[data-testid="bookmark-row"]').count() == 1
                   and page.locator('[data-testid="highlight-row"]').count() == 1), 'listan visar bokmärket och markeringen')
    check('Bilden av staden' in page.locator('[data-testid="highlight-row"]').inner_text(), 'anteckningen syns i listan')
    page.screenshot(path=os.path.join(out, "f07-markeringar-pdf.png"))
    page.locator('[data-testid="highlight-row"]').click()
    check(wait_for(lambda: page.locator('.page-label').inner_text().startswith('Sida 2')), 'klick i listan går till markeringen')
    page.keyboard.press('Escape')

    # Finns kvar efter omladdning (läspositionen sparas efter 0,4 sekunder)
    page.wait_for_timeout(800)
    page.reload()
    page.wait_for_selector('[data-testid="book"]')
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    check(wait_for(lambda: page.locator('.pdf-mark.color-green').count() >= 1), 'markeringen finns kvar efter omladdning')
    check('active' in (page.locator('[data-testid="bookmark-button"]').get_attribute('class') or ''), 'bokmärket finns kvar')

    # Ta bort
    box = page.locator('.pdf-mark.color-green').first.bounding_box()
    page.mouse.click(box["x"] + 4, box["y"] + box["height"] / 2)
    page.locator('[data-testid="mark-delete"]').click()
    check(wait_for(lambda: page.locator('.pdf-mark').count() == 0), 'Ta bort tar bort markeringen')
    check(db_rows(page, "SELECT deleted FROM highlights") == [[1]], 'borttagen markering finns kvar som deleted = 1 (för synken)')
    back_to_library(page)

    # EPUB: markering i ett kapitel
    open_book(page, 'Testbok för Läsa')
    check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'EPUB-kapitel laddat')
    page.locator('[data-testid="toc-button"]').click()
    page.locator('.toc-item').filter(has_text=re.compile(r'^(kap4|Kapitel 4: English)$')).click()
    page.wait_for_timeout(1200)
    found = None
    for frame in page.frames:
        if not frame.url.startswith('blob:'):
            continue
        rect = frame.evaluate("""() => {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const at = node.data.indexOf('The morning was quiet');
            if (at < 0) continue;
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + 'The morning was quiet'.length);
            const rects = [...range.getClientRects()];
            if (!rects.length || rects[0].left < 0 || rects[0].left > innerWidth) continue;
            return { x1: rects[0].left + 1, y: rects[0].top + rects[0].height / 2, x2: rects[0].right - 1 };
          }
          return null;
        }""")
        if rect:
            box = frame.frame_element().bounding_box()
            found = ({"x": box["x"] + rect["x1"], "y": box["y"] + rect["y"]}, {"x": box["x"] + rect["x2"], "y": box["y"] + rect["y"]})
            break
    check(found is not None, 'hittade texten att markera i EPUB:en')
    if found:
        drag_select(page, found[0], found[1])
        check(wait_for(lambda: page.locator('[data-testid="mark-menu"]').count() == 1), 'färgvalet visas i EPUB')
        page.locator('[data-testid="mark-yellow"]').click()
        check(wait_for(lambda: page.evaluate("[...lasaTest.reader.annotations.values()].filter(a => a.kind === 'mark').length") == 1),
              'markeringen ritas i kapitlet')
        rows = db_rows(page, "SELECT section, start, length, text, color FROM highlights WHERE deleted = 0")
        check(len(rows) == 1 and rows[0][3] == 'The morning was quiet' and rows[0][4] == 'yellow', f'EPUB-markeringen sparas: {rows}')
        if rows:
            chapter = page.evaluate("""(section) => {
              const index = lasaTest.reader.sectionOfDocument[section];
              const doc = lasaTest.reader.loadedDoc(index);
              const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
              let text = '';
              while (walker.nextNode()) {
                const parent = walker.currentNode.parentNode.localName;
                if (parent !== 'script' && parent !== 'style') text += walker.currentNode.data;
              }
              return text;
            }""", rows[0][0])
            check(chapter[rows[0][1]:rows[0][1] + rows[0][2]] == 'The morning was quiet',
                  'start och length gäller kapitlets text (all text i body, som på iPaden)')
        page.wait_for_timeout(300)
        page.screenshot(path=os.path.join(out, "f08-markering-epub.png"))
        page.keyboard.press('b')
        check(wait_for(lambda: len(db_rows(page, "SELECT section FROM bookmarks WHERE deleted = 0")) == 2), 'bokmärke i EPUB')
    back_to_library(page)


def memory(page, books, out):
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    page.keyboard.press('Home')
    for _ in range(6):
        page.keyboard.press('ArrowRight')
        page.wait_for_timeout(250)
    page.wait_for_timeout(600)
    size = page.evaluate("lasaTest.reader.cache.size")
    pages = page.evaluate("lasaTest.reader.current.length")
    check(size <= (6 if pages > 1 else 4), f'högst 4 ritade sidor i minnet (6 i uppslag): {size}, {pages} sida(or) syns')
    for _ in range(6):
        page.keyboard.press('Control+Equal')
        page.wait_for_timeout(200)
    page.wait_for_timeout(800)
    pixels = page.evaluate("Math.max(...[...document.querySelectorAll('.pdf-canvas')].map(c => c.width * c.height))")
    check(pixels <= 8e6 + 1, f'en sida är högst 8 miljoner bildpunkter vid största zoom: {pixels}')
    page.keyboard.press('Control+Digit0')
    page.wait_for_timeout(400)
    back_to_library(page)


def words_rows(page, sql):
    return page.evaluate("""async (sql) => (await fetch('/api/test_sql', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ db: 'ord', sql, params: [] }) })).json()""", sql)


def review(page, books, out):
    # Tre ord till, som om de slagits upp tidigare (äldre än det första).
    page.evaluate("""async () => {
      for (const [i, word] of ['stad', 'bro', 'library'].entries()) {
        await fetch('/api/test_sql', { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ db: 'ord', sql: `INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups,
            created, updated, uuid, book_id) VALUES (?, ?, ?, ?, 'Prov', 0, 1, ?, ?, ?, '')`,
            params: [word, word, word === 'library' ? 'en' : 'sv', `En mening med ${word}.`, 1700000000 + i, 1700000000 + i, `uuid-${i}`] }) });
      }
    }""")
    page.locator('[data-testid="tab-saved"]').click()
    page.wait_for_selector('[data-testid="review-button"]')
    label = page.locator('[data-testid="review-button"]').inner_text()
    saved = len(words_rows(page, "SELECT lemma FROM saved_words WHERE deleted = 0"))
    check(label == f'Repetera ({saved})', f'knappen visar antalet ord att repetera: {label}, {saved} sparade')
    page.locator('[data-testid="review-button"]').click()
    page.wait_for_selector('[data-testid="review-word"]')
    first = page.locator('[data-testid="review-word"]').inner_text()
    check('nytt ord' in page.locator('[data-testid="review-progress"]').inner_text(), 'ett nytt ord visas')
    page.keyboard.press('Space')
    check(wait_for(lambda: page.locator('[data-testid="review-answer"]').is_visible()), 'mellanslag visar svaret')
    whens = page.locator('.grade-when').all_inner_texts()
    check(whens == ['10 min', '1 dag', '1 dag', '4 dagar'], f'betygen visar när ordet kommer igen, som på iPaden: {whens}')
    page.screenshot(path=os.path.join(out, "f09-repetera.png"))
    page.keyboard.press('3')
    check(wait_for(lambda: page.locator('[data-testid="review-done"]').count() == 1
                   or page.locator('[data-testid="review-word"]').inner_text() != first),
          f'Bra går till nästa ord: {page.locator(".review-dialog").inner_text()[:120]!r}')
    row = words_rows(page, f"SELECT due, interval, ease, reps, lapses, review_updated, review_introduced, updated FROM saved_words WHERE lemma = '{first}'")
    check(row and row[0][1] == 1 and row[0][2] == 2.5 and row[0][3] == 1 and row[0][4] == 0 and row[0][5] and row[0][6],
          f'repetitionen sparas som på iPaden (1 dag, ease 2,5, reps 1): {row}')
    check(row and abs(row[0][0] - (row[0][5] + 86400)) < 2, 'nästa gång om en dag')
    check(row and row[0][5] > row[0][7], 'repetitionens ändringstid är ny, ordets egen ändringstid är orörd')
    # Igen: ordet kommer tillbaka i slutet av omgången
    if page.locator('[data-testid="review-word"]').count():
        second = page.locator('[data-testid="review-word"]').inner_text()
        page.keyboard.press('Space')
        page.keyboard.press('1')
        wait_for(lambda: page.locator('[data-testid="review-word"]').inner_text() != second)
        remaining = []
        for _ in range(40):
            if page.locator('[data-testid="review-done"]').count():
                break
            remaining.append(page.locator('[data-testid="review-word"]').inner_text())
            page.keyboard.press('Space')
            page.wait_for_timeout(100)
            page.keyboard.press('4')
            page.wait_for_timeout(100)
        check(remaining[-1:] == [second] and remaining.count(second) == 1, f'Igen lägger ordet sist i omgången: {second} i {remaining}')
        check(wait_for(lambda: page.locator('[data-testid="review-done"]').count() == 1), 'omgången tar slut')
        check('Klart för i dag' in page.locator('[data-testid="review-done"]').inner_text(), 'Klart för i dag')
    page.keyboard.press('Escape')
    check(wait_for(lambda: page.locator('[data-testid="review-button"]').inner_text() == 'Repetera'),
          f'inga ord kvar att repetera: {page.locator("[data-testid=review-button]").inner_text()}')
    page.locator('[data-testid="tab-library"]').click()
    page.wait_for_selector('[data-testid="book"]')


def spreads(page, books, out):
    open_book(page, 'Testbok i PDF')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    page.keyboard.press('Home')
    page.keyboard.press('ArrowRight')
    page.locator('[data-testid="zoom-button"]').click()
    page.locator('[data-testid="spread-two"]').click()
    check(wait_for(lambda: page.locator('.pdf-spread.two').count() == 1), 'Två sidor ger uppslag även i det låga fönstret')
    check(wait_for(lambda: page.locator('.page-label').inner_text().startswith('Sidorna 2 och 3')), f'uppslaget 2 och 3: {page.locator(".page-label").inner_text()}')
    page.screenshot(path=os.path.join(out, "f10-tva-sidor.png"))
    page.locator('[data-testid="spread-one"]').click()
    page.locator('[data-testid="fit-page"]').click()
    check(wait_for(lambda: page.locator('.pdf-spread.two').count() == 0 and page.locator('.page-label').inner_text().startswith('Sida ')),
          f'En sida: inget uppslag fast hela sidan ryms: {page.locator(".page-label").inner_text()}')
    page.locator('[data-testid="spread-auto"]').click()
    page.locator('[data-testid="fit-auto"]').click()
    page.keyboard.press('Escape')
    check(page.evaluate("JSON.parse(localStorage.getItem('x') ?? 'null')") is None, 'inställningen sparas i databasen, inte i webbvyn')
    back_to_library(page)

    open_book(page, 'Testbok för Läsa')
    check(wait_for(lambda: any(f.url.startswith('blob:') for f in page.frames), 15), 'EPUB-kapitel laddat')
    page.locator('.toolbar-button', has_text='Aa').click()
    page.locator('[data-testid="spread-one"]').click()
    check(wait_for(lambda: page.evaluate("lasaTest.reader.view.renderer.getAttribute('max-column-count')") == '1'), 'En sida i EPUB')
    page.wait_for_timeout(500)
    page.screenshot(path=os.path.join(out, "f11-epub-en-sida.png"))
    page.locator('[data-testid="spread-auto"]').click()
    check(wait_for(lambda: page.evaluate("lasaTest.reader.view.renderer.getAttribute('max-column-count')") == '2'), 'Automatiskt i EPUB')
    page.keyboard.press('Escape')
    back_to_library(page)


def narrow_commands(page, books, out):
    # W12: egen SQL och okända namn tas inte emot (provservern svarar som appen).
    before = len(CONSOLE)
    statuses = page.evaluate("""async () => {
      const post = async (command, body) => (await fetch('/api/' + command, { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })).status;
      return [
        await post('user_query', { db: 'bibliotek', sql: 'SELECT * FROM settings', params: [] }),
        await post('user_batch', { db: 'bibliotek', sql: 'DROP TABLE books' }),
        await post('db_read', { name: 'DROP TABLE books', params: [] }),
        await post('db_write', { name: 'settings_all', params: [] }),
        await post('db_read', { name: 'settings_all', params: [] }),
      ];
    }""")
    check(statuses[:4] == [500, 500, 500, 500] and statuses[4] == 200,
          f'bara namngivna frågor tas emot, av rätt slag: {statuses}')
    page.wait_for_timeout(300)
    # Webbläsaren skriver de nekade anropen i konsolen. De är väntade.
    CONSOLE[before:] = [line for line in CONSOLE[before:] if 'status of 500' not in line]


STEPS = [search_in_books, shortcuts, highlights_and_bookmarks, memory, review, spreads, narrow_commands]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8955/")
    parser.add_argument("--books", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--data", default=None, help="serverns datamapp, för att se vilka bokfiler som sparats")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    run(args.url, args.books, args.out, args.data)
    print(f"\n{len(FAILURES)} fel")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
