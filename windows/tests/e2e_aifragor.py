"""Provkör AI-frågorna (K6b, docs/AI-FRAGOR.md) och frågefilen (K6) i Windows-appen, i Chrome (huvudlöst).

  python windows/tests/e2e_aifragor.py --dictionary <lasa-ordbok.sqlite> --out <mapp> [--port 8970]

Testet gör egna testböcker (en EPUB med tre kapitel och en PDF med innehåll) och startar själv
dev/server.py på --port med en egen datamapp under --out (en process, stoppas på sitt eget PID). Gemini
anropas aldrig: testet svarar på varje anrop (Playwright route) med frågor vars platser och källor tas ur
texten i den skickade frågan, plus en fråga som inte hittas, och provar felbeskeden (ingen nyckel, dagens
kvot, minutens kvot). Skärmbilderna sparas i --out.
"""

import argparse
import json
import os
import re
import sys
import time
import zipfile

import fitz
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e_fas8 import FAILURES, Server, back_to_library, check, new_page, open_book, wait_for  # noqa: E402

GEMINI = 'https://generativelanguage.googleapis.com/**'
TOPICS = ['vanor', 'signaler', 'belöningar', 'miljön', 'viljan', 'minnet', 'uppmärksamheten', 'sömnen']


def sentences(chapter, count, start=1):
    """Unika meningar: varje mening slutar med sitt eget nummer, så att platserna bara hittas en gång."""
    out = []
    for n in range(start, start + count):
        a, b = TOPICS[n % len(TOPICS)], TOPICS[(n * 3 + 1) % len(TOPICS)]
        out.append(f"I {chapter} visar författaren att {a} och {b} påverkar varandra i vardagen enligt exempel nummer {n}.")
    return out


def make_epub(path):
    chapters = [("Omslag", ["Vanans väg. En testbok."])]
    chapters.append(("Slingan", [' '.join(sentences('slingan', 8, 1 + 8 * i)) for i in range(5)]))
    chapters.append(("Miljön", [' '.join(sentences('miljön', 8, 100 + 8 * i)) for i in range(5)]))
    chapters.append(("Att ändra en vana", [' '.join(sentences('slutet', 8, 200 + 8 * i)) for i in range(4)]))
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        manifest, spine, nav = [], [], []
        for i, (title, paragraphs) in enumerate(chapters):
            name = f'kap{i}.xhtml'
            body = ''.join(f'<p>{p}</p>\n' for p in paragraphs)
            z.writestr(f'OEBPS/{name}', '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="sv">'
                       f'<head><title>{title}</title></head><body>\n<h1>{title}</h1>\n{body}</body></html>')
            manifest.append(f'<item id="k{i}" href="{name}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="k{i}"/>')
            nav.append(f'<li><a href="{name}">{title}</a></li>')
        z.writestr('OEBPS/nav.xhtml', '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
                   'xmlns:epub="http://www.idpf.org/2007/ops" lang="sv"><head><title>Innehåll</title></head><body>'
                   f'<nav epub:type="toc"><ol>{"".join(nav)}</ol></nav></body></html>')
        z.writestr('OEBPS/content.opf', '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" '
                   'version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                   '<dc:identifier id="id">vanans-vag</dc:identifier><dc:title>Vanans väg</dc:title><dc:creator>Testförfattare</dc:creator>'
                   '<dc:language>sv</dc:language></metadata><manifest>'
                   '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
                   f'{"".join(manifest)}</manifest><spine>{"".join(spine)}</spine></package>')


def make_pdf(path):
    doc = fitz.open()
    for p in range(6):
        page = doc.new_page(width=595, height=842)
        text = ' '.join(sentences('artikeln', 9, 300 + 9 * p))
        page.insert_textbox(fitz.Rect(60, 70, 535, 800), text, fontsize=12, fontname='helv')
    doc.set_toc([[1, 'Del ett', 1], [1, 'Del två', 4]])
    doc.set_metadata({'title': 'Vanor i artikeln', 'author': 'Testförfattare'})
    doc.save(path)


class Gemini:
    """Svarar på anropen som Gemini: frågor ur texten i frågan, eller ett fel som testet har valt."""

    def __init__(self):
        self.requests = []
        self.errors = []  # (status, body) som skickas i tur och ordning före vanliga svar

    def handle(self, route):
        body = json.loads(route.request.post_data or '{}')
        prompt = body['contents'][0]['parts'][0]['text']
        self.requests.append({'time': time.time(), 'prompt': prompt, 'config': body.get('generationConfig', {}),
                              'key': route.request.headers.get('x-goog-api-key')})
        if self.errors:
            status, error = self.errors.pop(0)
            route.fulfill(status=status, content_type='application/json', body=json.dumps({'error': error}))
            return
        answer = self.compare(prompt) if prompt.startswith('Du bedömer') else self.questions(prompt)
        route.fulfill(status=200, content_type='application/json', body=json.dumps(
            {'candidates': [{'content': {'parts': [{'text': json.dumps(answer, ensure_ascii=False)}]}}]}))

    @staticmethod
    def compare(prompt):
        return {'med': ['Du nämner att exemplen hänger ihop.'], 'saknas': ['Vardagen som ram.'], 'fel': [],
                'omdome': 'delvis', 'kommentar': 'En bra början, men en punkt saknas.'}

    @staticmethod
    def questions(prompt):
        text = prompt.split('<text>\n', 1)[1].rsplit('\n</text>', 1)[0]
        found = [s.strip() for s in re.findall(r'[^.]+\.', text) if len(s.split()) >= 10]
        wanted = int(re.search(r'a\) (\d+) frågo?r? med', prompt).group(1))
        title = re.search(r'^Kapitel: (.+)$', prompt, re.M).group(1)
        fragor = []
        if 'b) Inga' not in prompt:
            fragor.append({'typ': 'huvudpoang', 'nar': 'fore', 'fraga': f'Vad är det viktigaste att leta efter i {title}?',
                           'svar': ['Hur sakerna påverkar varandra.'], 'oppen': False, 'plats': '', 'kalla': found[0]})
        step = max(1, len(found) // wanted)
        kinds = ['varfor', 'egna_ord', 'skillnad', 'belagg', 'vems_rost']
        for i in range(wanted):
            sentence = found[min(len(found) - 1, step * (i + 1) - 1)]
            words = sentence.split()
            fragor.append({'typ': kinds[i % len(kinds)], 'nar': 'efter', 'fraga': f'Vad säger avsnitt {i + 1} om hur sakerna hänger ihop?',
                           'svar': ['De påverkar varandra.', 'Det syns i vardagen.'], 'oppen': False,
                           'plats': ' '.join(words[-6:]), 'kalla': sentence})
        # En fråga vars plats inte står i texten: slängs av kontrollen.
        fragor.append({'typ': 'varfor', 'nar': 'efter', 'fraga': 'Varför står det här inte i texten?', 'svar': ['Det gör det inte.'],
                       'oppen': False, 'plats': 'en plats som inte finns någonstans', 'kalla': found[0]})
        if 'c) Inga' not in prompt:
            fragor.append({'typ': 'sammanfatta', 'nar': 'slut', 'fraga': f'Sammanfatta {title} med två meningar.',
                           'svar': ['Sakerna påverkar varandra.'], 'oppen': False, 'plats': '', 'kalla': ''})
            fragor.append({'typ': 'verkligheten', 'nar': 'slut', 'fraga': 'Var har du själv sett något liknande?',
                           'svar': ['Boken ger exempel ur vardagen.'], 'oppen': True, 'plats': '', 'kalla': ''})
        return {'sammanfattning': f'{title} handlar om hur saker påverkar varandra.', 'begrepp': ['vanor', 'signaler'],
                'fragor': fragor}


def frame_dots(page):
    """Prickarna i EPUB-kapitlen: [(nummer, ruta i fönstret)]. foliate-js överlägg ligger i en stängd skugg-DOM,
    så läsaren ger prickarnas mittpunkter (drawnDots)."""
    dots = page.evaluate("window.lasaTest?.reader?.drawnDots?.() ?? []")
    return [(str(d['number']), {'x': d['x'] - 9, 'y': d['y'] - 9, 'width': 18, 'height': 18}) for d in dots]


def visible_dots(page, frame_list):
    width = page.viewport_size['width']
    return [(n, b) for n, b in frame_list if 0 <= b['x'] + b['width'] / 2 <= width]


def open_reader_panel(page, testid):
    page.locator(f'[data-testid="{testid}"]').click()


def epub_part(page, server, gemini, out):
    open_book(page, 'Vanans väg')
    page.wait_for_selector('foliate-view')
    wait_for(lambda: page.evaluate("Boolean(window.lasaTest?.reader?.sectionCount)"), 15)
    check(page.locator('[data-testid="questions-button"]').is_hidden(), 'knappen Frågor syns inte när frågorna är avstängda')
    # Slå på frågorna i Aa.
    page.locator('.toolbar-button', has_text='Aa').click()
    page.locator('[data-testid="toggle-questions"]').check()
    check(wait_for(lambda: page.locator('[data-testid="questions-button"]').is_visible(), 5), 'Frågor i marginalen slås på i Aa, knappen Frågor syns')
    check(page.locator('[data-testid="toggle-ai-questions"]').is_checked(), 'Gör frågor med AI är på från början')
    page.screenshot(path=os.path.join(out, 'ai-01-aa.png'))
    page.keyboard.press('Escape')
    # Till kapitlet Slingan: frågorna görs när kapitlet visas, och sedan nästa kapitels.
    page.locator('[data-testid="toc-button"]').click()
    page.locator('.toc-item', has_text='Slingan').click()
    check(wait_for(lambda: len(gemini.requests) >= 2, 40), f'två anrop: kapitlet som visas och nästa ({len(gemini.requests)})')
    first = gemini.requests[0] if gemini.requests else {'prompt': '', 'config': {}}
    check('Kapitel: Slingan' in first['prompt'] and first['prompt'].startswith('Du gör frågor som hjälper en läsare'),
          'frågan har kapitlets rubrik och börjar som kravet')
    check(first['config'].get('maxOutputTokens') == 8192 and first['config'].get('temperature') == 0.3
          and first['config'].get('responseJsonSchema', {}).get('required') == ['sammanfattning', 'begrepp', 'fragor'],
          f'maxOutputTokens, temperature och schemat: {first["config"].get("maxOutputTokens")}')
    check('Bok: Vanans väg, av Testförfattare' in first['prompt'], 'boken och författaren i frågan')
    text = first['prompt'].split('<text>\n', 1)[1].rsplit('\n</text>', 1)[0]
    check('\n\n' in text and '<p>' not in text, 'kapitlets text utan taggar, stycken åtskilda av en tom rad')
    check(all('Kapitel: Omslag' not in r['prompt'] for r in gemini.requests), 'omslaget (för kort) skickas inte')
    rows = wait_for(lambda: server.sql("SELECT chapter, part, questions FROM ai_questions WHERE chapter IN ('k0', 'k1')") if len(
        server.sql("SELECT chapter FROM ai_questions WHERE chapter IN ('k0', 'k1')")) == 2 else None, 20) or []
    stored = {r[0]: json.loads(r[2]) for r in rows}
    check(stored.get('k0') == [], 'omslaget sparas som klart utan frågor')
    k1 = stored.get('k1', [])
    check(len([q for q in k1 if q['nar'] == 'efter']) >= 2 and not any('inte i texten' in q['fraga'] for q in k1),
          f'kapitlets frågor sparas, frågan som inte hittas slängs ({len(k1)})')
    check(all(q['id'].startswith('ai') for q in k1), 'id:na börjar med ai')
    dots = wait_for(lambda: visible_dots(page, frame_dots(page)), 15) or []
    check(len(dots) >= 1, f'prickarna syns i marginalen ({len(dots)})')
    page.screenshot(path=os.path.join(out, 'ai-02-epub-prickar.png'))
    if not dots:
        return
    number, box = dots[0]
    check(number == '1', f'första pricken har nummer 1 ({number})')
    page.mouse.click(box['x'] + box['width'] / 2, box['y'] + box['height'] / 2)
    check(wait_for(lambda: page.locator('[data-testid="question-box"]').is_visible(), 5), 'ett klick på pricken öppnar rutan')
    box_text = page.locator('[data-testid="question-box"]').inner_text()
    check('Ur boken' not in box_text and 'Visa i boken' not in box_text, 'varken källan eller platsen syns före svaret')
    check(page.locator('[data-testid="my-answer"]').get_attribute('placeholder') == 'Skriv eller diktera ditt svar', 'rutan Ditt svar')
    check('Windows-tangenten och H dikterar.' in box_text and 'Gjord med AI' in box_text, 'raden om diktering och Gjord med AI')
    check(page.locator('[data-testid="compare"]').is_hidden(), 'Jämför syns inte innan något skrivits')
    page.screenshot(path=os.path.join(out, 'ai-03-rutan-fore.png'))
    page.locator('[data-testid="my-answer"]').fill('De hänger ihop med varandra.')
    check(page.locator('[data-testid="compare"]').is_visible(), 'Jämför syns när något skrivits och det finns en nyckel')
    page.locator('[data-testid="reveal"]').click()
    check(page.locator('[data-testid="source"]').is_visible() and page.locator('[data-testid="show-in-book"]').is_visible(),
          'Visa svaret visar punkterna, Ur boken och Visa i boken')
    page.screenshot(path=os.path.join(out, 'ai-04-rutan-efter.png'))
    before = len(gemini.requests)
    page.locator('[data-testid="compare"]').click()
    check(wait_for(lambda: page.locator('.feedback-med').count() == 1, 15), 'Jämför visar Med, Saknas och kommentaren')
    compare_prompt = gemini.requests[before]['prompt'] if len(gemini.requests) > before else ''
    check(compare_prompt.startswith('Du bedömer en läsares svar') and '<text>' not in compare_prompt
          and 'Läsarens svar: De hänger ihop med varandra.' in compare_prompt, 'Jämförs fråga utan kapitlets text')
    check('suggested' in (page.locator('[data-testid="status-osaker"]').get_attribute('class') or ''), 'delvis föreslår Osäker')
    page.screenshot(path=os.path.join(out, 'ai-05-jamfor.png'))
    qid = k1[0]['id'] if k1 else ''
    page.locator('[data-testid="status-osaker"]').click()
    saved = wait_for(lambda: server.sql("SELECT status, my_answer, feedback FROM question_answers WHERE status = 'osaker'"), 5) or []
    check(bool(saved) and saved[0][1] == 'De hänger ihop med varandra.' and json.loads(saved[0][2]).get('omdome') == 'delvis',
          f'svaret, valet och Jämförs svar sparas ({saved[:1]})')
    del qid

    # Panelen Frågor.
    open_reader_panel(page, 'questions-button')
    page.wait_for_selector('[data-testid="ai-line"]')
    line = page.locator('[data-testid="ai-line"]').inner_text()
    check('AI-frågor:' in line and 'av 3 kapitel' in line, f'raden om AI-frågorna: {line!r}')
    check(page.locator('[data-testid="question-chapter"]').count() >= 1, 'panelen visar kapitlen med frågor')
    page.screenshot(path=os.path.join(out, 'ai-06-panelen.png'))
    # Gör frågor till hela boken: resten av kapitlen, med fyra sekunders paus mellan anropen.
    before = len(gemini.requests)
    if page.locator('[data-testid="ai-whole-book"]').count():
        page.locator('[data-testid="ai-whole-book"]').click()
        wait_for(lambda: page.locator('[data-testid="ai-progress"]').count() == 1, 3)
        page.screenshot(path=os.path.join(out, 'ai-07-hela-boken.png'))
        check(wait_for(lambda: '3 av 3 kapitel har frågor' in page.locator('[data-testid="ai-line"]').inner_text(), 40),
              'hela boken har frågor efter Gör frågor till hela boken')
    calls = gemini.requests[before:]
    gaps = [b['time'] - a['time'] for a, b in zip(calls, calls[1:])]
    check(all(gap >= 3.8 for gap in gaps), f'fyra sekunders paus mellan anropen: {[round(g, 1) for g in gaps]}')
    last_prompt = next((r['prompt'] for r in reversed(gemini.requests) if 'Kapitel: Att ändra en vana' in r['prompt']), '')
    check('Det här är bokens sista kapitel' in last_prompt, 'bokens sista kapitel får en syntesfråga')
    check('- Slingan: Slingan handlar om' in last_prompt, 'tidigare kapitlens sammanfattningar följer med')
    page.keyboard.press('Escape')

    # Läs för att ta reda på: när kapitlet Miljön börjar.
    page.locator('[data-testid="toc-button"]').click()
    page.locator('.toc-item', has_text='Miljön').click()
    check(wait_for(lambda: page.locator('[data-testid="before-reading"]').is_visible(), 8), 'raden Läs för att ta reda på')
    page.screenshot(path=os.path.join(out, 'ai-08-fore-lasningen.png'))
    page.locator('[data-testid="before-reading"] button', has_text='Visa').click()
    check(wait_for(lambda: page.locator('[data-testid="question-box"]').is_visible(), 3), 'Visa öppnar fore-frågorna')
    page.keyboard.press('Escape')
    # Kapitlet är slut: bläddra förbi kapitlets sista sida.
    for _ in range(30):
        page.keyboard.press('ArrowRight')
        page.wait_for_timeout(250)
        if page.locator('[data-testid="chapter-end"]').count():
            break
    check(page.locator('[data-testid="chapter-end"]').count() == 1, 'raden Kapitlet är slut när man bläddrar förbi kapitlet')
    if page.locator('[data-testid="chapter-end"]').count():
        page.screenshot(path=os.path.join(out, 'ai-09-kapitlet-slut.png'))
        check(re.search(r'Kapitlet är slut: \d+ frågor', page.locator('[data-testid="chapter-end"]').inner_text()) is not None,
              'raden räknar frågorna')
    back_to_library(page)


def pdf_part(page, server, gemini, out):
    before = len(gemini.requests)
    # Minutens kvot: första svaret är 429 med retryDelay, sedan försöks det en gång till.
    gemini.errors = [(429, {'code': 429, 'message': 'Resource exhausted', 'details': [{'retryDelay': '1s'}]})]
    open_book(page, 'Vanor i artikeln')
    page.wait_for_selector('.pdf-spread .pdf-page canvas')
    check(wait_for(lambda: server.sql("SELECT chapter FROM ai_questions WHERE chapter = 'p1-3'"), 40), 'PDF: kapitlets frågor görs')
    # Testsvaret lägger platserna på sidorna 2 och 3.
    page.keyboard.press('ArrowRight')
    check(wait_for(lambda: page.locator('.pdf-dots .question-dot').count() >= 1, 10), 'PDF: prickarna syns vid platserna')
    pdf_calls = gemini.requests[before:]
    check(len(pdf_calls) >= 2 and pdf_calls[0]['prompt'] == pdf_calls[1]['prompt'], 'minutens kvot: samma fråga en gång till')
    prompt = pdf_calls[0]['prompt'] if pdf_calls else ''
    check('Kapitel: Del ett' in prompt, 'PDF: kapitlet ur innehållet')
    check('Andra böcker som läsaren har läst:\n- Vanans väg:' in prompt, 'andra böcker med frågor följer med')
    rows = server.sql("SELECT chapter FROM ai_questions WHERE chapter LIKE 'p%' ORDER BY chapter")
    check(['p1-3'] == [r[0] for r in rows][:1], f'PDF: nyckeln p<första>-<sista> ({rows})')
    page.screenshot(path=os.path.join(out, 'ai-10-pdf-prickar.png'))
    page.locator('.pdf-dots .question-dot').first.click()
    check(wait_for(lambda: page.locator('[data-testid="question-box"]').is_visible(), 3), 'PDF: pricken öppnar rutan')
    page.locator('[data-testid="reveal"]').click()
    page.locator('[data-testid="show-in-book"]').click()
    check(wait_for(lambda: page.locator('[data-testid="search-hit"]').count() >= 1, 5), 'Visa i boken ringar in källan')
    page.screenshot(path=os.path.join(out, 'ai-11-visa-i-boken.png'))

    # Dagens kvot: kön stoppas och panelen säger när den fylls på.
    gemini.errors = [(429, {'code': 429, 'message': 'Quota exceeded', 'details': [
        {'@type': 'type.googleapis.com/google.rpc.QuotaFailure', 'violations': [{'quotaId': 'GenerateRequestsPerDayPerProjectPerModel-FreeTier'}]}]})]
    open_reader_panel(page, 'questions-button')
    page.wait_for_selector('[data-testid="ai-line"]')
    page.locator('[data-testid="ai-replace-chapter"]').first.click()
    page.locator('.modal-backdrop .button.primary', has_text='Gör nya frågor').click()
    check(wait_for(lambda: 'Dagens gratiskvot hos Google är slut' in page.locator('[data-testid="ai-line"]').inner_text(), 10),
          'dagens kvot: beskedet med klockslaget')
    page.screenshot(path=os.path.join(out, 'ai-12-kvoten.png'))
    page.keyboard.press('Escape')
    page.wait_for_timeout(300)

    # Frågefilen går före: Välj frågefil kopierar filen till appens data, och AI-frågorna döljs.
    quote = 'påverkar varandra i vardagen enligt exempel nummer 305'
    page.keyboard.press('Home')
    question_file = os.path.join(out, 'Vanor i artikeln.fragor.json')
    with open(question_file, 'w', encoding='utf-8') as file:
        json.dump({'sensus': 'frågor', 'version': 1, 'fragor': [
            {'id': 'f1', 'sida': 1, 'citat': quote, 'titel': 'Ur filen', 'fraga': 'Vad visar exempel nummer 305?', 'svar': ['Att sakerna hänger ihop.']},
            {'sida': 2, 'y': 0.5, 'fraga': 'En fråga utan citat på sida 2.'}]}, file, ensure_ascii=False)
    open_reader_panel(page, 'questions-button')
    with page.expect_file_chooser() as chooser:
        page.locator('[data-testid="choose-question-file"]').click()
    chooser.value.set_files(question_file)
    check(wait_for(lambda: server.sql("SELECT name FROM question_files"), 5) == [['Vanor i artikeln.fragor.json']], 'frågefilen sparas i appens data')
    check(wait_for(lambda: page.locator('.pdf-dots .question-dot').count() == 1, 5),
          f'bara frågefilens prick på sida 1 ({page.locator(".pdf-dots .question-dot").count()})')
    page.keyboard.press('Escape')
    page.locator('.pdf-dots .question-dot').first.click()
    check(wait_for(lambda: 'Ur filen' in page.locator('[data-testid="question-box"]').inner_text(), 3), 'frågefilens fråga i rutan')
    check(page.locator('[data-testid="my-answer"]').count() == 0, 'frågefilens fråga ser ut som i dag (ingen ruta Ditt svar)')
    page.keyboard.press('Escape')
    page.screenshot(path=os.path.join(out, 'ai-13-fragefil.png'))
    back_to_library(page)


def no_key_part(page, server, out):
    server.api('secret_set', {'name': 'gemini-api-key', 'value': None})
    open_book(page, 'Vanans väg')
    page.wait_for_selector('foliate-view')
    wait_for(lambda: page.locator('[data-testid="questions-button"]').is_visible(), 10)
    open_reader_panel(page, 'questions-button')
    check(wait_for(lambda: 'inte uppsatt' in page.locator('[data-testid="questions-panel"]').inner_text(), 5),
          'utan nyckel: beskedet och en knapp till Inställningar')
    page.screenshot(path=os.path.join(out, 'ai-14-ingen-nyckel.png'))
    page.keyboard.press('Escape')
    back_to_library(page)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dictionary', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--port', type=int, default=8970)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    os.makedirs(args.out, exist_ok=True)
    books = os.path.join(args.out, 'bocker')
    data = os.path.join(args.out, 'data')
    for folder in (books, data):
        os.makedirs(folder, exist_ok=True)
        for name in os.listdir(folder):
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                os.remove(path)
    os.makedirs(os.path.join(data, 'Böcker'), exist_ok=True)
    make_epub(os.path.join(books, 'Vanans väg.epub'))
    make_pdf(os.path.join(books, 'Vanor i artikeln.pdf'))
    server = Server(args.dictionary, data, args.port, os.path.join(args.out, 'server.log'))
    gemini = Gemini()
    console = []
    try:
        server.api('secret_set', {'name': 'gemini-api-key', 'value': 'provnyckel-aifragor'})
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel='chrome', headless=True)
            page = new_page(browser)
            page.on('console', lambda m: console.append(f'{m.type}: {m.text}'))
            page.route(GEMINI, gemini.handle)
            page.goto(server.url)
            page.set_input_files('[data-testid="file-input"]', [os.path.join(books, 'Vanans väg.epub'), os.path.join(books, 'Vanor i artikeln.pdf')])
            check(wait_for(lambda: page.locator('[data-testid="book"]').count() == 2, 20), 'två testböcker i biblioteket')
            epub_part(page, server, gemini, args.out)
            pdf_part(page, server, gemini, args.out)
            no_key_part(page, server, args.out)
            check(all(r['key'] == 'provnyckel-aifragor' for r in gemini.requests), 'alla anrop har testets nyckel')
            browser.close()
    finally:
        server.stop()
    summaries = [line for line in console if 'AI-frågor ' in line]
    print('\n'.join(summaries[:6]))
    check(any(re.search(r'AI-frågor k1: \d+ av \d+ behölls \(plats 1', line) for line in summaries), 'konsolen räknar de slängda per orsak')
    errors = [line for line in console if line.startswith(('error', 'pageerror')) and 'Failed to load resource' not in line]
    check(not errors, f'inga fel i konsolen: {errors[:3]}')
    print(f'\n{len(FAILURES)} fel')
    sys.exit(1 if FAILURES else 0)


if __name__ == '__main__':
    main()
