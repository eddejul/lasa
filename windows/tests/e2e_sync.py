"""Provkör synken (fas 6) i Chrome mot låtsas-Supabase (mock_supabase.py) och dev/server.py.

  python windows/tests/e2e_sync.py --url http://127.0.0.1:8955/ --books <testböcker> --out <mapp> [--port 8956]

Provservern (dev/server.py) ska köra med en tom datamapp. Testet startar själv låtsasservern på --port
med ett frö (en position och två ord från "iPaden", en markering som inte får röras) och stoppar den
efteråt på dess PID. Det loggar in under Inställningar, synkar och kontrollerar:
* att fröets EPUB-position och ord hamnar i appen, och att boken öppnas i rätt kapitel,
* att lokala positioner och ord hamnar på servern med rätt fält och tider i millisekunder,
* att en andra synk skickar och hämtar noll rader,
* att ett borttaget ord blir deleted = true,
* att en öppen bok inte hoppar när en nyare position kommer, och att den gäller nästa gång,
* att markeringar och bokmärken aldrig läses eller skrivs.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import FIND_IN_TEXT_LAYER, KNOWN  # noqa: E402

FAILURES = []
ISO_MS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
USER = "00000000-0000-4000-8000-000000000001"


def check(condition, message):
    print(("ok   " if condition else "FEL  ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


def sha256(path):
    with open(path, "rb") as file:
        return hashlib.sha256(file.read()).hexdigest()


def seed(pdf_id, epub_id):
    return {
        "positions": [
            {"book_id": epub_id, "title": "Testbok för Läsa", "kind": "reflow", "section": 2, "progression": 0.5,
             "updated_at": "2026-11-07T09:00:00.123456+00:00"},
            {"book_id": "f" * 64, "title": "En bok som bara finns på iPaden", "kind": "pdf", "section": 7,
             "progression": 0, "updated_at": "2026-11-07T09:00:00+00:00"},
        ],
        "highlights": [
            {"id": "6f1c1d2e-0000-4000-8000-00000000abcd", "book_id": pdf_id, "section": 1, "start": 0, "length": 5,
             "text": "Detta", "color": "yellow", "note": "", "created_at": "2026-11-07T08:00:00.000000+00:00",
             "updated_at": "2026-11-07T08:00:00.000000+00:00", "deleted": False},
        ],
        "bookmarks": [],
        "saved_words": [
            {"lemma": "bro", "language": "sv", "word": "bron", "sentence": "Bron var hög.", "book": "Testbok för Läsa",
             "page": 3, "lookups": 2, "created_at": "2026-11-06T09:00:00.000000+00:00",
             "updated_at": "2026-11-07T09:00:00.456789+00:00", "deleted": False, "due": 1794000000.5, "interval": 3.0,
             "ease": 2.5, "reps": 2, "lapses": 1, "review_updated_at": "2026-11-07T09:30:00.250000+00:00"},
            {"lemma": "gammal", "language": "sv", "word": "gamla", "sentence": "", "book": "", "page": 0, "lookups": 1,
             "created_at": "2026-11-05T09:00:00+00:00", "updated_at": "2026-11-06T09:00:00+00:00", "deleted": True,
             "due": None, "interval": None, "ease": None, "reps": None, "lapses": None, "review_updated_at": None},
        ],
    }


def api(base, command, args):
    request = urllib.request.Request(base + "api/" + command, data=json.dumps(args).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read() or b"null")


def setting(base, key):
    rows = api(base, "test_sql", {"db": "bibliotek", "sql": "SELECT value FROM settings WHERE key = ?", "params": [key]})
    return json.loads(rows[0][0]) if rows else None


def wait_for(page, predicate, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            value = predicate()
            if value:
                return value
        except Exception:  # noqa: BLE001
            pass
        page.wait_for_timeout(150)
    return None


def run(url, books, out, port):
    os.makedirs(out, exist_ok=True)
    pdf_id = sha256(os.path.join(books, "test.pdf"))
    epub_id = sha256(os.path.join(books, "test.epub"))
    seed_path = os.path.join(out, "supabase-fro.json")
    state_path = os.path.join(out, "supabase-efter.json")
    with open(seed_path, "w", encoding="utf-8") as file:
        json.dump(seed(pdf_id, epub_id), file, ensure_ascii=False)
    mock = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_supabase.py"),
                             str(port), seed_path, state_path])
    print(f"     låtsas-Supabase på port {port}, pid {mock.pid}")
    mock_url = f"http://127.0.0.1:{port}"

    def server_state():
        with open(state_path, encoding="utf-8") as file:
            return json.load(file)

    def word_row(lemma):
        return next((row for row in server_state()["tables"]["saved_words"] if row["lemma"] == lemma), None)

    console = []
    try:
        time.sleep(1)
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="chrome", headless=True)
            page = browser.new_context(viewport={"width": 1278, "height": 720}).new_page()
            page.on("console", lambda m: console.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
            page.on("pageerror", lambda e: console.append(f"pageerror: {e}"))
            page.goto(url)
            page.wait_for_selector('[data-testid="tab-settings"]')
            page.set_input_files('[data-testid="file-input"]',
                                 [os.path.join(books, name) for name in ("test.pdf", "test.epub", "test.md")])
            check(wait_for(page, lambda: page.locator('[data-testid="book"]').count() == 3, 20), 'tre böcker')

            # Lokalt före inloggningen: PDF till sida 3, och ett ord sparas.
            page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
            page.wait_for_selector('.pdf-spread .pdf-page canvas')
            wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 1 av 9')
            page.keyboard.press('ArrowRight')
            wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 2 av 9')
            page.wait_for_function("document.querySelectorAll('.pdf-spread .textLayer span').length > 5")
            point = page.evaluate(FIND_IN_TEXT_LAYER, ["kun-", 0])
            page.mouse.dblclick(point["x"] - 6, point["y"])
            page.wait_for_selector('.popup [data-testid="header"]')
            page.keyboard.press('Escape')
            page.keyboard.press('ArrowRight')
            check(wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 3 av 9'), 'PDF på sida 3')
            page.wait_for_timeout(700)
            page.locator('.toolbar-button', has_text='Bibliotek').click()
            page.wait_for_selector('[data-testid="book"]')

            # Ingen synk utan inställningar
            check(not any("/rest/" in line for line in server_state()["requests"]), 'ingen synk utan inställningar')

            # Logga in under Inställningar
            page.locator('[data-testid="tab-settings"]').click()
            page.fill('[data-testid="sync-url"]', mock_url)
            page.fill('[data-testid="sync-key"]', "test-anon")
            page.fill('[data-testid="sync-email"]', "edvin@example.com")
            page.fill('[data-testid="sync-password"]', "provlosenord")
            page.locator('[data-testid="sync-sign-in"]').click()
            check(wait_for(page, lambda: setting(url, "syncReport") is not None, 15), 'första synken efter inloggningen')
            report = setting(url, "syncReport")
            check(report == {"books": 2, "pushed": 2, "pulled": 3}, f'första synken: {report}')
            check(setting(url, "syncError") is None, f'inget fel: {setting(url, "syncError")}')
            page.screenshot(path=os.path.join(out, "s1-installningar.png"), full_page=True)
            check('provlosenord' not in json.dumps(api(url, "test_sql", {"db": "bibliotek", "sql": "SELECT * FROM settings", "params": []})),
                  'lösenordet finns inte i inställningarna')
            check(page.input_value('[data-testid="sync-password"]') == '', 'lösenordsfältet töms efter inloggningen')
            check(api(url, "secret_get", {"name": "sync-refresh-token"}) == "refresh-1", 'förnyelsetoken sparas som hemlighet')

            # Det lokala på servern
            state = server_state()
            position = next((row for row in state["tables"]["positions"] if row["book_id"] == pdf_id), None)
            check(position is not None and position["kind"] == "pdf" and position["section"] == 2
                  and position["progression"] == 0 and position["title"] == "Testbok i PDF"
                  and position["user_id"] == USER and ISO_MS.match(position["updated_at"]),
                  f'PDF-positionen på servern: {position}')
            word = word_row("kunskap")
            expected = {"user_id", "lemma", "language", "word", "sentence", "book", "page", "lookups", "created_at",
                        "updated_at", "deleted", "due", "interval", "ease", "reps", "lapses", "review_updated_at"}
            check(word is not None and set(word) == expected and word["language"] == "sv" and word["deleted"] is False
                  and word["word"] == "kunskap" and word["book"] == "Testbok i PDF" and word["page"] == 1
                  and word["due"] is None and ISO_MS.match(word["updated_at"]) and ISO_MS.match(word["created_at"])
                  and "kunskap" in word["sentence"], f'ordet kunskap på servern: {word}')

            # Fröet i appen
            rows = api(url, "test_sql", {"db": "bibliotek", "sql": "SELECT position, position_updated FROM books WHERE id = ?",
                                           "params": [epub_id]})
            seed_ms = int(datetime.datetime(2026, 11, 7, 9, 0, 0, 123000, tzinfo=datetime.timezone.utc).timestamp() * 1000)
            check(json.loads(rows[0][0]) == {"section": 2, "progression": 0.5} and round(rows[0][1] * 1000) == seed_ms,
                  f'EPUB-positionen från fröet, med fröets tid i millisekunder: {rows}')
            words = api(url, "test_sql", {"db": "ord", "sql": "SELECT lemma, deleted, due, interval, ease, reps, lapses, "
                                            "review_updated, updated FROM saved_words ORDER BY lemma", "params": []})
            bro = next((row for row in words if row[0] == "bro"), None)
            check(bro is not None and bro[1] == 0 and bro[2:7] == [1794000000.5, 3.0, 2.5, 2, 1],
                  f'ordet bro med repetitionen från fröet: {bro}')
            gammal = next((row for row in words if row[0] == "gammal"), None)
            check(gammal is not None and gammal[1] == 1, f'borttaget ord från fröet är borttaget lokalt: {gammal}')
            page.locator('[data-testid="tab-saved"]').click()
            page.wait_for_selector('[data-testid="saved-word"]')
            saved = page.locator('[data-testid="saved-word"]').all_inner_texts()
            check(any(text.startswith('bron (bro)') for text in saved) and not any('gamla' in text for text in saved),
                  f'Sparade ord visar bro men inte det borttagna: {[s.splitlines()[0] for s in saved]}')

            # EPUB öppnas i kapitlet från iPaden (kapitel 2 bland dokumenten är kap2)
            page.locator('[data-testid="tab-library"]').click()
            page.locator('.book-card', has_text='Testbok för Läsa').locator('.book-cover').click()
            check(wait_for(page, lambda: page.locator('.page-label').inner_text().startswith('kap2'), 15),
                  f'EPUB öppnas i kap2: {page.locator(".page-label").inner_text()}')
            page.wait_for_timeout(800)
            page.screenshot(path=os.path.join(out, "s2-epub-fran-ipaden.png"))
            page.locator('.toolbar-button', has_text='Bibliotek').click()
            page.wait_for_selector('[data-testid="book"]')

            # Andra synken: inget att skicka eller hämta
            page.locator('[data-testid="tab-settings"]').click()
            last = setting(url, "syncLast")
            page.locator('[data-testid="sync-now"]').click()
            check(wait_for(page, lambda: setting(url, "syncLast") != last and not page.locator('[data-testid="sync-now"]').is_disabled(), 15),
                  'Synka nu')
            report = setting(url, "syncReport")
            check(report == {"books": 2, "pushed": 0, "pulled": 0}, f'andra synken skickar och hämtar noll: {report}')
            status = page.locator('[data-testid="sync-status"]').inner_text()
            check('0 ändringar skickade, 0 hämtade' in status, f'statusen visar synken: {status!r}')

            # Ett borttaget ord blir deleted = true
            before = word_row("kunskap")["updated_at"]
            page.locator('[data-testid="tab-saved"]').click()
            page.locator('[data-testid="saved-word"]', has_text='kunskap').get_by_text('Ta bort').click()
            page.wait_for_timeout(300)
            page.locator('[data-testid="tab-settings"]').click()
            page.locator('[data-testid="sync-now"]').click()
            check(wait_for(page, lambda: word_row("kunskap")["deleted"] is True, 15), 'borttaget ord blir deleted = true')
            word = word_row("kunskap")
            check(word["updated_at"] > before and ISO_MS.match(word["updated_at"]), f'med ny ändringstid: {before} till {word["updated_at"]}')
            check(setting(url, "syncReport") == {"books": 2, "pushed": 1, "pulled": 0}, f'tredje synken: {setting(url, "syncReport")}')

            # En öppen bok hoppar inte när en nyare position kommer, och den gäller nästa gång
            page.locator('[data-testid="tab-library"]').click()
            page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
            check(wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 3 av 9'), 'PDF öppnas på sida 3')
            newer = {"user_id": USER, "book_id": pdf_id, "title": "Testbok i PDF", "kind": "pdf", "section": 6,
                     "progression": 0, "updated_at": "2099-01-01T00:00:00.000Z"}
            request = urllib.request.Request(f"{mock_url}/rest/v1/positions?on_conflict=user_id,book_id",
                                             data=json.dumps([newer]).encode("utf-8"), method="POST",
                                             headers={"apikey": "test-anon", "Authorization": "Bearer token-1",
                                                      "Prefer": "resolution=merge-duplicates,return=minimal",
                                                      "Content-Type": "application/json"})
            urllib.request.urlopen(request, timeout=10).close()
            result = page.evaluate("async () => (await import('/js/sync.js')).syncNow()")
            check(result == {"books": 2, "pushed": 0, "pulled": 1}, f'synk med boken öppen hämtar positionen: {result}')
            page.wait_for_timeout(500)
            check(page.locator('.page-label').inner_text() == 'Sida 3 av 9', 'den öppna boken hoppar inte')
            page.locator('.toolbar-button', has_text='Bibliotek').click()
            page.wait_for_selector('[data-testid="book"]')
            page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
            check(wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 7 av 9'),
                  f'nästa gång öppnas boken där iPaden var: {page.locator(".page-label").inner_text()}')
            page.locator('.toolbar-button', has_text='Bibliotek').click()

            # Markeringar och bokmärken rörs aldrig
            state = server_state()
            touched = [line for line in state["requests"] if "highlights" in line or "bookmarks" in line]
            check(not touched, f'markeringar och bokmärken rörs inte: {touched}')
            seeded = [dict(row, user_id=USER) for row in seed(pdf_id, epub_id)["highlights"]]
            check(state["tables"]["highlights"] == seeded, 'markeringen från iPaden är orörd')
            bro_row = word_row("bro")
            check(bro_row["due"] == 1794000000.5 and bro_row["review_updated_at"] == "2026-11-07T09:30:00.250000+00:00",
                  f'repetitionen för bro är orörd på servern: {bro_row}')

            # Logga ut
            page.locator('[data-testid="tab-settings"]').click()
            page.locator('[data-testid="sync-sign-out"]').click()
            check(wait_for(page, lambda: page.locator('[data-testid="sync-sign-out"]').count() == 0), 'Logga ut')
            page.screenshot(path=os.path.join(out, "s3-utloggad.png"), full_page=True)
            browser.close()
    finally:
        mock.terminate()
        mock.wait(timeout=10)
        print(f"     låtsas-Supabase stoppad (pid {mock.pid})")
    problems = [line for line in console if not any(known in line for known in KNOWN)]
    check(not problems, 'konsolen är tom' + ('' if not problems else ': ' + ' | '.join(problems[:8])))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8955/")
    parser.add_argument("--books", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--port", type=int, default=8956)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    run(args.url, args.books, args.out, args.port)
    print(f"\n{len(FAILURES)} fel")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
