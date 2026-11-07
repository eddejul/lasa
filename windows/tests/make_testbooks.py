"""Testböcker för provkörningen: en PDF med svensk och engelsk text, avstavning över radbrytning,
innehållsförteckning och sidetiketter, plus EPUB, txt och md ur tools/simtest/make_books.py.

  python windows/tests/make_testbooks.py <mapp>

Kräver reportlab. All text är skriven för testet.
"""

import os
import subprocess
import sys
import zipfile

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
SIMTEST = os.path.join(HERE, "..", "..", "tools", "simtest", "make_books.py")

SWEDISH = [
    "Det var en klar morgon i början av september när hon gick genom den gamla staden.",
    "Gatorna var smala och husen stod tätt, som om de ville skydda varandra mot vinden.",
    "Undersökningen visade att de flesta invånarna hade bott på orten i mer än tjugo år.",
    "Svårigheterna med att förstå ett nytt samhälle ligger ofta i det som ingen säger högt.",
    "Hon sprang de sista metrarna till stationen och hann precis med tåget mot norr.",
]
ENGLISH = [
    "The morning was quiet, and the river moved slowly beneath the old stone bridge.",
    "She went to the library to find a book about the history of the town.",
    "The difficulties they encountered were greater than anyone had expected.",
    "Reading carefully is a skill that improves with patience and practice.",
]


def write_lines(c, lines, top=780, size=13):
    c.setFont("Helvetica", size)
    y = top
    for line in lines:
        c.drawString(72, y, line)
        y -= size * 1.6


def make_pdf(path):
    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle("Testbok i PDF")
    c.setAuthor("Läsa")
    # Sida 1: omslag
    c.setFont("Helvetica-Bold", 30)
    c.drawString(72, 600, "Testbok i PDF")
    c.setFont("Helvetica", 16)
    c.drawString(72, 560, "för Läsa på Windows")
    c.bookmarkPage("omslag")
    c.addOutlineEntry("Omslag", "omslag", level=0)
    c.showPage()
    # Sida 2: svensk text med ett avstavat ord över radbrytningen
    c.bookmarkPage("kapitel1")
    c.addOutlineEntry("Kapitel 1: Svenska", "kapitel1", level=0)
    write_lines(c, ["Kapitel 1", "", "Det här kapitlet handlar om kun-", "skap och om hur man undersöker en ny plats."]
                + SWEDISH)
    c.showPage()
    # Sida 3 och 4: mer svensk text
    for number in (3, 4):
        write_lines(c, [f"Sidan {number}", ""] + SWEDISH[number - 3:] + SWEDISH)
        c.showPage()
    # Sida 5: engelsk text
    c.bookmarkPage("kapitel2")
    c.addOutlineEntry("Kapitel 2: English", "kapitel2", level=0)
    write_lines(c, ["Chapter 2", ""] + ENGLISH)
    c.showPage()
    # Sida 6 till 9: fyllnad
    for number in range(6, 10):
        write_lines(c, [f"Sidan {number}", ""] + SWEDISH)
        c.showPage()
    c.save()


def make_script_epub(path):
    """En EPUB med skript i kapitlet. Läsaren ska inte köra dem (Content-Security-Policy stoppar dem)."""
    chapter = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="sv"><head><meta charset="UTF-8"/><title>Skript</title>
<script>parent.document.title = 'HACKAD'; parent.hacked = true;</script></head>
<body><h1>Skriptbok</h1><p>Det här kapitlet försöker köra skript.</p>
<img src="saknas.png" alt="" onerror="parent.document.title = 'HACKAD'; parent.hacked = true;"/></body></html>
"""
    nav = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="sv"><head><title>Innehåll</title></head>
<body><nav epub:type="toc"><ol><li><a href="kap1.xhtml">Skript</a></li></ol></nav></body></html>
"""
    opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:lasa-skript</dc:identifier>
<dc:title>Skriptbok</dc:title><dc:language>sv</dc:language><meta property="dcterms:modified">2026-11-07T12:00:00Z</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="kap1" href="kap1.xhtml" media-type="application/xhtml+xml" properties="scripted"/></manifest>
<spine><itemref idref="kap1"/></spine></package>
"""
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/kap1.xhtml", chapter, compress_type=zipfile.ZIP_DEFLATED)


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out", "books")
    os.makedirs(folder, exist_ok=True)
    make_pdf(os.path.join(folder, "test.pdf"))
    make_script_epub(os.path.join(folder, "skript.epub"))
    subprocess.run([sys.executable, SIMTEST, folder], check=True)
    for name in sorted(os.listdir(folder)):
        print(name, os.path.getsize(os.path.join(folder, name)))


if __name__ == "__main__":
    main()
