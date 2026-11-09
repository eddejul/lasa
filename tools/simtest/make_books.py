"""Skapar testböcker för simulatortestet: en EPUB 3 med innehållsförteckning, fotnot, bild och ett
engelskt kapitel, samt samma sorts text som txt (Windows-1252, radbruten), Markdown, RTF och en PDF
med textlager (fas 4: markeringar, bokmärken och sökning).

All text är skriven för testet och fri att använda.

Användning: python3 tools/simtest/make_books.py <mapp>
"""

import random
import sys
import zipfile
from pathlib import Path

SWEDISH = [
    "Det var en klar morgon i början av september när hon för första gången gick genom den gamla staden.",
    "Gatorna var smala och husen stod tätt, som om de ville skydda varandra mot vinden från havet.",
    "Hon hade läst om platsen i flera böcker, men ingen av dem hade förberett henne på ljuset.",
    "Kunskap kommer sällan av sig själv, den måste sökas upp och prövas mot verkligheten.",
    "I hamnen låg några fiskebåtar och guppade, och en man lagade nät i solen utan att se upp.",
    "Svårigheterna med att förstå ett nytt samhälle ligger ofta i det som ingen säger högt.",
    "Hon sprang de sista metrarna till stationen och hann precis med tåget mot norr.",
    "Undersökningen visade att de flesta invånarna hade bott på orten i mer än tjugo år.",
    "Utvecklingen hade gått långsamt, men den hade inte stannat, och det märktes i små detaljer.",
    "På eftermiddagen satt hon på biblioteket och skrev ner allt hon hade sett under dagen.",
    "Betydelsen av ett ord kan skifta beroende på vem som använder det och i vilket sammanhang.",
    "Ingen visste riktigt varför bron hade byggts så högt, men alla var överens om att den var vacker.",
    "När kvällen kom tändes lamporna ett efter ett längs kajen, och luften blev kall och fuktig.",
    "Hon funderade länge på vad hon egentligen ville åstadkomma med sin resa.",
    "Det fanns ett lugn i rutinerna, i att varje dag liknade den förra utan att vara likadan.",
    "Läraren hade en gång sagt att den som läser noga ser mer än den som läser mycket.",
    "Vinden vände under natten, och på morgonen låg dimman tät över vattnet.",
    "Hon samlade sina anteckningar i en tjock pärm och märkte varje kapitel med en färgad flik.",
    "Diskussionen i gruppen blev livlig när någon ifrågasatte metoden som de hade valt.",
    "Det är skillnad på att veta något och att förstå varför det är så.",
    "Han berättade om sin barndom på landet, om skolan och om vintrarna som aldrig tog slut.",
    "Varje försök att beskriva staden blev för kort, som om orden inte räckte till.",
    "De bestämde sig för att vänta tills regnet hade upphört innan de gick vidare.",
    "Resultatet var tydligt, även om det inte var det som någon av dem hade hoppats på.",
]

ENGLISH = [
    "The morning was quiet, and the river moved slowly beneath the old stone bridge.",
    "She went to the library to find a book about the history of the town.",
    "Knowledge is not simply collected; it is built, tested and sometimes abandoned.",
    "The difficulties they encountered were greater than anyone had expected.",
    "He ran along the shore until the lights of the harbour disappeared behind him.",
    "Every attempt to explain the result led to new and more interesting questions.",
    "The committee decided to postpone the decision until the following spring.",
    "Reading carefully is a skill that improves with patience and practice.",
]

STYLE = """body { font-family: Georgia, serif; }
h1 { font-size: 1.6em; margin: 0 0 1em 0; line-height: 1.2; }
h2 { font-size: 1.2em; margin: 1.2em 0 0.6em 0; }
p { margin: 0; text-indent: 1.2em; line-height: 1.45; text-align: justify; }
h1 + p, h2 + p { text-indent: 0; }
.not { font-size: 0.9em; text-indent: 0; margin-bottom: 0.6em; }
figure { margin: 1em 0; text-align: center; }
figcaption { font-size: 0.85em; font-style: italic; }
"""

COVER_SVG = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900" viewBox="0 0 600 900">
<rect width="600" height="900" fill="#2f5d62"/>
<rect x="40" y="40" width="520" height="820" fill="none" stroke="#f4ecd8" stroke-width="6"/>
<text x="300" y="380" font-family="Georgia" font-size="64" fill="#f4ecd8" text-anchor="middle">Testbok</text>
<text x="300" y="460" font-family="Georgia" font-size="36" fill="#f4ecd8" text-anchor="middle">för Läsa</text>
</svg>
"""

FIGURE_SVG = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400" viewBox="0 0 600 400">
<rect width="600" height="400" fill="#ffffff"/>
<rect x="60" y="250" width="80" height="100" fill="#c0504d"/>
<rect x="200" y="180" width="80" height="170" fill="#4f81bd"/>
<rect x="340" y="120" width="80" height="230" fill="#9bbb59"/>
<rect x="480" y="60" width="80" height="290" fill="#8064a2"/>
<line x1="40" y1="350" x2="580" y2="350" stroke="#000000" stroke-width="3"/>
</svg>
"""


def paragraphs(pool, count, rng, low=4, high=7):
    return [" ".join(rng.choice(pool) for _ in range(rng.randint(low, high))) for _ in range(count)]


def xhtml(title, body, lang="sv"):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{lang}" lang="{lang}">
<head>
<meta charset="UTF-8"/>
<title>{title}</title>
<link rel="stylesheet" type="text/css" href="styles.css"/>
</head>
<body>
{body}
</body>
</html>
"""


def make_epub(path, rng):
    chapter1 = paragraphs(SWEDISH, 12, rng)
    # Mjukt bindestreck i ett ord och ett kursivt ord, för ordfunktionen.
    chapter1[0] = ("Det här kapitlet handlar om kun&#173;skap och om hur man <em>undersöker</em> en ny plats. "
                   + chapter1[0])
    chapter2 = paragraphs(SWEDISH, 60, rng)
    chapter3 = paragraphs(SWEDISH, 14, rng)
    chapter3[0] = ("Det här stycket har en fotnot"
                   '<a href="noter.xhtml#not1" id="ref1" epub:type="noteref"><sup>1</sup></a> '
                   "som går att trycka på. " + chapter3[0])
    chapter4 = paragraphs(ENGLISH, 12, rng)
    chapter5 = paragraphs(SWEDISH, 2, rng)

    def body(heading, items, extra=""):
        return f"<h1>{heading}</h1>\n" + "\n".join(f"<p>{p}</p>" for p in items) + extra

    middle = len(chapter3) // 2
    chapter3_body = (
        "<h1>Kapitel 3: Fotnoter</h1>\n"
        + "\n".join(f"<p>{p}</p>" for p in chapter3[:middle])
        + '\n<h2 id="avsnitt">3.1 Ett avsnitt</h2>\n'
        + "\n".join(f"<p>{p}</p>" for p in chapter3[middle:])
    )
    figure = ('\n<figure><img src="images/figur.svg" alt="Stapeldiagram" width="600" height="400"/>'
              "<figcaption>Figur 1. Fyra staplar.</figcaption></figure>")

    documents = {
        "cover.xhtml": xhtml("Omslag", '<div style="text-align:center"><img src="images/cover.svg" alt="Omslag"/></div>'),
        "kap1.xhtml": xhtml("Kapitel 1", body("Kapitel 1: Början", chapter1)),
        "kap2.xhtml": xhtml("Kapitel 2", body("Kapitel 2: En lång väg", chapter2)),
        "kap3.xhtml": xhtml("Kapitel 3", chapter3_body),
        "kap4.xhtml": xhtml("Chapter 4", body("Kapitel 4: English", chapter4), lang="en"),
        "kap5.xhtml": xhtml("Kapitel 5", body("Kapitel 5: Kort", chapter5, figure)),
        "noter.xhtml": xhtml("Noter", '<h1>Noter</h1>\n<p class="not" id="not1"><a href="kap3.xhtml#ref1">1</a> '
                                     "Det här är fotnotens text. Tryck på Tillbaka för att komma tillbaka.</p>"),
    }
    spine = ["cover", "kap1", "kap2", "kap3", "kap4", "kap5", "noter"]

    nav = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="sv">
<head><meta charset="UTF-8"/><title>Innehåll</title></head>
<body>
<nav epub:type="toc" id="toc"><h1>Innehåll</h1>
<ol>
<li><a href="kap1.xhtml">Kapitel 1: Början</a></li>
<li><a href="kap2.xhtml">Kapitel 2: En lång väg</a></li>
<li><a href="kap3.xhtml">Kapitel 3: Fotnoter</a>
<ol><li><a href="kap3.xhtml#avsnitt">3.1 Ett avsnitt</a></li></ol>
</li>
<li><a href="kap4.xhtml">Kapitel 4: English</a></li>
<li><a href="kap5.xhtml">Kapitel&nbsp;5: Kort</a></li>
<li><a href="noter.xhtml">Noter</a></li>
</ol>
</nav>
</body>
</html>
"""
    ncx_points = "\n".join(
        f'<navPoint id="p{i}" playOrder="{i}"><navLabel><text>{name}</text></navLabel><content src="{name}.xhtml"/></navPoint>'
        for i, name in enumerate(spine[1:], start=1)
    )
    ncx = f"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:uuid:lasa-testbok"/></head>
<docTitle><text>Testbok för Läsa</text></docTitle>
<navMap>
{ncx_points}
</navMap>
</ncx>
"""
    manifest = "\n".join(
        f'<item id="{name}" href="{name}.xhtml" media-type="application/xhtml+xml"/>' for name in spine
    )
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="sv">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">urn:uuid:lasa-testbok</dc:identifier>
<dc:title>Testbok för Läsa</dc:title>
<dc:creator>Sensus Testsson</dc:creator>
<dc:language>sv</dc:language>
<meta property="dcterms:modified">2026-11-07T12:00:00Z</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="css" href="styles.css" media-type="text/css"/>
<item id="coverimage" href="images/cover.svg" media-type="image/svg+xml" properties="cover-image"/>
<item id="figure" href="images/figur.svg" media-type="image/svg+xml"/>
{manifest}
</manifest>
<spine toc="ncx">
{chr(10).join(f'<itemref idref="{name}"/>' for name in spine)}
</spine>
</package>
"""
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/styles.css", STYLE, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/images/cover.svg", COVER_SVG, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/images/figur.svg", FIGURE_SVG, compress_type=zipfile.ZIP_DEFLATED)
        for name, text in documents.items():
            archive.writestr("OEBPS/" + name, text, compress_type=zipfile.ZIP_DEFLATED)


def wrap(text, width=68):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    if line:
        lines.append(line)
    return lines


def make_txt(path, rng):
    out = []
    for number in range(1, 4):
        out += [f"KAPITEL {number}", ""]
        for paragraph in paragraphs(SWEDISH, 14, rng):
            out += wrap(paragraph) + [""]
    path.write_bytes("\r\n".join(out).encode("cp1252"))


def make_md(path, rng):
    parts = ["# Anteckningar om staden", "", paragraphs(SWEDISH, 1, rng)[0], "",
             "## Det viktigaste", "",
             "- **Kunskap** måste prövas.", "- *Svårigheter* finns i det osagda.", "- Läs noga.", "",
             "1. Första steget", "2. Andra steget", "",
             "> " + paragraphs(SWEDISH, 1, rng, 2, 3)[0], "",
             "```", "kod = 'visas som den är'", "```", "",
             "Mer om [svenska ord](https://svenska.se) finns på nätet.", "", "---", ""]
    parts += [p + "\n" for p in paragraphs(SWEDISH, 10, rng)]
    parts += ["# Andra delen", ""] + [p + "\n" for p in paragraphs(SWEDISH, 12, rng)]
    path.write_text("\n".join(parts), encoding="utf-8")


def rtf_escape(text):
    out = []
    for char in text:
        code = ord(char)
        if char in "\\{}":
            out.append("\\" + char)
        elif code < 128:
            out.append(char)
        elif code < 256:
            out.append(f"\\'{code:02x}")
        else:
            out.append(f"\\u{code if code < 32768 else code - 65536}?")
    return "".join(out)


def make_rtf(path, rng):
    body = ["{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\froman Times New Roman;}}",
            "{\\colortbl;\\red0\\green0\\blue0;}", "\\f0\\fs24 {\\b " + rtf_escape("Rubrik i RTF") + "}\\par"]
    for paragraph in paragraphs(SWEDISH, 16, rng):
        body.append(rtf_escape(paragraph) + " \\emdash  slut.\\par")
    body.append("}")
    path.write_text("\n".join(body), encoding="ascii")


def pdf_string(text):
    """En textsträng i PDF:ens innehåll, i Windows-1252 som typsnittets kodning (WinAnsiEncoding)."""
    out = []
    for byte in text.encode("cp1252"):
        if byte in b"\\()":
            out.append("\\" + chr(byte))
        elif 32 <= byte < 127:
            out.append(chr(byte))
        else:
            out.append(f"\\{byte:03o}")
    return "(" + "".join(out) + ")"


def make_pdf(path, rng):
    """En liten PDF med textlager: åtta A4-sidor med rubrik och stycken, svenska och engelska.
    Sida 2 har ordet kunskap avstavat över en radbrytning, för sökningen.
    Innehållet (bokmärkena) har tre kapitel på sidorna 1, 3 och 6, för sidor kvar i kapitlet (V1) och
    kapitelstrecken i tidslinjen (V2). Sida 3 har en fotnotssiffra med en intern länk till noten nederst
    på sida 8, för fotnoten i en ruta (V5)."""
    pages = []
    for number in range(1, 9):
        pool = ENGLISH if number == 6 else SWEDISH
        lines = []
        for paragraph in paragraphs(pool, 7, rng, 3, 5):
            lines += wrap(paragraph, 74) + [""]
        if number == 2:
            lines = ["Den som söker kun-", "skap måste läsa noga och pröva det hon läser.", ""] + lines
        # Sida 8 slutar högre upp, så att fotnoten står ensam nederst.
        pages.append((f"Kapitel {number}", lines[:40] if number == 8 else lines[:46]))

    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    page_tree = add(None)
    regular = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    bold = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    # B1: titel och författare i dokumentets metadata, som biblioteket visar i stället för filnamnet.
    info = add(b"<< /Title (Provbok med textlager) /Author (Sensus Testsson) >>")
    # Sidornas objekt först, så att länken på sida 3 kan peka på sida 8.
    kids = [add(None) for _ in pages]
    for number, (title, lines) in enumerate(pages, start=1):
        content = [f"BT /F2 18 Tf 60 780 Td {pdf_string(title)} Tj ET", "BT /F1 12 Tf 15 TL 60 748 Td"]
        for line in lines:
            content.append(f"{pdf_string(line)} Tj T*")
        content.append("ET")
        annots = ""
        if number == 3:
            # V5: en fotnotssiffra med en intern länk till noten nederst på sida 8.
            content.append(f"BT /F1 12 Tf 60 806 Td {pdf_string('Det här stycket har en fotnot.')} Tj ET")
            content.append(f"BT /F1 8 Tf 216 811 Td {pdf_string('1')} Tj ET")
            annots = (" /Annots [<< /Type /Annot /Subtype /Link /Rect [212 805 226 821] /Border [0 0 0] "
                      "/Dest [%d 0 R /XYZ 0 84 0] >>]" % kids[7])
        if number == 8:
            content.append(f"BT /F1 9 Tf 60 70 Td {pdf_string('1 Fotnoten i PDF:en. En kort förklaring som visas i en ruta vid siffran.')} Tj ET")
        stream = "\n".join(content).encode("latin-1")
        contents = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        objects[kids[number - 1] - 1] = ("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] "
                                         "/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R%s >>"
                                         % (page_tree, regular, bold, contents, annots)).encode("ascii")
    # Innehållet: tre kapitel (V1, V2).
    chapters = [("Kapitel 1", 0), ("Kapitel 3", 2), ("Kapitel 6", 5)]
    outlines = add(None)
    items = [add(None) for _ in chapters]
    for position, (title, page) in enumerate(chapters):
        links = ""
        if position > 0:
            links += " /Prev %d 0 R" % items[position - 1]
        if position < len(chapters) - 1:
            links += " /Next %d 0 R" % items[position + 1]
        objects[items[position] - 1] = ("<< /Title %s /Parent %d 0 R /Dest [%d 0 R /XYZ 0 842 0]%s >>"
                                        % (pdf_string(title), outlines, kids[page], links)).encode("latin-1")
    objects[outlines - 1] = ("<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>"
                             % (items[0], items[-1], len(items))).encode("ascii")
    objects[catalog - 1] = ("<< /Type /Catalog /Pages %d 0 R /Outlines %d 0 R >>" % (page_tree, outlines)).encode("ascii")
    objects[page_tree - 1] = ("<< /Type /Pages /Kids [%s] /Count %d >>"
                              % (" ".join(f"{kid} 0 R" for kid in kids), len(kids))).encode("ascii")

    data = bytearray(b"%PDF-1.4\n%\xe5\xe4\xf6\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(data))
        data += b"%d 0 obj\n" % index + body + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        data += b"%010d 00000 n \n" % offset
    data += b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1, catalog, info, xref)
    path.write_bytes(bytes(data))


def make_png(width, height):
    """En PNG utan bibliotek: bläckblå yta med en ljus ram, som omslag i roman.epub (B1)."""
    import struct
    import zlib
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            frame = (18 <= x < 24 or width - 24 <= x < width - 18 or 18 <= y < 24 or height - 24 <= y < height - 18)
            band = height // 3 <= y < height // 3 + 70 and 50 <= x < width - 50
            rows += bytes((244, 236, 216)) if frame or band else bytes((45, 91, 132))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def make_cover_epub(path):
    """B1: en kort EPUB 2 med ett PNG-omslag (<meta name="cover">) och två författare, för bibliotekets omslag."""
    chapter = xhtml("Första kapitlet", "<h1>Första kapitlet</h1>"
                    + "".join(f"<p>{line}</p>" for line in SWEDISH[:12]))
    opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
<dc:identifier id="uid">urn:uuid:lasa-omslagsbok</dc:identifier>
<dc:title>Ljuset över hamnen</dc:title>
<dc:creator opf:role="aut">Anna Exempel</dc:creator>
<dc:creator opf:role="aut">Erik Prov</dc:creator>
<dc:language>sv</dc:language>
<meta name="cover" content="omslagsbild"/>
</metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="omslagsbild" href="bilder/framsida.png" media-type="image/png"/>
<item id="kap1" href="text/kap1.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine toc="ncx"><itemref idref="kap1"/></spine>
</package>
"""
    ncx = """<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:uuid:lasa-omslagsbok"/></head>
<docTitle><text>Ljuset över hamnen</text></docTitle>
<navMap><navPoint id="n1" playOrder="1"><navLabel><text>Första kapitlet</text></navLabel>
<content src="text/kap1.xhtml"/></navPoint></navMap>
</ncx>
"""
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/bilder/framsida.png", make_png(400, 600), compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/text/kap1.xhtml", chapter, compress_type=zipfile.ZIP_DEFLATED)


def make_photo_pdf(path, rng):
    """G5: en fotad PDF som Edvins kamerafoton av kursböcker: tolv sidor, var och en en stor JPEG
    (2400 x 3200) utan textlager. Bilden görs som BMP och omvandlas till JPEG med macOS sips.
    Varje sida har en egen kopia av bilden, så att PDFKit avkodar varje sida för sig."""
    import subprocess
    import tempfile
    width, height = 2400, 3200
    row_size = width * 3
    rows = []
    for variant in range(48):
        row = bytearray(row_size)
        base = 205 + variant % 30
        for x in range(0, width):
            shade = base - (x * 40) // width + rng.randint(-12, 12)
            if variant % 7 == 0 and 200 < x < 2200 and rng.random() < 0.35:
                shade = 40 + rng.randint(0, 30)
            shade = max(0, min(255, shade))
            row[x * 3:x * 3 + 3] = bytes((shade - 8 if shade > 8 else shade, shade, shade + 6 if shade < 249 else shade))
        rows.append(bytes(row))
    pixels = bytearray()
    for y in range(height):
        pixels += rows[(y * 7 + (y // 60) * 13) % len(rows)]
    header = b"BM" + (54 + len(pixels)).to_bytes(4, "little") + b"\0\0\0\0" + (54).to_bytes(4, "little")
    info = ((40).to_bytes(4, "little") + width.to_bytes(4, "little") + height.to_bytes(4, "little")
            + (1).to_bytes(2, "little") + (24).to_bytes(2, "little") + b"\0" * 24)
    with tempfile.TemporaryDirectory() as folder:
        bmp = Path(folder) / "sida.bmp"
        jpg = Path(folder) / "sida.jpg"
        bmp.write_bytes(header + info + bytes(pixels))
        result = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", str(bmp), "--out", str(jpg)],
                                capture_output=True)
        if result.returncode != 0 or not jpg.exists():
            print("sips saknas, ingen fotad PDF")
            return
        image = jpg.read_bytes()

    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    page_tree = add(None)
    kids = []
    page_w, page_h = 595, 793
    for number in range(12):
        xobject = add(("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB "
                       "/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n" % (width, height, len(image)))
                      .encode("ascii") + image + b"\nendstream")
        stream = ("q %d 0 0 %d 0 0 cm /Im%d Do Q" % (page_w, page_h, number)).encode("ascii")
        contents = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        kids.append(add(("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
                         "/Resources << /XObject << /Im%d %d 0 R >> >> /Contents %d 0 R >>"
                         % (page_tree, page_w, page_h, number, xobject, contents)).encode("ascii")))
    objects[catalog - 1] = ("<< /Type /Catalog /Pages %d 0 R >>" % page_tree).encode("ascii")
    objects[page_tree - 1] = ("<< /Type /Pages /Kids [%s] /Count %d >>"
                              % (" ".join(f"{kid} 0 R" for kid in kids), len(kids))).encode("ascii")
    data = bytearray(b"%PDF-1.4\n%\xe5\xe4\xf6\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(data))
        data += b"%d 0 obj\n" % index + body + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        data += b"%010d 00000 n \n" % offset
    data += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref)
    path.write_bytes(bytes(data))


def make_photo_text_pair(folder):
    """Våg 10b (P3, P4): en PDF som liknar Edvins kamerafoton, med textlager, och txt-filen från OCR-flödet
    bredvid (samma namn, en rubrik "--- boksida N ---" per sida som i ocr_spalter.py i Reta 30).
    Varje sida är ett grått bord med en ljus boksida på (papperet 10 till 90 procent av bredden) och texten i
    mitten. Ordet kunskap står ensamt på en rad med tomt runt, så att självtestet kan se att sidbilden och
    rutorna stämmer på en beskuren sida. Sida 1 är titelsidan, sidorna 2 till 4 är boksidorna 12 till 14."""
    labels = ["titelsida", "boksida 12", "boksida 13", "boksida 14"]
    texts = [
        ["FOTOBOKEN", "", "En provbok för textläget och beskärningen."],
        ["Retoriken handlar om att övertyga. Den som talar väljer argument efter publiken,",
         "och ordningen mellan argumenten avgör ofta hur väl de tas emot av den som lyssnar.",
         "", "RETORIKENS GRUNDER", "",
         "Den klassiska läran delar arbetet i fem delar: inventio, dispositio, elocutio, memo-",
         "ria och actio. Varje del har sina egna begrepp och sina egna övningar."],
        ["Inventio är att finna argumenten. Topikerna är platser där argumenten kan sökas,",
         "till exempel orsak och verkan, likhet och skillnad eller helhet och delar.",
         "", "Ett bra argument är anpassat till situationen och till den som ska övertygas."],
        ["Dispositio är ordningen. Ett tal börjar med exordium och slutar med peroratio,",
         "och däremellan står berättelsen, beviset och vederläggningen.",
         "", "Den som har ordning i sitt tal blir lättare att följa och att minnas."],
    ]

    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    page_tree = add(None)
    regular = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    kids = [add(None) for _ in labels]
    for number, lines in enumerate(texts):
        content = [
            "0.35 0.33 0.31 rg 0 0 595 842 re f",  # bordet
            "0.96 0.95 0.92 rg 60 40 476 770 re f",  # boksidan, 10 till 90 procent av bredden
            "0 0 0 rg",
            "BT /F1 12 Tf 16 TL 110 700 Td",
        ]
        for line in lines:
            content.append(f"{pdf_string(line)} Tj T*")
        content.append("ET")
        # Ordet kunskap ensamt på en rad, med tomma rader runt.
        content.append(f"BT /F1 12 Tf 110 470 Td {pdf_string('Ord: kunskap')} Tj ET")
        content.append(f"BT /F1 12 Tf 110 300 Td {pdf_string('Sidan slutar här.')} Tj ET")
        stream = "\n".join(content).encode("latin-1")
        contents = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        objects[kids[number] - 1] = ("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] "
                                     "/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
                                     % (page_tree, regular, contents)).encode("ascii")
    objects[catalog - 1] = ("<< /Type /Catalog /Pages %d 0 R >>" % page_tree).encode("ascii")
    objects[page_tree - 1] = ("<< /Type /Pages /Kids [%s] /Count %d >>"
                              % (" ".join(f"{kid} 0 R" for kid in kids), len(kids))).encode("ascii")
    data = bytearray(b"%PDF-1.4\n%\xe5\xe4\xf6\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(data))
        data += b"%d 0 obj\n" % index + body + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        data += b"%010d 00000 n \n" % offset
    data += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref)
    (folder / "foto-text.pdf").write_bytes(bytes(data))

    # Txt-filen som OCR-flödet skriver: rubriken före varje sida, sidorna åtskilda av en tom rad.
    pages = []
    for label, lines in zip(labels, texts):
        pages.append(f"--- {label} ---\n" + "\n".join(lines) + "\n\nOrd: kunskap\n\nSidan slutar här.")
    (folder / "foto-text.txt").write_text("\n\n".join(pages), encoding="utf-8")


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else "build/testbooks")
    folder.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)
    make_epub(folder / "test.epub", rng)
    make_txt(folder / "test.txt", rng)
    make_md(folder / "test.md", rng)
    make_rtf(folder / "test.rtf", rng)
    make_pdf(folder / "test.pdf", rng)
    make_cover_epub(folder / "roman.epub")
    make_photo_text_pair(folder)
    if sys.platform == "darwin":
        make_photo_pdf(folder / "foto.pdf", random.Random(11))
    for item in sorted(folder.iterdir()):
        print(item.name, item.stat().st_size)


if __name__ == "__main__":
    main()
