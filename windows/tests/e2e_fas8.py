"""Provkör Windows-spår 2 (natten 8 november, fas 8) i Chrome (huvudlöst) mot dev/server.py.

  python windows/tests/e2e_fas8.py --dictionary <lasa-ordbok.sqlite> --books <testböcker> --out <mapp> [--port 8963]

Testet startar själv dev/server.py (på --port, en process i taget, stoppas på sitt eget PID) med egna
datamappar under --out:
* G3: en datamapp med påhittade data från version 0.7.0 (bok-id = SHA-256), flytten till bokens id med
  kopian före, en andra start, namnbyte, ny version, Behåll båda, Ersätt och börja om, Ta bort och
  tillbaka, och liknande namn på en borttagen bok.
* W10: Rulla och Bläddra, uppslaget, ordfunktionen, markeringar, sök och läspositionen i båda lägena.
Testböckerna görs med make_testbooks.py. Skärmbilderna sparas i --out.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e import FIND_IN_TEXT_LAYER, KNOWN  # noqa: E402

SERVER = os.path.join(HERE, "..", "dev", "server.py")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
FAILURES = []
PAGE = None
CONSOLE = []


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
        if PAGE is not None:
            PAGE.wait_for_timeout(interval * 1000)
        else:
            time.sleep(interval)
    return None


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Server:
    """dev/server.py som egen process. Stoppas på sitt eget PID, aldrig på namn."""

    def __init__(self, dictionary, data, port, log):
        self.url = f"http://127.0.0.1:{port}/"
        self.log = open(log, "a", encoding="utf-8")
        self.process = subprocess.Popen([sys.executable, SERVER, "--dictionary", dictionary, "--data", data,
                                         "--port", str(port)], stdout=self.log, stderr=self.log)
        print(f"server PID {self.process.pid} på port {port}, data {data}", flush=True)
        ready = False
        for _ in range(100):
            try:
                urllib.request.urlopen(self.url, timeout=1).read()
                ready = True
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.1)
        if not ready:
            raise RuntimeError("servern startade inte")

    def api(self, command, args):
        request = urllib.request.Request(self.url + "api/" + command, data=json.dumps(args).encode("utf-8"),
                                         headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read() or b"null")

    def sql(self, sql, params=None, db="bibliotek"):
        return self.api("test_sql", {"db": db, "sql": sql, "params": params or []})

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        self.log.close()


def new_page(browser):
    global PAGE
    context = browser.new_context(viewport={"width": 1278, "height": 720}, device_scale_factor=1.5)
    page = context.new_page()
    page.on("console", lambda m: CONSOLE.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
    page.on("pageerror", lambda e: CONSOLE.append(f"pageerror: {e}"))
    PAGE = page
    return page


def open_book(page, title, nth=0):
    page.locator('.book-card').filter(has=page.locator('.book-title', has_text=re.compile('^' + re.escape(title) + '$'))) \
        .nth(nth).locator('.book-cover').click()


def back_to_library(page):
    page.locator('.toolbar-button', has_text='Bibliotek').click()
    page.wait_for_selector('[data-testid="book"]')


def add_file(page, path):
    page.set_input_files('[data-testid="file-input"]', [path])


def book_count(page):
    return page.locator('[data-testid="book"]').count()


def answer(page, value):
    page.wait_for_selector('[data-testid="choice-dialog"]', timeout=10000)
    title = page.locator('[data-testid="choice-dialog"] h2').inner_text()
    page.locator(f'[data-testid="choice-dialog"] [data-choice="{value}"]').click()
    return title


def toasts(page):
    return ' | '.join(page.locator('.toast').all_inner_texts())


# G3

def old_data(folder, books):
    """En datamapp som från version 0.7.0: books utan sha256, id = SHA-256, markeringar under kontrollsumman."""
    os.makedirs(os.path.join(folder, "Böcker"), exist_ok=True)
    ids = {}
    for name in ("test.pdf", "test.epub"):
        data = open(os.path.join(books, name), "rb").read()
        ids[name] = sha256(data)
        shutil.copy(os.path.join(books, name), os.path.join(folder, "Böcker", f"{ids[name]}.{name.split('.')[1]}"))
    db = sqlite3.connect(os.path.join(folder, "bibliotek.sqlite"))
    db.executescript("""
      CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL DEFAULT '', format TEXT NOT NULL,
        ext TEXT NOT NULL, file_name TEXT NOT NULL, size INTEGER NOT NULL, added REAL NOT NULL, opened REAL NOT NULL DEFAULT 0,
        position TEXT NOT NULL DEFAULT '', progress REAL NOT NULL DEFAULT 0, cover TEXT NOT NULL DEFAULT '', position_updated REAL);
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE highlights (id TEXT PRIMARY KEY, book TEXT NOT NULL, section INTEGER NOT NULL, start INTEGER NOT NULL,
        length INTEGER NOT NULL, text TEXT NOT NULL, color TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
        updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE bookmarks (id TEXT PRIMARY KEY, book TEXT NOT NULL, section INTEGER NOT NULL, progression REAL NOT NULL,
        label TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
    """)
    db.execute("""INSERT INTO books (id, title, author, format, ext, file_name, size, added, opened, position, progress, position_updated)
                  VALUES (?, 'Testbok i PDF', 'Läsa', 'pdf', 'pdf', 'test.pdf', 1, 1, 5, '{"page":3}', 0.4, 1700000000)""",
               (ids["test.pdf"],))
    db.execute("""INSERT INTO books (id, title, author, format, ext, file_name, size, added, opened, position, progress, position_updated)
                  VALUES (?, 'Testbok för Läsa', '', 'epub', 'epub', 'test.epub', 1, 2, 0, '', 0, NULL)""", (ids["test.epub"],))
    # Platsen stämmer inte med pdf.js text, så markeringen letas upp via texten (som efter en ny version).
    db.execute("""INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated)
                  VALUES ('m1', ?, 1, 0, 17, 'Gatorna var smala', 'green', 'Gammal anteckning', 10, 20)""", (ids["test.pdf"],))
    db.execute("""INSERT INTO bookmarks (id, book, section, progression, label, created, updated)
                  VALUES ('b1', ?, 2, 0, 'Sida 3', 10, 30)""", (ids["test.pdf"],))
    db.commit()
    db.close()
    return ids


def backups(folder):
    return sorted(glob.glob(os.path.join(folder, "bibliotek före bokens id *.sqlite")))


def book_files(folder):
    return sorted(os.listdir(os.path.join(folder, "Böcker")))


def g3(browser, args):
    data = os.path.join(args.out, "data-g3")
    shutil.rmtree(data, ignore_errors=True)
    ids = old_data(data, args.books)
    log = os.path.join(args.out, "server-g3.log")
    server = Server(args.dictionary, data, args.port, log)
    try:
        # Flytten
        copies = backups(data)
        check(len(copies) == 1, f'en kopia av bibliotek.sqlite före flytten: {[os.path.basename(c) for c in copies]}')
        if copies:
            old = sqlite3.connect(copies[0])
            # Kopian görs efter att de nya kolumnerna lagts till (tomma), men före flytten.
            check(sorted(row[0] for row in old.execute("SELECT id FROM books")) == sorted(ids.values())
                  and old.execute("SELECT COUNT(*) FROM highlights WHERE book = ?", (ids["test.pdf"],)).fetchone()[0] == 1,
                  'kopian har böckerna och markeringen som före flytten')
            old.close()
        rows = server.sql("SELECT id, sha256, file_name, missing FROM books ORDER BY added")
        check([row[1] for row in rows] == [ids["test.pdf"], ids["test.epub"]] and all(UUID.match(row[0]) for row in rows),
              f'böckerna har fått eget id och kontrollsumman i sha256: {rows}')
        pdf_id = rows[0][0] if rows else None
        marks = server.sql("SELECT book, updated FROM highlights")
        check(marks == [[pdf_id, 20]], f'markeringen flyttad till bokens id, ändringstiden orörd: {marks}')
        check(server.sql("SELECT book, updated FROM bookmarks") == [[pdf_id, 30]], 'bokmärket flyttat')
        check(server.sql("SELECT value FROM meta WHERE key = 'legacy_book_keys_moved'") == [['1']], 'klart-markeringen')
        check(book_files(data) == sorted([f'{ids["test.pdf"]}.pdf', f'{ids["test.epub"]}.epub']),
              'bokfilerna heter fortfarande efter kontrollsumman')

        # En andra start ändrar ingenting
        server.stop()
        server = Server(args.dictionary, data, args.port, log)
        check(len(backups(data)) == 1, 'ingen ny kopia vid andra starten')
        check(server.sql("SELECT id, sha256, file_name, missing FROM books ORDER BY added") == rows, 'andra starten ändrar inget')

        page = new_page(browser)
        page.goto(server.url)
        page.wait_for_selector('[data-testid="book"]')
        check(book_count(page) == 2, 'två böcker i biblioteket efter flytten')
        shas = page.locator('[data-testid="book"]').evaluate_all('els => els.map(e => e.dataset.sha256)')
        check(sorted(shas) == sorted(ids.values()), 'korten visar kontrollsumman')
        open_book(page, 'Testbok i PDF')
        page.wait_for_selector('.pdf-spread .pdf-page canvas')
        check(wait_for(lambda: page.locator('.page-label').inner_text().startswith('Sida 4')),
              f'läspositionen följde med: {page.locator(".page-label").inner_text()}')
        page.keyboard.press('Home')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: page.locator('.pdf-mark.color-green').count() >= 1), 'den gamla markeringen syns på sidan 2')
        page.locator('[data-testid="marks-button"]').click()
        check(wait_for(lambda: page.locator('[data-testid="bookmark-row"]').count() == 1
                       and page.locator('[data-testid="highlight-row"]').count() == 1), 'listan visar bokmärket och markeringen')
        page.screenshot(path=os.path.join(args.out, "g3-01-efter-flytten.png"))
        page.keyboard.press('Escape')
        back_to_library(page)

        pdf_bytes = open(os.path.join(args.books, "test.pdf"), "rb").read()
        work = os.path.join(args.out, "g3-filer")
        os.makedirs(work, exist_ok=True)

        def variant(name, extra):
            path = os.path.join(work, extra.replace(' ', '_'), name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as file:
                file.write(pdf_bytes + f"\n% {extra}\n".encode())
            return path

        # Namnbyte: samma innehåll med ett annat namn läggs inte till igen
        renamed = os.path.join(work, "Omdöpt.pdf")
        shutil.copy(os.path.join(args.books, "test.pdf"), renamed)
        add_file(page, renamed)
        check(wait_for(lambda: 'finns redan i biblioteket som test.pdf' in toasts(page)), f'namnbyte: {toasts(page)}')
        check(book_count(page) == 2, 'ingen ny bok för samma innehåll')

        # Ny version med samma namn: Ersätt och behåll markeringarna
        v2 = variant("test.pdf", "version 2")
        add_file(page, v2)
        title = answer(page, 'keep')
        check(title == 'Det finns redan en bok som heter test.pdf', f'frågan vid upptaget namn: {title}')
        v2_sha = sha256(open(v2, "rb").read())
        check(wait_for(lambda: server.sql("SELECT sha256 FROM books WHERE id = ?", [pdf_id]) == [[v2_sha]]),
              'Behåll markeringarna: samma id, ny kontrollsumma')
        check(wait_for(lambda: f'{v2_sha}.pdf' in book_files(data) and f'{ids["test.pdf"]}.pdf' not in book_files(data)),
              f'den nya filen sparad och den gamla borta: {book_files(data)}')
        check(server.sql("SELECT book FROM highlights") == [[pdf_id]], 'markeringen hänger kvar på bokens id')
        page.wait_for_selector('[data-testid="book"]')
        check(wait_for(lambda: book_count(page) == 2), 'fortfarande två böcker')
        open_book(page, 'Testbok i PDF')
        page.wait_for_selector('.pdf-spread .pdf-page canvas')
        page.keyboard.press('Home')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: page.locator('.pdf-mark.color-green').count() >= 1), 'markeringen syns i den nya versionen')
        back_to_library(page)

        # Behåll båda
        v3 = variant("test.pdf", "version 3")
        add_file(page, v3)
        answer(page, 'both')
        check(wait_for(lambda: book_count(page) == 3), 'Behåll båda: tre böcker')
        both = server.sql("SELECT id, file_name FROM books WHERE sha256 = ?", [sha256(open(v3, "rb").read())])
        check(len(both) == 1 and both[0][1] == 'test 2.pdf' and both[0][0] != pdf_id, f'den nya heter test 2.pdf: {both}')
        check(wait_for(lambda: 'test 2.pdf' in page.locator('[data-testid="book-file"]').all_inner_texts()),
              'två böcker med samma titel visar filnamnet')
        page.screenshot(path=os.path.join(args.out, "g3-02-behall-bada.png"))

        # Ersätt och börja om
        v4 = variant("test.pdf", "version 4")
        add_file(page, v4)
        answer(page, 'startOver')
        v4_sha = sha256(open(v4, "rb").read())
        check(wait_for(lambda: len(server.sql("SELECT id FROM books WHERE sha256 = ? AND missing = 0", [v4_sha])) == 1),
              'Ersätt och börja om: en ny bok')
        new_id = server.sql("SELECT id FROM books WHERE sha256 = ?", [v4_sha])[0][0]
        check(new_id != pdf_id and server.sql("SELECT missing FROM books WHERE id = ?", [pdf_id]) == [[1]],
              'den gamla raden finns kvar som borttagen')
        check(server.sql("SELECT COUNT(*) FROM highlights WHERE book = ?", [new_id]) == [[0]]
              and server.sql("SELECT COUNT(*) FROM highlights WHERE book = ?", [pdf_id]) == [[1]],
              'den nya boken börjar utan markeringar, de gamla finns kvar')
        check(f'{v2_sha}.pdf' not in book_files(data), 'den ersatta filen är borta')
        check(wait_for(lambda: book_count(page) == 3), 'fortfarande tre böcker i biblioteket')

        # Avbryt
        v5 = variant("test.pdf", "version 5")
        add_file(page, v5)
        answer(page, 'cancel')
        page.wait_for_timeout(500)
        check(len(server.sql("SELECT id FROM books")) == 4 and book_count(page) == 3, 'Avbryt lägger inte till något')

        # Ta bort, och samma fil tillbaka med ett annat namn
        card = page.locator('.book-card').filter(has=page.locator('[data-testid="book-file"]', has_text='test 2.pdf'))
        card.get_by_text('Ta bort').click()
        page.locator('.dialog .button.danger').click()
        check(wait_for(lambda: book_count(page) == 2), 'Ta bort tar bort boken ur biblioteket')
        check(server.sql("SELECT missing FROM books WHERE id = ?", [both[0][0]]) == [[1]], 'men raden finns kvar')
        server.sql("INSERT INTO bookmarks (id, book, section, progression, label, created, updated) VALUES ('b2', ?, 4, 0, 'Sida 5', 1, 1)",
                   [both[0][0]])
        back = os.path.join(work, "Tillbaka.pdf")
        shutil.copy(v3, back)
        add_file(page, back)
        check(wait_for(lambda: server.sql("SELECT missing, file_name FROM books WHERE id = ?", [both[0][0]]) == [[0, 'Tillbaka.pdf']]),
              'samma innehåll kommer tillbaka med sitt id och det nya namnet')
        check(wait_for(lambda: book_count(page) == 3), 'och syns i biblioteket igen')

        # Liknande namn på en borttagen bok: Ny version av boken
        txt_a = os.path.join(work, "Anteckningar.txt")
        with open(txt_a, "w", encoding="utf-8") as file:
            file.write("Anteckningar om retorik.\n\nEthos, pathos och logos.\n")
        add_file(page, txt_a)
        check(wait_for(lambda: len(server.sql("SELECT id FROM books WHERE file_name = 'Anteckningar.txt'")) == 1), 'textfilen lades till')
        txt_id = server.sql("SELECT id FROM books WHERE file_name = 'Anteckningar.txt'")[0][0]
        server.sql("INSERT INTO bookmarks (id, book, section, progression, label, created, updated) VALUES ('b3', ?, 0, 0.2, 'Början', 1, 1)",
                   [txt_id])
        page.wait_for_timeout(300)
        card = page.locator('.book-card', has_text='Anteckningar')
        card.get_by_text('Ta bort').click()
        page.locator('.dialog .button.danger').click()
        check(wait_for(lambda: server.sql("SELECT missing FROM books WHERE id = ?", [txt_id]) == [[1]]), 'textfilen borttagen')
        txt_b = os.path.join(work, "Anteckningar (OCR) 2.txt")
        with open(txt_b, "w", encoding="utf-8") as file:
            file.write("Anteckningar om retorik.\n\nEthos, pathos och logos, och kairos.\n")
        add_file(page, txt_b)
        title = answer(page, 'keep')
        check(title == 'Ny version av boken', f'frågan Ny version av boken: {title}')
        check(wait_for(lambda: server.sql("SELECT missing, file_name FROM books WHERE id = ?", [txt_id])
                       == [[0, 'Anteckningar (OCR) 2.txt']]), 'Behåll markeringarna: samma id med det nya namnet')
        check(server.sql("SELECT book FROM bookmarks WHERE id = 'b3'") == [[txt_id]], 'bokmärket följer med')
        page.screenshot(path=os.path.join(args.out, "g3-03-bibliotek.png"))
        page.context.close()
    finally:
        server.stop()


# W10

def word_box(page, word, page_index, occurrence=0):
    """Vänsterkant, högerkant och mitt (i fönstret) för ett ord på en viss PDF-sida."""
    return page.evaluate("""([word, index, occurrence]) => {
      let seen = 0;
      for (const span of document.querySelectorAll(`.pdf-page[data-page="${index}"] .textLayer span`)) {
        const node = span.firstChild;
        if (!node || node.nodeType !== 3) continue;
        let at = node.data.indexOf(word);
        while (at >= 0) {
          if (seen++ === occurrence) {
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + word.length);
            const r = range.getBoundingClientRect();
            return { left: { x: r.left + 1, y: r.top + r.height / 2 }, right: { x: r.right - 1, y: r.top + r.height / 2 },
              x: r.left + r.width / 2, y: r.top + r.height / 2, visible: r.top >= 0 && r.bottom <= innerHeight };
          }
          at = node.data.indexOf(word, at + 1);
        }
      }
      return null;
    }""", [word, page_index, occurrence])


def drag(page, start, end):
    page.mouse.move(start["x"], start["y"])
    page.mouse.down()
    page.mouse.move((start["x"] + end["x"]) / 2, (start["y"] + end["y"]) / 2, steps=4)
    page.mouse.move(end["x"], end["y"], steps=4)
    page.mouse.up()


def label(page):
    return page.locator('.page-label').inner_text()


def rendered(page):
    return page.evaluate("[...document.querySelectorAll('.pdf-slot .pdf-page')].map(e => Number(e.dataset.page))")


def choose_view(page, testid):
    if not page.locator('[data-testid="fit-auto"]').is_visible():
        page.locator('[data-testid="zoom-button"]').click()
    page.locator(f'[data-testid="{testid}"]').click()
    page.wait_for_timeout(400)


def w10(browser, args):
    data = os.path.join(args.out, "data-w10")
    shutil.rmtree(data, ignore_errors=True)
    os.makedirs(data)
    server = Server(args.dictionary, data, args.port, os.path.join(args.out, "server-w10.log"))
    try:
        page = new_page(browser)
        page.goto(server.url)
        page.wait_for_selector('[data-testid="tab-library"]')
        add_file(page, os.path.join(args.books, "test.pdf"))
        check(wait_for(lambda: book_count(page) == 1, 20), 'PDF:en lades till')
        open_book(page, 'Testbok i PDF')
        page.wait_for_selector('.pdf-spread .pdf-page canvas')

        # Rulla med En sida
        choose_view(page, 'flow-scroll')
        choose_view(page, 'spread-one')
        page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.pdf-spread.continuous').count() == 1), 'Rulla: remsan visas')
        check(page.locator('.pdf-slot').count() == 9, f'en plats per sida: {page.locator(".pdf-slot").count()}')
        check(wait_for(lambda: 0 < len(rendered(page)) <= 6), f'bara några sidor ritade: {rendered(page)}')
        check(server.sql("SELECT value FROM settings WHERE key = 'pdfFlow'") == [['"scroll"']], 'valet Rulla sparas')
        page.screenshot(path=os.path.join(args.out, "w10-01-rulla.png"))

        # Rulla genom boken med hjulet: sidnumret följer med, och sidorna långt bak släpps
        page.mouse.move(640, 400)
        for _ in range(30):
            page.mouse.wheel(0, 600)
            page.wait_for_timeout(60)
        check(wait_for(lambda: 'Sida 9' in label(page) or 'Sida 8' in label(page)), f'hjulet rullar till slutet: {label(page)}')
        check(wait_for(lambda: 0 not in rendered(page) and len(rendered(page)) <= 6), f'sidorna i början är släppta: {rendered(page)}')
        page.keyboard.press('Home')
        check(wait_for(lambda: label(page).startswith('Sida 1')), f'Home går till början: {label(page)}')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: label(page).startswith('Sida 2')), f'högerpil går till nästa sida: {label(page)}')
        wait_for(lambda: page.evaluate("document.querySelectorAll('.pdf-page[data-page=\"1\"] .textLayer span').length") > 5)

        # Ordfunktionen i Rulla
        box = word_box(page, 'Gatorna', 1)
        check(box is not None and box["visible"], f'ordet syns på sidan 2: {box}')
        page.mouse.dblclick(box["x"], box["y"])
        check(wait_for(lambda: page.locator('.popup [data-testid="header"]').count() == 1), 'Rulla: dubbelklick slår upp ordet')
        page.keyboard.press('Escape')
        page.wait_for_timeout(200)

        # Markering i Rulla
        a = word_box(page, 'Gatorna', 1)
        b = word_box(page, 'smala', 1)
        drag(page, a["left"], b["right"])
        check(wait_for(lambda: page.locator('[data-testid="mark-menu"]').count() == 1), 'Rulla: färgvalet visas')
        page.locator('[data-testid="mark-green"]').click()
        check(wait_for(lambda: page.locator('.pdf-page[data-page="1"] .pdf-mark.color-green').count() >= 1), 'Rulla: markeringen syns')
        rows = server.sql("SELECT section, text, color FROM highlights WHERE deleted = 0")
        check(len(rows) == 1 and rows[0][0] == 1 and rows[0][1].startswith('Gatorna var smala'), f'Rulla: markeringen sparas: {rows}')
        # Markeringen finns kvar när sidan släppts och ritats igen
        page.keyboard.press('End')
        check(wait_for(lambda: 1 not in rendered(page)), f'sidan 2 släpps längre fram: {rendered(page)}')
        page.keyboard.press('Home')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: page.locator('.pdf-page[data-page="1"] .pdf-mark.color-green').count() >= 1),
              'markeringen ritas igen när sidan kommer tillbaka')
        page.screenshot(path=os.path.join(args.out, "w10-02-markering.png"))

        # Sök i Rulla
        page.keyboard.press('Control+f')
        page.fill('[data-testid="search-input"]', 'Chapter')
        check(wait_for(lambda: page.locator('[data-testid="search-hit-row"]').count() >= 1, 15), 'Rulla: sökningen hittar Chapter')
        page.locator('[data-testid="search-hit-row"]').first.click()
        check(wait_for(lambda: label(page).startswith('Sida 5')), f'Rulla: träffen visas på sidan 5: {label(page)}')
        hit = page.locator('.pdf-spread [data-testid="search-hit"]')
        check(wait_for(lambda: hit.count() >= 1), 'Rulla: träffen ringas in')
        if hit.count():
            r = hit.first.bounding_box()
            check(r and 0 <= r["y"] <= 720, f'träffen syns i fönstret: {r}')
        page.screenshot(path=os.path.join(args.out, "w10-03-sok.png"))
        page.keyboard.press('Escape')
        page.wait_for_timeout(200)

        # Läspositionen i Rulla
        page.evaluate("document.querySelector('.reader-stage').focus()")
        page.keyboard.press('Home')
        for _ in range(5):
            page.keyboard.press('ArrowRight')
            page.wait_for_timeout(100)
        check(wait_for(lambda: label(page).startswith('Sida 6')), f'sida 6: {label(page)}')
        page.wait_for_timeout(900)
        page.reload()
        page.wait_for_selector('[data-testid="book"]')
        open_book(page, 'Testbok i PDF')
        check(wait_for(lambda: page.locator('.pdf-spread.continuous').count() == 1, 15), 'Rulla är kvar efter omladdning')
        check(wait_for(lambda: label(page).startswith('Sida 6')), f'Rulla: läspositionen finns kvar: {label(page)}')

        # Uppslag i Rulla: Två sidor
        choose_view(page, 'spread-two')
        page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.pdf-row.two').count() == 5), f'Två sidor: fem rader: {page.locator(".pdf-row.two").count()}')
        check(page.locator('.pdf-row').first.locator('.pdf-slot.empty').count() == 1, 'omslaget ensamt till höger')
        check(wait_for(lambda: label(page).startswith('Sidorna 6 och 7')), f'platsen behålls: {label(page)}')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: label(page).startswith('Sidorna 8 och 9')), f'högerpil till nästa rad: {label(page)}')
        check(wait_for(lambda: len(rendered(page)) <= 10), f'högst tio ritade sidor: {rendered(page)}')
        page.screenshot(path=os.path.join(args.out, "w10-04-rulla-tva-sidor.png"))
        choose_view(page, 'fit-page')
        page.keyboard.press('Escape')
        page.keyboard.press('End')
        page.wait_for_timeout(600)
        check(wait_for(lambda: len(rendered(page)) <= 10), f'Hela sidan i Rulla: högst tio ritade sidor: {rendered(page)}')
        choose_view(page, 'fit-auto')
        choose_view(page, 'spread-auto')
        page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.pdf-spread.continuous .pdf-slot .pdf-page canvas').count() >= 1), 'Automatiskt i Rulla ritar sidor')

        # Tillbaka till Bläddra: en sida eller ett uppslag i taget, ordfunktionen fungerar
        choose_view(page, 'flow-paged')
        choose_view(page, 'spread-one')
        page.keyboard.press('Escape')
        check(wait_for(lambda: page.locator('.pdf-spread.continuous').count() == 0 and page.locator('.pdf-slot').count() == 0),
              'Bläddra: remsan är borta')
        check(server.sql("SELECT value FROM settings WHERE key = 'pdfFlow'") == [['"paged"']], 'valet Bläddra sparas')
        page.keyboard.press('Home')
        page.keyboard.press('ArrowRight')
        check(wait_for(lambda: label(page).startswith('Sida 2')), f'Bläddra: sida 2: {label(page)}')
        check(wait_for(lambda: page.locator('.pdf-spread > .pdf-page').count() == 1), 'Bläddra: en sida åt gången')
        wait_for(lambda: page.evaluate("document.querySelectorAll('.pdf-page[data-page=\"1\"] .textLayer span').length") > 5)
        check(wait_for(lambda: page.locator('.pdf-page[data-page="1"] .pdf-mark.color-green').count() >= 1), 'Bläddra: markeringen syns')
        box = word_box(page, 'Gatorna', 1)
        if box:
            page.mouse.dblclick(box["x"], box["y"])
        check(wait_for(lambda: page.locator('.popup [data-testid="header"]').count() == 1), 'Bläddra: dubbelklick slår upp ordet')
        page.keyboard.press('Escape')
        page.screenshot(path=os.path.join(args.out, "w10-05-bladdra.png"))
        page.context.close()
    finally:
        server.stop()


def main():
    global PAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--dictionary", required=True)
    parser.add_argument("--books", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--port", type=int, default=8963)
    parser.add_argument("--only", default="", help="g3 eller w10")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        try:
            if args.only in ("", "g3"):
                g3(browser, args)
            if args.only in ("", "w10"):
                w10(browser, args)
        finally:
            browser.close()
    problems = [line for line in CONSOLE if not any(known in line for known in KNOWN)]
    check(not problems, 'konsolen är tom' + ('' if not problems else ': ' + ' | '.join(problems[:8])))
    print(f"\n{len(FAILURES)} fel" if FAILURES else "\nInga fel", flush=True)
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
