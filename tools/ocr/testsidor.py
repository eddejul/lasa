"""Gör påhittade testsidor för sokbar_pdf.py: en skannad PDF utan textlager, med egen text (inga boksidor).

  python tools/ocr/testsidor.py <ut.pdf> [--sidor tva,en,tva-sned]

Sidtyperna:
* tva: två spalter och ett fotnotsblock över hela bredden, raderna böjer sig nedåt mot vänsterkanten (som
  nära bokryggen på ett kamerafoto av en högersida) och hela sidan lutar en grad.
* en: en spalt.
* tva-sned: som tva men lutar en och en halv grad åt andra hållet och har en mörk remsa av "motstående sida" i
  vänsterkanten.
Den förväntade läsordningen skrivs till <ut.pdf>.json (en lista med sidornas ord i ordning).
"""
import json
import os
import sys

import fitz
import numpy as np
from PIL import Image, ImageDraw, ImageFont

STYCKEN_V = [
    "Den som läser en kursbok på kvällen vill förstå texten och inte bara känna igen orden. Därför "
    "stannar läsaren vid ett svårt ord och slår upp det, skriver en kort anteckning i marginalen och "
    "läser sedan vidare med ny förståelse.",
    "Retoriken lär oss att ett argument måste passa åhöraren. Ett exempel från vardagen väger ofta "
    "tyngre än en lång definition, och en väl vald bild stannar kvar längre än en tabell över årtal.",
    "När spalterna står tätt intill varandra måste läsordningen vara rätt, annars blir meningen som "
    "sparas med ordet obegriplig och sökningen hittar inte frasen som löper över en radbrytning.",
]
STYCKEN_V += [
    "Ett tredje stycke i vänsterspalten ger sidan mer text. Kursboken har långa kapitel, och varje sida "
    "är full av ord som ska kunna slås upp, sparas och repeteras senare i veckan.",
    "Läraren påminner om att källorna ska anges, att citat ska vara exakta och att en sammanfattning "
    "aldrig får bli längre än texten den sammanfattar. Det låter enkelt men kräver övning.",
]
STYCKEN_H = [
    "Högerspalten fortsätter resonemanget. Här står det att övning gör färdighet, och att den som "
    "återvänder till samma text efter en vecka minns mer än den som läste tre gånger i följd.",
    "Sökbara sidor gör det möjligt att markera en mening som går över två rader. Markeringen följer "
    "då texten i den ordning den skrevs, från vänster spalt till höger spalt och sist fotnoterna.",
    "Ett välskrivet stycke har en tydlig början, en mitt som för tanken framåt och ett slut som "
    "knyter ihop säcken. Så är det också med en god föreläsning eller ett tal på bröllopet.",
]
STYCKEN_H += [
    "Den sista delen av högerspalten avslutar sidan. Här samlas trådarna, och läsaren får en fråga att "
    "fundera på till nästa seminarium: vad gör ett argument övertygande för just den här publiken?",
    "Svaret är sällan ett enda skäl. Ofta är det samspelet mellan talarens karaktär, känslan i rummet "
    "och själva sakskälen som avgör, precis som de gamla handböckerna beskrev det.",
]
STYCKEN_V += [
    "Mot slutet av spalten kommer en längre utvikning om minnet. Den som repeterar med glesare och glesare "
    "mellanrum behåller orden längre, och därför sparar läsappen varje uppslaget ord med meningen det stod i.",
]
STYCKEN_H += [
    "Till sist en påminnelse om att vila. Hjärnan sorterar det man läst medan man sover, så en kväll med "
    "lagom mycket text och en god natts sömn slår ofta en hel natt med kaffe och överstrykningspenna.",
]
FOTNOTER = [
    "1 Fotnoterna står över hela sidans bredd, under ett kort streck, med mindre stil än brödtexten.",
    "2 Jämför med kapitel två, där samma tanke prövas på ett annat exempel ur dagspressen.",
]
EN_SPALT = [
    "En sida med bara en spalt läses uppifrån och ned. Raderna är längre, och det finns ingen ränna "
    "mellan två spalter som programmet kan hitta. Då läses hela sidan på en gång.",
    "Andra stycket på sidan handlar om något annat. Åsikter om väder, äventyr på fjället och ökända "
    "överraskningar ger ord med å, ä och ö som måste komma med rätt.",
]

BREDD, HOJD = 1700, 2400  # cirka 200 punkter per tum på en A4-sida


def typsnitt(storlek):
    for namn in ("C:/Windows/Fonts/times.ttf", "C:/Windows/Fonts/georgia.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf", "/Library/Fonts/Times New Roman.ttf"):
        if os.path.exists(namn):
            return ImageFont.truetype(namn, storlek)
    return ImageFont.load_default(size=storlek)


def bryt(text, font, bredd, rita):
    rader, rad = [], ""
    for ord_ in text.split():
        prov = (rad + " " + ord_).strip()
        if rita.textlength(prov, font=font) <= bredd:
            rad = prov
        else:
            rader.append(rad)
            rad = ord_
    if rad:
        rader.append(rad)
    return rader


def skriv(rita, stycken, font, x, y, bredd, radhojd):
    for stycke in stycken:
        for rad in bryt(stycke, font, bredd, rita):
            rita.text((x, y), rad, font=font, fill=0)
            y += radhojd
        y += radhojd // 2
    return y


def bojd(bild, mitt, djup):
    """Böjer raderna nedåt mot x = mitt (bokryggen), mest de närmaste 15 procenten av bredden."""
    a = np.asarray(bild).copy()
    h, w = a.shape
    ut = np.full_like(a, 255)
    for x in range(w):
        dy = int(round(djup * np.exp(-((x - mitt) / (0.16 * w)) ** 2)))
        if dy > 0:
            ut[dy:, x] = a[:-dy, x]
        else:
            ut[:, x] = a[:, x]
    return Image.fromarray(ut)


def tva_spalter(sned=False):
    bild = Image.new("L", (BREDD, HOJD), 255)
    rita = ImageDraw.Draw(bild)
    brod, liten = typsnitt(34), typsnitt(26)
    marg, ranna = 150, 70
    spalt = (BREDD - 2 * marg - ranna) // 2
    yv = skriv(rita, STYCKEN_V, brod, marg, 200, spalt, 46)
    yh = skriv(rita, STYCKEN_H, brod, marg + spalt + ranna, 200, spalt, 46)
    y = max(yv, yh) + 60
    rita.line((marg, y, marg + 300, y), fill=0, width=2)
    skriv(rita, FOTNOTER, liten, marg, y + 25, BREDD - 2 * marg, 34)
    rita.text((BREDD // 2 - 20, HOJD - 140), "17", font=brod, fill=0)
    bild = bojd(bild, 0, 30)
    if sned:
        rita = ImageDraw.Draw(bild)
        rita.rectangle((0, 0, 40, HOJD), fill=40)  # kanten av motstående sida
    bild = bild.rotate(-1.5 if sned else 1, resample=Image.BICUBIC, fillcolor=255)
    ord_ = " ".join(STYCKEN_V + STYCKEN_H + FOTNOTER).split()
    return bild, ord_


def en_spalt():
    bild = Image.new("L", (BREDD, HOJD), 255)
    rita = ImageDraw.Draw(bild)
    skriv(rita, EN_SPALT, typsnitt(36), 180, 260, BREDD - 360, 50)
    return bild.rotate(0.6, resample=Image.BICUBIC, fillcolor=255), " ".join(EN_SPALT).split()


def main(argv):
    ut = argv[0]
    typer = ["tva", "en", "tva-sned"]
    if "--sidor" in argv:
        typer = argv[argv.index("--sidor") + 1].split(",")
    doc = fitz.open()
    facit = []
    for typ in typer:
        bild, ord_ = {"tva": lambda: tva_spalter(), "en": en_spalt, "tva-sned": lambda: tva_spalter(True)}[typ]()
        sida = doc.new_page(width=595, height=842)
        import io
        buf = io.BytesIO()
        bild.save(buf, format="PNG", optimize=True)
        sida.insert_image(sida.rect, stream=buf.getvalue())
        facit.append({"typ": typ, "ord": ord_})
    doc.save(ut, garbage=3, deflate=True)
    with open(ut + ".json", "w", encoding="utf-8") as fil:
        json.dump(facit, fil, ensure_ascii=False, indent=1)
    print(f"{ut}: {len(typer)} sidor ({', '.join(typer)})")


if __name__ == "__main__":
    main(sys.argv[1:])
