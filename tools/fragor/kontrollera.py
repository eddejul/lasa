"""Kontrollerar en frågefil till Sensus (K6, formatet står i docs/FRAGOR.md).

Användning:
    python tools/fragor/kontrollera.py <Bok.pdf.fragor.json> [boken]

Utan bok kontrolleras bara formatet: att filen är JSON, att varje fråga har en fråga och ett citat eller
en sida, och att id:na är unika. Med boken (PDF, EPUB, txt eller md) letas varje citat upp i texten med
samma vikning som appen (små bokstäver, ett mellanslag mellan orden, avstavningar bort). PDF kräver
PyMuPDF (pip install pymupdf). Skriptet ändrar aldrig något.
"""

import html
import json
import re
import sys
import zipfile
from pathlib import Path


def fold(text):
    text = text.replace("­", "")
    # Avstavning över en radbrytning: "kun-\nskap" blir "kunskap", som FoldedText i appen.
    text = re.sub(r"[-‐‑][ \t]*[\r\n  ]+\s*(?=[a-zåäöéü])", "", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def chapters_of_epub(path):
    with zipfile.ZipFile(path) as archive:
        names = sorted(n for n in archive.namelist() if n.lower().endswith((".xhtml", ".html", ".htm")))
        for name in names:
            raw = archive.read(name).decode("utf-8", errors="replace")
            raw = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", "", raw)
            yield name, html.unescape(re.sub(r"(?s)<[^>]+>", "", raw))


def sections(book):
    suffix = book.suffix.lower()
    if suffix == ".pdf":
        try:
            import fitz  # PyMuPDF
        except ImportError:
            sys.exit("PyMuPDF saknas: pip install pymupdf (eller kontrollera utan bok)")
        with fitz.open(book) as document:
            for number, page in enumerate(document, start=1):
                yield f"sida {number}", page.get_text()
    elif suffix == ".epub":
        yield from chapters_of_epub(book)
    else:
        yield book.name, book.read_text(encoding="utf-8", errors="replace")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    if not path.name.lower().endswith(".fragor.json"):
        print(f"Obs: filen bör heta som boken plus .fragor.json, till exempel Bok.pdf.fragor.json")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        sys.exit(f"FEL: filen kan inte läsas som JSON: {error}")
    items = data if isinstance(data, list) else (data.get("fragor") or data.get("frågor") or data.get("questions"))
    if not isinstance(items, list):
        sys.exit("FEL: filen saknar listan fragor")
    problems = 0
    seen = set()
    usable = []
    for number, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            print(f"FEL: post {number} är inget objekt")
            problems += 1
            continue
        question = str(item.get("fraga") or item.get("fråga") or "").strip()
        quote = str(item.get("citat") or "").strip()
        page = item.get("sida")
        if not question:
            print(f"FEL: post {number} saknar fraga, den hoppas över i appen")
            problems += 1
            continue
        if not quote and page is None:
            print(f"FEL: post {number} saknar både citat och sida, den hoppas över i appen")
            problems += 1
            continue
        ident = str(item.get("id") or "").strip()
        if ident and ident in seen:
            print(f"FEL: id {ident} finns två gånger (post {number}), svaren blandas ihop")
            problems += 1
        seen.add(ident)
        if "y" in item and not (isinstance(item["y"], (int, float)) and 0 <= item["y"] <= 1):
            print(f"FEL: post {number} har y utanför 0 till 1")
            problems += 1
        if not item.get("svar"):
            print(f"Obs: post {number} har inget svar")
        usable.append((len(usable) + 1, question, quote, page))
    print(f"{len(usable)} frågor går att använda.")

    if len(sys.argv) > 2:
        book = Path(sys.argv[2])
        texts = [(name, fold(text)) for name, text in sections(book)]
        for number, question, quote, page in usable:
            if not quote:
                print(f"  {number}: inget citat, pricken står på sida {page}")
                continue
            wanted = fold(quote)
            places = [name for name, text in texts if wanted in text]
            if not places:
                print(f"FEL: {number}: citatet hittas inte i boken: {quote[:60]}")
                problems += 1
            else:
                more = f" (och {len(places) - 1} till, den närmast sidan eller kapitlet väljs)" if len(places) > 1 else ""
                print(f"  {number}: {places[0]}{more}")
    if problems:
        sys.exit(f"{problems} fel")
    print("Inga fel.")


if __name__ == "__main__":
    main()
