"""Provkör synken (F1) i Chrome mot dev/server.py, med en vanlig mapp i stället för iCloud Drive.

  python windows/tests/e2e_sync.py --url http://127.0.0.1:8968/ --books <testböcker> --out <mapp>

Provservern (dev/server.py) ska köra med en tom datamapp. Testet gör själv en synkmapp i --out med en fil från
en påhittad iPad (en position, en markering, två ord, varav ett borttaget) och tre filer som ska hoppas över
(trasig, tom, från en nyare version). Det väljer mappen under Inställningar, synkar och kontrollerar:
* att iPadens EPUB-position och ord hamnar i appen, och att boken öppnas i rätt kapitel,
* att datorns egen fil skrivs i formatet i docs/SYNK.md, med de lokala raderna och det som lästs från iPaden,
* att iPadens markering följer med oförändrad i datorns fil, och att appens egna markeringar inte rörs,
* att de tre trasiga filerna hoppas över och att inget lokalt försvinner av dem,
* att en andra synk inte ändrar något, och att ett borttaget ord blir deleted = true,
* att en öppen bok inte hoppar när en nyare position kommer, och att den gäller nästa gång,
* att Sluta synka inte tar bort några filer.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import FIND_IN_TEXT_LAYER, KNOWN  # noqa: E402

FAILURES = []
ISO_MS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
SYNC = "Sensus synk"


def check(condition, message):
    print(("ok   " if condition else "FEL  ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


def sha256(path):
    with open(path, "rb") as file:
        return hashlib.sha256(file.read()).hexdigest()


IPAD_HIGHLIGHT = None


def ipad_file(pdf_id, epub_id, newer_pdf=None):
    global IPAD_HIGHLIGHT
    IPAD_HIGHLIGHT = {"id": "6f1c1d2e-0000-4000-8000-00000000abcd", "book_id": pdf_id, "section": 1, "start": 0, "length": 5,
                      "text": "Detta", "color": "yellow", "note": "från iPaden", "created_at": "2026-11-07T08:00:00.000Z",
                      "updated_at": "2026-11-07T08:00:00.000Z", "deleted": False}
    positions = [
        {"book_id": epub_id, "title": "Testbok för Läsa", "kind": "reflow", "section": 2, "progression": 0.5,
         "updated_at": "2026-11-07T09:00:00.123456+00:00"},
        {"book_id": "f" * 64, "title": "En bok som bara finns på iPaden", "kind": "pdf", "section": 7,
         "progression": 0, "updated_at": "2026-11-07T09:00:00+00:00"},
    ]
    if newer_pdf:
        positions.append(newer_pdf)
    return {
        "format": 1, "app": "Sensus", "device": {"id": "ipad-prov", "name": "Edvins iPad", "platform": "ios"},
        "written_at": "2026-11-07T10:00:00.000Z",
        "positions": positions,
        "highlights": [IPAD_HIGHLIGHT],
        "bookmarks": [],
        "saved_words": [
            {"lemma": "bro", "language": "sv", "word": "bron", "sentence": "Bron var hög.", "book": "Testbok för Läsa",
             "page": 3, "lookups": 2, "created_at": "2026-11-06T09:00:00.000Z",
             "updated_at": "2026-11-07T09:00:00.456Z", "deleted": False, "due": 1794000000.5, "interval": 3.0,
             "ease": 2.5, "reps": 2, "lapses": 1, "review_updated_at": "2026-11-07T09:30:00.250Z"},
            {"lemma": "gammal", "language": "sv", "word": "gamla", "sentence": "", "book": "", "page": 0, "lookups": 1,
             "created_at": "2026-11-05T09:00:00Z", "updated_at": "2026-11-06T09:00:00Z", "deleted": True,
             "due": None, "interval": None, "ease": None, "reps": None, "lapses": None, "review_updated_at": None},
        ],
        "framtida_falt": {"ignoreras": True},
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


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False)


def run(url, books, out):
    os.makedirs(out, exist_ok=True)
    pdf_id = sha256(os.path.join(books, "test.pdf"))
    epub_id = sha256(os.path.join(books, "test.epub"))
    folder = os.path.join(out, "iCloudDrive", "Sensus")
    shutil.rmtree(os.path.join(out, "iCloudDrive"), ignore_errors=True)
    sync = os.path.join(folder, SYNC)
    os.makedirs(sync)
    write_json(os.path.join(sync, "ipad-prov.json"), ipad_file(pdf_id, epub_id))
    with open(os.path.join(sync, "trasig.json"), "w", encoding="utf-8") as file:
        file.write('{"format": 1, "device": {"id": "trasig", "name": "Halvt hä')
    open(os.path.join(sync, "tom.json"), "w").close()
    write_json(os.path.join(sync, "framtid.json"), {"format": 9, "device": {"id": "framtid"}, "positions": []})
    seeds = set(os.listdir(sync))

    def own_file():
        names = [name for name in os.listdir(sync) if name.endswith(".json") and name not in seeds]
        if len(names) != 1:
            return None, None
        with open(os.path.join(sync, names[0]), encoding="utf-8") as file:
            return names[0], json.load(file)

    def word_row(data, lemma):
        return next((row for row in data["saved_words"] if row["lemma"] == lemma), None)

    console = []
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

        # Lokalt före synken: PDF till sida 3, och ett ord sparas.
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
        check(set(os.listdir(sync)) == seeds, 'ingen synk utan vald mapp')

        # Välj mappen under Inställningar
        page.locator('[data-testid="tab-settings"]').click()
        page.fill('[data-testid="sync-folder"]', folder)
        page.locator('[data-testid="sync-save"]').click()
        check(wait_for(page, lambda: setting(url, "syncReport") is not None, 15), 'första synken efter att mappen valts')
        message = page.locator('[data-testid="sync-message"]').inner_text()
        check('Mappen fungerar' in message, f'provet visar att mappen fungerar: {message!r}')
        report = setting(url, "syncReport")
        check(report == {"books": 2, "pushed": 7, "pulled": 3, "devices": 1, "skippedFiles": 3}, f'första synken: {report}')
        check(setting(url, "syncError") is None, f'inget fel: {setting(url, "syncError")}')
        check(setting(url, "syncFolder") == folder, 'mappen sparas')
        page.wait_for_timeout(300)
        page.screenshot(path=os.path.join(out, "s1-installningar.png"), full_page=True)
        status = page.locator('[data-testid="sync-status"]').inner_text()
        check('Edvins iPad' in status and status.count('Hoppades över') == 3, f'statusen visar iPaden och tre överhoppade: {status!r}')
        check(not any(name.endswith(".tmp") or name.startswith(".sensus-prov") for name in os.listdir(sync)),
              'inga tillfälliga filer kvar')

        # Datorns egen fil
        name, data = own_file()
        device = setting(url, "syncDevice")
        check(name == f"{device}.json", f'datorns fil heter efter enhetens id: {name}')
        check(data is not None and data["format"] == 1 and data["device"]["platform"] == "windows" and ISO_MS.match(data["written_at"]),
              f'format, plattform och tid: {data and {k: data[k] for k in ("format", "device", "written_at")}}')
        position = next((row for row in data["positions"] if row["book_id"] == pdf_id), None)
        check(position is not None and position["kind"] == "pdf" and position["section"] == 2 and position["progression"] == 0
              and position["title"] == "Testbok i PDF" and ISO_MS.match(position["updated_at"]),
              f'PDF-positionen i datorns fil: {position}')
        check(any(row["book_id"] == "f" * 64 and row["section"] == 7 for row in data["positions"]),
              'en position för en bok som bara finns på iPaden följer med i filen')
        word = word_row(data, "kunskap")
        expected = {"lemma", "language", "word", "sentence", "book", "page", "lookups", "created_at", "updated_at", "deleted",
                    "due", "interval", "ease", "reps", "lapses", "review_updated_at"}
        check(word is not None and set(word) == expected and word["language"] == "sv" and word["deleted"] is False
              and word["word"] == "kunskap" and word["book"] == "Testbok i PDF" and word["page"] == 1
              and word["due"] is None and ISO_MS.match(word["updated_at"]) and ISO_MS.match(word["created_at"])
              and "kunskap" in word["sentence"], f'ordet kunskap i datorns fil: {word}')
        check(data["highlights"] == [IPAD_HIGHLIGHT], f'iPadens markering följer med oförändrad: {data["highlights"]}')
        bro = word_row(data, "bro")
        check(bro["due"] == 1794000000.5 and bro["review_updated_at"] == "2026-11-07T09:30:00.250Z",
              f'repetitionen för bro i datorns fil: {bro}')

        # iPadens rader i appen
        rows = api(url, "test_sql", {"db": "bibliotek", "sql": "SELECT position, position_updated FROM books WHERE sha256 = ?",
                                       "params": [epub_id]})
        seed_ms = int(datetime.datetime(2026, 11, 7, 9, 0, 0, 123000, tzinfo=datetime.timezone.utc).timestamp() * 1000)
        check(json.loads(rows[0][0]) == {"section": 2, "progression": 0.5} and round(rows[0][1] * 1000) == seed_ms,
              f'EPUB-positionen från iPaden, med iPadens tid i millisekunder: {rows}')
        words = api(url, "test_sql", {"db": "ord", "sql": "SELECT lemma, deleted, due, interval, ease, reps, lapses, "
                                        "review_updated, updated FROM saved_words ORDER BY lemma", "params": []})
        bro_local = next((row for row in words if row[0] == "bro"), None)
        check(bro_local is not None and bro_local[1] == 0 and bro_local[2:7] == [1794000000.5, 3.0, 2.5, 2, 1],
              f'ordet bro med repetitionen från iPaden: {bro_local}')
        gammal = next((row for row in words if row[0] == "gammal"), None)
        check(gammal is not None and gammal[1] == 1, f'borttaget ord från iPaden är borttaget här: {gammal}')
        own_marks = api(url, "test_sql", {"db": "bibliotek", "sql": "SELECT COUNT(*) FROM highlights", "params": []})
        check(own_marks == [[0]], f'appens egna markeringar rörs inte: {own_marks}')
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
        page.locator('.toolbar-button', has_text='Bibliotek').click()
        page.wait_for_selector('[data-testid="book"]')

        # Andra synken: inget ändras, filen skrivs inte om
        page.locator('[data-testid="tab-settings"]').click()
        written = own_file()[1]["written_at"]
        last = setting(url, "syncLast")
        page.locator('[data-testid="sync-now"]').click()
        check(wait_for(page, lambda: setting(url, "syncLast") != last and not page.locator('[data-testid="sync-now"]').is_disabled(), 15),
              'Synka nu')
        report = setting(url, "syncReport")
        check(report["pushed"] == 0 and report["pulled"] == 0, f'andra synken ändrar inget: {report}')
        check(own_file()[1]["written_at"] == written, 'filen skrivs inte om när inget ändrats')

        # Ett borttaget ord blir deleted = true
        before = word_row(own_file()[1], "kunskap")["updated_at"]
        page.locator('[data-testid="tab-saved"]').click()
        page.locator('[data-testid="saved-word"]', has_text='kunskap').get_by_text('Ta bort').click()
        page.wait_for_timeout(300)
        page.locator('[data-testid="tab-settings"]').click()
        page.locator('[data-testid="sync-now"]').click()
        check(wait_for(page, lambda: word_row(own_file()[1], "kunskap")["deleted"] is True, 15), 'borttaget ord blir deleted = true')
        word = word_row(own_file()[1], "kunskap")
        check(word["updated_at"] > before and word["due"] is None, f'med ny ändringstid: {before} till {word["updated_at"]}')
        check(setting(url, "syncReport")["pushed"] == 1, f'tredje synken: {setting(url, "syncReport")}')

        # En öppen bok hoppar inte när en nyare position kommer, och den gäller nästa gång
        page.locator('[data-testid="tab-library"]').click()
        page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
        check(wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 3 av 9'), 'PDF öppnas på sida 3')
        newer = {"book_id": pdf_id, "title": "Testbok i PDF", "kind": "pdf", "section": 6, "progression": 0,
                 "updated_at": "2099-01-01T00:00:00.000Z"}
        write_json(os.path.join(sync, "ipad-prov.json"), ipad_file(pdf_id, epub_id, newer))
        result = page.evaluate("async () => (await import('/js/sync.js')).syncNow()")
        check(result["pulled"] == 1, f'synk med boken öppen hämtar positionen: {result}')
        page.wait_for_timeout(500)
        check(page.locator('.page-label').inner_text() == 'Sida 3 av 9', 'den öppna boken hoppar inte')
        page.locator('.toolbar-button', has_text='Bibliotek').click()
        page.wait_for_selector('[data-testid="book"]')
        page.locator('.book-card', has_text='Testbok i PDF').locator('.book-cover').click()
        check(wait_for(page, lambda: page.locator('.page-label').inner_text() == 'Sida 7 av 9'),
              f'nästa gång öppnas boken där iPaden var: {page.locator(".page-label").inner_text()}')
        page.locator('.toolbar-button', has_text='Bibliotek').click()

        # Trasiga filer tog inte bort något, och iPadens fil är orörd av datorn
        with open(os.path.join(sync, "ipad-prov.json"), encoding="utf-8") as file:
            check(json.load(file)["highlights"] == [IPAD_HIGHLIGHT], 'iPadens fil är orörd')
        check(os.path.getsize(os.path.join(sync, "tom.json")) == 0 and os.path.exists(os.path.join(sync, "trasig.json")),
              'de trasiga filerna ligger kvar orörda')

        # Sluta synka
        page.locator('[data-testid="tab-settings"]').click()
        files_before = sorted(os.listdir(sync))
        page.locator('[data-testid="sync-forget"]').click()
        check(wait_for(page, lambda: page.locator('[data-testid="sync-forget"]').count() == 0), 'Sluta synka')
        check(setting(url, "syncFolder") is None and sorted(os.listdir(sync)) == files_before,
              'mappen glöms och inga filer tas bort')
        page.screenshot(path=os.path.join(out, "s3-utan-synk.png"), full_page=True)
        browser.close()
    problems = [line for line in console if not any(known in line for known in KNOWN)]
    check(not problems, 'konsolen är tom' + ('' if not problems else ': ' + ' | '.join(problems[:8])))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8968/")
    parser.add_argument("--books", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    run(args.url, args.books, args.out)
    print(f"\n{len(FAILURES)} fel")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
