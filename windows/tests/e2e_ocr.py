"""Provkör Gör sökbar (P1) i Chrome (huvudlöst) mot dev/server.py, med riktig Python och Tesseract.

  python windows/tests/e2e_ocr.py --dictionary <lasa-ordbok.sqlite> --out <mapp> [--port 8967]
      [--tessdata <mapp med swe.traineddata>] [--tesseract <tesseract.exe>]

Testet startar själv dev/server.py (på --port, stoppas på sitt eget PID) med en tom datamapp under --out, och gör
en tvåspaltig testsida med tools/ocr/testsidor.py (påhittad text, inga boksidor). Det provar:
* att Gör sökbar bara finns på PDF:er, och att en saknad språkmodell ger rutan med vad som saknas och
  knappen Öppna Inställningar,
* Spara och kontrollera under Inställningar,
* Gör sökbar med förloppet, att den nya boken (sökbar) kommer in i biblioteket bredvid originalet, att dess
  textlager kommer i spaltordning (både i filen och i pdf.js textlager i läsaren), att ett ord över en
  radbrytning i vänsterspalten sparas med rätt mening, och att OCR-mappen är tom efteråt,
* att en bok som redan har text ger frågan Läs om sidorna, och att Avbryt stoppar utan att lämna filer.
"""

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

import fitz
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e import KNOWN  # noqa: E402 (kända meddelanden, som 404 för favicon)
SERVER = os.path.join(HERE, "..", "dev", "server.py")
TESTSIDOR = os.path.join(HERE, "..", "..", "tools", "ocr", "testsidor.py")
FAILURES, CONSOLE = [], []


def check(condition, message):
    print(("ok   " if condition else "FEL  ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


def norm(text):
    return [w for w in (re.sub(r"[^0-9a-zåäöéü]", "", t.lower()) for t in text.split()) if w]


def order_ratio(expected, text):
    return difflib.SequenceMatcher(None, norm(" ".join(expected)), norm(text), autojunk=False).ratio()


class Server:
    """dev/server.py som egen process. Stoppas på sitt eget PID, aldrig på namn."""

    def __init__(self, dictionary, data, port, log):
        self.url = f"http://127.0.0.1:{port}/"
        self.log = open(log, "a", encoding="utf-8")
        self.process = subprocess.Popen([sys.executable, SERVER, "--dictionary", dictionary, "--data", data,
                                         "--port", str(port)], stdout=self.log, stderr=self.log)
        print(f"server PID {self.process.pid} på port {port}, data {data}", flush=True)
        for _ in range(100):
            try:
                urllib.request.urlopen(self.url, timeout=1).read()
                return
            except Exception:  # noqa: BLE001
                time.sleep(0.1)
        raise RuntimeError("servern startade inte")

    def sql(self, sql, params=None, db="bibliotek"):
        request = urllib.request.Request(self.url + "api/test_sql", method="POST",
                                         data=json.dumps({"db": db, "sql": sql, "params": params or []}).encode("utf-8"),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read() or b"null")

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        self.log.close()


def wait_js(page, expression, timeout=20.0):
    """Väntar tills uttrycket är sant. Inte page.wait_for_function: den kör eval, som appens CSP stoppar
    (global regel 71)."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            if page.evaluate(f"() => Boolean({expression})"):
                return True
        except Exception:  # noqa: BLE001 (sidan kan vara mitt i en omritning)
            pass
        page.wait_for_timeout(200)
    raise TimeoutError(expression)


def card(page, title):
    return page.locator('.book-card').filter(has=page.locator('.book-title', has_text=re.compile('^' + re.escape(title) + '$')))


def set_field(page, testid, value):
    page.fill(f'[data-testid="{testid}"]', value)


def wait_toast(page, text, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if any(text in t for t in page.locator('.toast').all_inner_texts()):
            return True
        page.wait_for_timeout(200)
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dictionary", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--port", type=int, default=8967)
    parser.add_argument("--tessdata", default="")
    parser.add_argument("--tesseract", default="")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    out = os.path.abspath(args.out)
    shutil.rmtree(out, ignore_errors=True)
    data, books = os.path.join(out, "data"), os.path.join(out, "böcker")
    os.makedirs(data)
    os.makedirs(books)
    pdf = os.path.join(books, "Testbok i två spalter.pdf")
    subprocess.run([sys.executable, TESTSIDOR, pdf, "--sidor", "tva"], check=True)
    facit = json.load(open(pdf + ".json", encoding="utf-8"))[0]["ord"]
    with open(os.path.join(books, "Anteckning.txt"), "w", encoding="utf-8") as file:
        file.write("En textfil har ingen knapp Gör sökbar.\n")

    server = Server(args.dictionary, data, args.port, os.path.join(out, "server.log"))
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="chrome", headless=True)
            context = browser.new_context(viewport={"width": 1278, "height": 720}, device_scale_factor=1.5)
            page = context.new_page()
            page.on("console", lambda m: CONSOLE.append(f"{m.type}: {m.text}")
                    if m.type == "error" and not any(k in m.text for k in KNOWN) else None)
            page.on("pageerror", lambda e: CONSOLE.append(f"pageerror: {e}"))
            page.on("response", lambda r: CONSOLE.append(f"{r.status} {r.url}") if r.status >= 400 else None)
            page.goto(server.url)
            page.wait_for_selector('[data-testid="add-books"]')
            page.set_input_files('[data-testid="file-input"]', [pdf, os.path.join(books, "Anteckning.txt")])
            wait_js(page, "document.querySelectorAll('[data-testid=\"book\"]').length === 2", 20)
            check(card(page, "Testbok i två spalter").locator('[data-testid="make-searchable"]').count() == 1,
                  "PDF:en har knappen Gör sökbar")
            check(card(page, "Anteckning").locator('[data-testid="make-searchable"]').count() == 0,
                  "textfilen har ingen knapp Gör sökbar")

            # En mapp utan swe.traineddata: rutan säger vad som saknas och kan öppna Inställningar.
            empty = os.path.join(out, "tom-tessdata")
            os.makedirs(empty)
            page.click('[data-testid="tab-settings"]')
            set_field(page, "ocr-tessdata", empty)
            if args.tesseract:
                set_field(page, "ocr-tesseract", args.tesseract)
            page.click('[data-testid="ocr-check"]')
            wait_js(page, "document.querySelector('[data-testid=\"ocr-message\"]').textContent.includes('swe')", 60)
            message = page.inner_text('[data-testid="ocr-message"]')
            check("swe.traineddata" in message and "saknas" in message, f"Inställningar säger att modellen saknas: {message[:120]!r}")
            page.click('[data-testid="tab-library"]')
            card(page, "Testbok i två spalter").locator('[data-testid="make-searchable"]').click()
            page.wait_for_selector('[data-testid="choice-dialog"]', timeout=60000)
            text = page.inner_text('[data-testid="choice-dialog"]')
            check("swe.traineddata" in text and "Öppna Inställningar" in text, f"rutan säger vad som saknas: {text[:140]!r}")
            page.screenshot(path=os.path.join(out, "01-saknas.png"))
            page.click('[data-testid="choice-dialog"] [data-choice="settings"]')
            page.wait_for_selector('[data-testid="ocr-python"]', timeout=10000)
            check(True, "Öppna Inställningar visar Inställningar")

            if not args.tessdata:
                print("--tessdata saknas, resten kräver en mapp med swe.traineddata")
                return
            set_field(page, "ocr-tessdata", args.tessdata)
            page.click('[data-testid="ocr-check"]')
            wait_js(page, "document.querySelector('[data-testid=\"ocr-message\"]').textContent.includes('Allt finns')", 60)
            check(True, "Spara och kontrollera: " + page.inner_text('[data-testid="ocr-message"]')[:100])
            page.screenshot(path=os.path.join(out, "02-installningar.png"))

            # Gör sökbar på riktigt.
            page.click('[data-testid="tab-library"]')
            card(page, "Testbok i två spalter").locator('[data-testid="make-searchable"]').click()
            page.wait_for_selector('.dialog', timeout=60000)
            check("(sökbar).pdf" in page.inner_text('.dialog'), "frågan nämner den nya filens namn")
            page.locator('.dialog .button.primary').click()
            page.wait_for_selector('[data-testid="ocr-box"]', timeout=10000)
            seen = set()
            started = time.time()
            while time.time() - started < 300:
                if page.locator('[data-testid="ocr-box"]').count():
                    line = page.inner_text('[data-testid="ocr-box"]').split('\n')[0]
                    if "sida" in line and not any("sida" in item for item in seen):
                        page.screenshot(path=os.path.join(out, "03a-forlopp.png"))
                    seen.add(line)
                if card(page, "Testbok i två spalter (sökbar)").count():
                    break
                page.wait_for_timeout(300)
            print(f"     förloppet visade: {sorted(seen)}")
            check(any("sida 1 av 1" in s for s in seen), "förloppet visar sida 1 av 1")
            check(card(page, "Testbok i två spalter (sökbar)").count() == 1,
                  f"den sökbara boken kom in i biblioteket efter {time.time() - started:.0f} s")
            check(card(page, "Testbok i två spalter").count() == 1, "originalet finns kvar")
            page.screenshot(path=os.path.join(out, "03-biblioteket.png"))
            rows = server.sql("SELECT sha256, file_name FROM books WHERE file_name LIKE '%sökbar%'")
            check(len(rows) == 1 and rows[0][1] == "Testbok i två spalter (sökbar).pdf", f"filnamnet i registret: {rows}")
            new_file = os.path.join(data, "Böcker", rows[0][0] + ".pdf") if rows else ""
            if os.path.isfile(new_file):
                doc = fitz.open(new_file)
                ratio = order_ratio(facit, doc[0].get_text())
                check(ratio >= 0.85, f"filens textlager i spaltordning ({ratio:.0%})")
                doc.close()
            leftover = os.path.join(data, "OCR")
            check(not os.path.isdir(leftover) or not os.listdir(leftover), "OCR-mappen är tom efteråt")

            # Läsaren: pdf.js textlager i samma ordning, och ett ord över en radbrytning får rätt mening.
            card(page, "Testbok i två spalter (sökbar)").locator('.book-cover').click()
            wait_js(page, "document.querySelectorAll('.pdf-page .textLayer span').length > 50", 30)
            layer = page.evaluate("[...document.querySelectorAll('.pdf-page[data-page=\"0\"] .textLayer span')]"
                                  ".map((s) => s.textContent).join(' ')")
            ratio = order_ratio(facit, layer)
            check(ratio >= 0.85, f"pdf.js textlager i läsaren i spaltordning ({ratio:.0%})")
            point = page.evaluate("""() => {
              for (const span of document.querySelectorAll('.pdf-page[data-page="0"] .textLayer span')) {
                const node = span.firstChild;
                if (!node || node.nodeType !== 3) continue;
                const at = node.data.indexOf('åhöraren');
                if (at < 0) continue;
                const range = document.createRange();
                range.setStart(node, at + 2);
                range.setEnd(node, at + 3);
                const r = range.getBoundingClientRect();
                return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
              }
              return null;
            }""")
            check(point is not None, "ordet åhöraren finns i textlagret")
            if point:
                page.mouse.dblclick(point["x"], point["y"])
                page.wait_for_selector('.popup', timeout=10000)
                page.wait_for_timeout(500)
                page.screenshot(path=os.path.join(out, "04-ordet.png"))
                saved = server.sql("SELECT word, sentence FROM saved_words ORDER BY id DESC LIMIT 1", db="ord")
                sentence = saved[0][1] if saved else ""
                check(bool(saved) and "måste passa åhöraren" in sentence and "Högerspalten" not in sentence,
                      f"meningen som sparas följer vänsterspalten: {sentence!r}")
                page.keyboard.press("Escape")
            page.keyboard.press("Escape")
            page.wait_for_selector('[data-testid="add-books"]', timeout=10000)

            # En bok som redan har text: frågan Läs om sidorna (avbryts här).
            card(page, "Testbok i två spalter (sökbar)").locator('[data-testid="make-searchable"]').click()
            page.wait_for_selector('.dialog', timeout=60000)
            page.locator('.dialog .button.primary').click()
            wait_js(page, "[...document.querySelectorAll('.dialog h2')].some((h) => h.textContent === 'Boken har redan text')", 60)
            check("1 av 1 sidor" in page.inner_text('.dialog'), "frågan säger hur många sidor som har text")
            page.screenshot(path=os.path.join(out, "05-har-text.png"))
            page.locator('.dialog .button', has_text="Avbryt").click()

            # Avbryt mitt i.
            card(page, "Testbok i två spalter").locator('[data-testid="make-searchable"]').click()
            page.wait_for_selector('.dialog', timeout=60000)
            page.locator('.dialog .button.primary').click()
            page.wait_for_selector('[data-testid="ocr-cancel"]', timeout=10000)
            page.wait_for_timeout(1500)
            page.click('[data-testid="ocr-cancel"]')
            check(wait_toast(page, "avbröts", 60), "Avbryt ger beskedet att det avbröts")
            page.wait_for_timeout(500)
            check(not os.path.isdir(leftover) or not os.listdir(leftover), "inga filer kvar efter Avbryt")
            check(page.locator('[data-testid="book"]').count() == 3, "ingen ny bok efter Avbryt")
            context.close()
            browser.close()
    finally:
        server.stop()
    check(not CONSOLE, f"inga fel i konsolen: {CONSOLE[:5]}")
    print("ALLT OK" if not FAILURES else f"{len(FAILURES)} FEL")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
