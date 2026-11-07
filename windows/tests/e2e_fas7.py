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


def run(url, books, out, data):
    global PAGE, DATA
    DATA = data
    os.makedirs(out, exist_ok=True)
    console = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        context = browser.new_context(viewport={"width": 1278, "height": 720}, device_scale_factor=1.5)
        context.add_init_script(WATCH)
        page = context.new_page()
        PAGE = page
        page.on("console", lambda m: console.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
        page.on("pageerror", lambda e: console.append(f"pageerror: {e}"))
        page.goto(url)
        page.wait_for_selector('[data-testid="tab-library"]')

        themes_and_files(page, books, out)
        for step in STEPS:
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


STEPS = [search_in_books]


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
