"""Provar sokbar_pdf.py på påhittade testsidor (testsidor.py), med riktig Tesseract.

  python tools/ocr/test_sokbar.py [--tesseract <exe>] [--tessdata <mapp med swe.traineddata>] [--mapp <arbetsmapp>]

Kontrollerar:
* att textlagret i den nya PDF:en (PyMuPDF get_text, i innehållsströmmens ordning) kommer i läsordning:
  vänster spalt, höger spalt, fotnoterna, med minst 85 procent av orden i rätt följd,
* att å, ä och ö kommer med, och att sidorna ser exakt likadana ut som förut (texten är osynlig),
* att textfilen skrivs, att en sida som redan har text stoppas utan --ersatt-text, att --ersatt-text byter
  den gamla texten, att avbrottsfilen stoppar körningen utan att lämna filer, och att en saknad
  språkmodell ger SAKNAS.
Arbetsmappen töms efteråt. Returkod 0 när allt gick bra.
"""
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import fitz
import numpy as np

HAR = os.path.dirname(os.path.abspath(__file__))
SKRIPT = os.path.join(HAR, "sokbar_pdf.py")
FEL = []


def kontroll(villkor, text):
    print(("ok   " if villkor else "FEL  ") + text, flush=True)
    if not villkor:
        FEL.append(text)


def norm(text):
    return [w for w in (re.sub(r"[^0-9a-zåäöéü]", "", t.lower()) for t in text.split()) if w]


def kor(*args, tid=900):
    r = subprocess.run([sys.executable, SKRIPT, *args], capture_output=True, timeout=tid)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def bild(sida):
    pix = sida.get_pixmap(matrix=fitz.Matrix(1, 1), colorspace=fitz.csGRAY, alpha=False)
    return np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.stride)[:, :pix.width].astype(int)


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    args = dict(zip(argv[::2], argv[1::2]))
    mapp = args.get("--mapp") or tempfile.mkdtemp(prefix="sokbar_test_")
    os.makedirs(mapp, exist_ok=True)
    extra = []
    for namn in ("--tesseract", "--tessdata"):
        if args.get(namn):
            extra += [namn, args[namn]]
    try:
        test = os.path.join(mapp, "test.pdf")
        subprocess.run([sys.executable, os.path.join(HAR, "testsidor.py"), test], check=True)
        facit = json.load(open(test + ".json", encoding="utf-8"))

        rk, ut, fel = kor("--kontroll", *extra)
        kontroll(rk == 0 and json.loads(ut.strip().splitlines()[-1])["ok"], f"--kontroll hittar allt ({ut.strip()[:160]})")
        if rk:
            return 1

        utfil = os.path.join(mapp, "ut.pdf")
        txt = os.path.join(mapp, "ut.txt")
        tmp = os.path.join(mapp, "tmp")
        rk, ut, fel = kor(test, utfil, "--tmp", tmp, "--txt", txt, *extra)
        print(ut.strip())
        kontroll(rk == 0 and "KLAR" in ut, f"körningen gick igenom (returkod {rk}) {fel.strip()[-300:]}")
        rader = ut.splitlines()
        kontroll(rader[0] == f"START {len(facit)}" and sum(r.startswith("SIDA ") for r in rader) == len(facit),
                 "START och en SIDA-rad per sida")
        kontroll(os.path.isdir(tmp) and not os.listdir(tmp), "inga tillfälliga filer kvar")
        org, ny = fitz.open(test), fitz.open(utfil)
        alla = ""
        for i, (sida, f) in enumerate(zip(ny, facit)):
            text = sida.get_text()
            alla += text
            fick, ville = norm(text), norm(" ".join(f["ord"]))
            andel = difflib.SequenceMatcher(None, ville, fick, autojunk=False).ratio()
            kontroll(andel >= 0.85, f"sida {i + 1} ({f['typ']}): {andel:.0%} av orden i läsordning")
            if f["typ"].startswith("tva"):
                # Sista ordet i vänsterspalten före första ordet i högerspalten, och fotnoterna sist.
                vt, hs, fn = norm("texten den sammanfattar"), norm("Högerspalten fortsätter"), norm("Fotnoterna står")
                plats = lambda ord_: next((k for k in range(len(fick)) if fick[k:k + len(ord_)] == ord_), -1)
                p1, p2, p3 = plats(vt), plats(hs), plats(fn)
                kontroll(0 <= p1 < p2 < p3, f"sida {i + 1}: vänster spalt ({p1}), höger spalt ({p2}), fotnoter ({p3})")
            skillnad = np.abs(bild(org[i]) - bild(sida)).max()
            kontroll(skillnad <= 2, f"sida {i + 1}: sidan ser likadan ut (största skillnad {skillnad})")
            kontroll(len(sida.get_images()) == len(org[i].get_images()), f"sida {i + 1}: samma bilder som förut")
        kontroll(all(c in alla for c in "åäö"), "å, ä och ö finns i textlagret")
        kontroll(open(txt, encoding="utf-8").read().startswith("--- sida 1 ---"), "textfilen skrevs")

        # En sida som redan har text (som en helsidesläsning i fel ordning).
        gammal = os.path.join(mapp, "gammal.pdf")
        d = fitz.open(test)
        for sida in d:
            sida.insert_text((60, 120), "GAMMALTEXT i fel ordning", fontsize=11, render_mode=3)
        d.save(gammal)
        d.close()
        rk, ut, _ = kor(gammal, os.path.join(mapp, "ut2.pdf"), *extra)
        kontroll(rk == 5 and ut.strip() == f"HAR_TEXT {len(facit)} {len(facit)}",
                 f"sidor med text stoppas utan --ersatt-text ({ut.strip()[-80:]})")
        rk, ut, _ = kor(gammal, os.path.join(mapp, "ut3.pdf"), "--ersatt-text", "--sidor", "1", *extra)
        if rk == 0:
            d = fitz.open(os.path.join(mapp, "ut3.pdf"))
            t = d[0].get_text()
            andel = difflib.SequenceMatcher(None, norm(" ".join(facit[0]["ord"])), norm(t), autojunk=False).ratio()
            kontroll("GAMMALTEXT" not in t and andel >= 0.85, f"--ersatt-text byter texten ({andel:.0%} i ordning)")
            kontroll(np.abs(bild(org[0]) - bild(d[0])).max() <= 2, "--ersatt-text behåller sidans bild")
            kontroll("GAMMALTEXT" in d[1].get_text(), "--sidor 1 rör inte sida 2")
            d.close()
        else:
            kontroll(False, f"--ersatt-text gick inte ({ut.strip()[-200:]})")

        # Avbrott: filen finns redan när körningen startar.
        avbryt = os.path.join(mapp, "avbryt")
        open(avbryt, "w").close()
        tmp2 = os.path.join(mapp, "tmp2")
        rk, ut, _ = kor(test, os.path.join(mapp, "ut4.pdf"), "--avbryt-fil", avbryt, "--tmp", tmp2, *extra)
        kontroll(rk == 4 and "AVBRUTEN" in ut and not os.path.exists(os.path.join(mapp, "ut4.pdf"))
                 and not os.listdir(tmp2), "avbrottsfilen stoppar körningen och inga filer blir kvar")

        # Textlagret på roterade och beskurna sidor: orden ska hamna där sidbilden visar dem.
        sys.path.insert(0, HAR)
        import sokbar_pdf
        sokbar_pdf.importera()
        rader = [[("Första", 60, 90, 130, 104), ("raden", 140, 92, 190, 104)],
                 [("Åsikter", 60, 120, 128, 134), ("här", 138, 120, 170, 134)]]
        for vinkel in (0, 90, 180, 270):
            d = fitz.open()
            sida = d.new_page(width=420, height=595)
            sida.set_cropbox(fitz.Rect(10, 20, 410, 580))
            sida.set_rotation(vinkel)
            sokbar_pdf.lagg_text(d, sida, [rader], 1.0)
            d.write()
            # get_text ger koordinater på sidan utan rotation, rotation_matrix för dem till sidbildens.
            orden = sida.get_text("words")
            fel_ = []
            for (text, x0, y0, x1, y1), w in zip([o for r in rader for o in r], orden):
                mitt = ((x0 + x1) / 2, (y0 + y1) / 2)
                ruta = fitz.Rect(w[:4]) * sida.rotation_matrix
                fick = ((ruta.x0 + ruta.x1) / 2, (ruta.y0 + ruta.y1) / 2)
                if w[4] != text or abs(mitt[0] - fick[0]) > 4 or abs(mitt[1] - fick[1]) > 4:
                    fel_.append((text, w[4], [round(v) for v in mitt], [round(v) for v in fick]))
            kontroll(len(orden) == 4 and not fel_, f"rotation {vinkel}: orden på sina platser {fel_ or ''}")
            d.close()

        tom = os.path.join(mapp, "tom-tessdata")
        os.makedirs(tom, exist_ok=True)
        rk, ut, _ = kor(test, os.path.join(mapp, "ut5.pdf"), "--tessdata", tom,
                        *(extra[:2] if extra[:1] == ["--tesseract"] else []))
        kontroll(rk == 3 and ut.startswith("SAKNAS sprak swe"), f"saknad språkmodell ger SAKNAS ({ut.strip()})")
        org.close()
        ny.close()
    finally:
        if not args.get("--behall"):
            shutil.rmtree(mapp, ignore_errors=True)
    print("ALLT OK" if not FEL else f"{len(FEL)} FEL")
    return 1 if FEL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
