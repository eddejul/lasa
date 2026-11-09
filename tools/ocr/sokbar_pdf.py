"""Gör en skannad PDF sökbar: osynlig text på originalsidorna, i spaltordning (P1).

  python tools/ocr/sokbar_pdf.py <in.pdf> <ut.pdf> [--tesseract <exe>] [--tessdata <mapp>] [--lang swe]
      [--spalter auto|1|2] [--sidor 1,3-5] [--arbetare 2] [--tmp <mapp>] [--txt <ut.txt>]
      [--ersatt-text] [--avbryt-fil <fil>] [--snabb]
  python tools/ocr/sokbar_pdf.py --kontroll [--tesseract <exe>] [--tessdata <mapp>] [--lang swe]

Sidorna ritas, läses med Tesseract, och orden läggs som osynlig text (render mode 3) ovanpå originalsidan med
PyMuPDF, ord för ord på ordets plats. Bilderna i PDF:en rörs inte. Textlagret kommer i läsordning: vänster spalt
uppifrån och ned, sedan höger spalt, sist fotnoterna över hela bredden. Helsidesläsningen (Tesseracts egen
PDF) blandar ihop spalterna där raderna böjer sig mot bokryggen, och då följer meningar, markeringar över
flera rader och sökning fel ordning.

Spaltuppdelningen bygger på Edvins flöde för Lindqvist (ocr_spalter.py och utrata.py, oktober 2026):
* mittrännan hittas som en sned linje (mitten av det vita bandet, omräknad ur band när fotnoterna tar
  halva sidan),
* fotnotsblocket hittas som raderna som korsar rännan, nerifrån,
* en remsa av motstående boksida vitmålas bara när den når spaltens kant, är smal och syns i minst tre
  band i rad,
* varje spalt läses både som den är och uträtad (varje textrad följs genom 24 lodräta remsor), och
  varianten med flest säkra ord behålls, om medelkonfidensen inte sjunker,
* spalten läses i band som skärs i vita radmellanrum (psm 6), så att inga rader dubbleras.
Uträtningens förskjutning räknas tillbaka, så att orden hamnar på sin plats på originalsidan.
En sida utan tydlig ränna läses som en spalt (psm 3).

Rader till standard ut (en per rad, för Sensus förloppsruta):
  START <antal sidor>
  SIDA <klara> <antal> <sidnummer> <tecken> <info>
  KLAR <ut.pdf>
  FEL <text>        (returkod 1), AVBRUTEN (returkod 4), SAKNAS <vad> (returkod 3)
  HAR_TEXT <sidor med text> <sidor>   (returkod 5: sidorna har redan text, kör med --ersatt-text)
--kontroll skriver en rad JSON: {"ok": ..., "saknas": [...], "python": ..., "tesseract": ..., ...}.

Tesseract startas med --tessdata-dir FÖRE allt annat och med -c tessedit_create_tsv=1 i stället för
konfigurationsfilen tsv, så att en egen tessdata-mapp bara behöver <språk>.traineddata.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

VERSION = "1"
SKRAP = re.compile(r"[A-Za-zÅÄÖåäöÉéÜüÆæØø]{3,}")
STANDARD_TESSERACT = r"C:\Program Files\Tesseract-OCR\tesseract.exe"
INGET_FONSTER = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # inga konsolfönster när Sensus startar skriptet
BREDD = 2400  # sidan ritas så att den blir minst så här bred i pixlar, som i Edvins flöde


def rad(*delar):
    print(" ".join(str(d) for d in delar), flush=True)


class Avbruten(Exception):
    pass


class Saknas(Exception):
    pass


class HarText(Exception):
    pass


# ---------------------------------------------------------------- beroenden


def importera():
    """numpy, PyMuPDF och Pillow. Kastar Saknas med paketets namn för pip."""
    global np, fitz, Image
    namn = {"numpy": "numpy", "fitz": "PyMuPDF", "pymupdf": "PyMuPDF", "PIL": "Pillow"}
    try:
        import numpy as np  # noqa: F401
        import fitz  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError as fel:
        paket = namn.get((fel.name or "").split(".")[0], fel.name or str(fel))
        raise Saknas(f"python-paket {paket}") from fel


def hitta_tesseract(angiven):
    if angiven:
        return angiven if os.path.isfile(angiven) else shutil.which(angiven)
    if os.path.isfile(STANDARD_TESSERACT):
        return STANDARD_TESSERACT
    return shutil.which("tesseract")


def hitta_tessdata(tesseract, angiven):
    if angiven:
        return angiven
    if os.environ.get("TESSDATA_PREFIX"):
        return os.environ["TESSDATA_PREFIX"]
    return os.path.join(os.path.dirname(tesseract), "tessdata") if tesseract else None


def kontroll(args):
    ut = {"ok": False, "saknas": [], "version": VERSION, "python": sys.version.split()[0]}
    try:
        importera()
        ut["pymupdf"] = fitz.VersionBind
    except Saknas as fel:
        ut["saknas"].append(str(fel))
    tesseract = hitta_tesseract(args.get("tesseract"))
    if not tesseract:
        ut["saknas"].append("tesseract")
    else:
        ut["tesseract_fil"] = tesseract
        try:
            r = subprocess.run([tesseract, "--version"], capture_output=True, timeout=20, creationflags=INGET_FONSTER)
            text = (r.stdout + r.stderr).decode("utf-8", "replace")
            m = re.search(r"tesseract v?(\d[\w.]*)", text)
            ut["tesseract"] = m.group(1) if m else text.strip().splitlines()[0][:40]
        except (OSError, subprocess.SubprocessError) as fel:
            ut["saknas"].append("tesseract")
            ut["fel"] = str(fel)
        tessdata = hitta_tessdata(tesseract, args.get("tessdata"))
        ut["tessdata"] = tessdata
        sprak = args.get("lang", "swe")
        if not tessdata or not os.path.isfile(os.path.join(tessdata, sprak + ".traineddata")):
            ut["saknas"].append(f"sprak {sprak}")
        if tessdata and os.path.isdir(tessdata):
            ut["sprak"] = sorted(f[:-12] for f in os.listdir(tessdata) if f.endswith(".traineddata"))
    ut["ok"] = not ut["saknas"]
    print(json.dumps(ut, ensure_ascii=False), flush=True)
    return 0 if ut["ok"] else 3


# ---------------------------------------------------------------- Tesseract


class Lasare:
    """Kör Tesseract och läser TSV-utdata. Kollar avbrottsfilen före varje körning."""

    def __init__(self, tesseract, tessdata, sprak, avbryt):
        self.tesseract, self.tessdata, self.sprak, self.avbryt = tesseract, tessdata, sprak, avbryt
        self.env = dict(os.environ, OMP_THREAD_LIMIT="1")  # en tråd per Tesseract, parallellismen sköts här
        self.stopp = threading.Event()

    def kolla(self):
        if self.stopp.is_set() or (self.avbryt and os.path.exists(self.avbryt)):
            raise Avbruten()

    def ord(self, bild, mapp, namn, psm):
        """Orden i en gråskalebild: [(block, rad, text, konf, x0, y0, x1, y1)] i Tesseracts ordning."""
        self.kolla()
        png = os.path.join(mapp, namn + ".png")
        Image.fromarray(bild).save(png)
        bas = os.path.join(mapp, namn)
        # --tessdata-dir först (global regel 118), tsv med -c så att inga konfigurationsfiler behövs.
        r = subprocess.run([self.tesseract, png, bas, "--tessdata-dir", self.tessdata, "-l", self.sprak,
                            "--psm", psm, "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=0"],
                           capture_output=True, env=self.env, creationflags=INGET_FONSTER)
        try:
            os.remove(png)
        except OSError:
            pass
        if r.returncode:
            raise RuntimeError("Tesseract: " + r.stderr.decode("utf-8", "replace").strip()[-300:])
        ut = []
        with open(bas + ".tsv", encoding="utf-8") as fil:
            rubrik = fil.readline().rstrip("\n").split("\t")
            kol = {k: i for i, k in enumerate(rubrik)}
            for rad_ in fil:
                f = rad_.rstrip("\n").split("\t")
                if len(f) < len(rubrik) or f[kol["level"]] != "5":
                    continue
                text = f[kol["text"]].strip()
                if not text:
                    continue
                x, y = int(f[kol["left"]]), int(f[kol["top"]])
                w, h = int(f[kol["width"]]), int(f[kol["height"]])
                ut.append(((f[kol["block_num"]], f[kol["par_num"]]), (f[kol["block_num"]], f[kol["par_num"]], f[kol["line_num"]]),
                           text, float(f[kol["conf"]]), x, y, x + w, y + h))
        os.remove(bas + ".tsv")
        return ut


def konfidens(orden):
    k = [o[3] for o in orden if o[3] >= 0]
    return (sum(k) / len(k) if k else 0.0), len(k), sum(c for c in k if c >= 50)


# ---------------------------------------------------------------- spalterna (ur ocr_spalter.py)


def ranna(m, y0, y1, detaljer=False):
    """Mitten av det vita bandet mellan spalterna. Med detaljer även (i_kanten, kvot), där kvot är
    minimum delat med median (nära 0 är en tydlig ränna)."""
    w = m.shape[1]
    x0 = int(w * 0.35)
    prof = m[y0:y1, x0:int(w * 0.65)].sum(axis=0).astype(float)
    k = max(3, w // 150)
    prof = np.convolve(prof, np.ones(k) / k, mode="same")
    i = int(np.argmin(prof))
    med = float(np.median(prof))
    tol = prof[i] + 0.1 * (med - prof[i])
    a = i
    while a > 0 and prof[a - 1] <= tol:
        a -= 1
    b = i
    while b < len(prof) - 1 and prof[b + 1] <= tol:
        b += 1
    if not detaljer:
        return x0 + (a + b) // 2
    return x0 + (a + b) // 2, (a <= k or b >= len(prof) - 1 - k), (prof[i] / med if med > 0 else 9.0)


def ranna_ur_band(m, nband=6):
    """Rännan som funktion av y ur de band som har en tydlig ränna, eller None, och antalet sådana band."""
    h = m.shape[0]
    pkt = []
    for j in range(nband):
        y0, y1 = int(h * (0.08 + 0.84 * j / nband)), int(h * (0.08 + 0.84 * (j + 1) / nband))
        x, kant, kvot = ranna(m, y0, y1, True)
        if not kant and kvot < 0.1:
            pkt.append(((y0 + y1) / 2, x))
    if not pkt:
        return None, 0
    if len(pkt) < 3 or pkt[-1][0] - pkt[0][0] < 0.28 * h:
        xm = float(np.median([x for _, x in pkt]))
        return (lambda y: xm), len(pkt)
    bast = []
    for i in range(len(pkt)):
        for j in range(i + 1, len(pkt)):
            (ya, xa), (yb, xb) = pkt[i], pkt[j]
            lut = (xb - xa) / (yb - ya)
            inom = [(y, x) for y, x in pkt if abs(xa + lut * (y - ya) - x) <= 40]
            if len(inom) > len(bast):
                bast = inom
    ys, xs = np.array(bast, dtype=float).T
    lut, c0 = np.polyfit(ys, xs, 1) if np.ptp(ys) > 0 else (0.0, float(xs.mean()))
    return (lambda y: c0 + lut * y), len(pkt)


def har_tva_spalter(m, nband=6):
    """Två spalter när minst två band, och minst hälften av banden med text på båda sidor om mitten, har en
    tydlig vit ränna. Sidor med lite text (ett kapitelslut) har bara några band med text."""
    h, w = m.shape
    med_text, tydliga = 0, 0
    for j in range(nband):
        y0, y1 = int(h * (0.08 + 0.84 * j / nband)), int(h * (0.08 + 0.84 * (j + 1) / nband))
        vanster = m[y0:y1, int(w * 0.08):w // 2].sum()
        hoger = m[y0:y1, w // 2:int(w * 0.92)].sum()
        if min(vanster, hoger) < 0.15 * max(1, vanster + hoger):
            continue
        med_text += 1
        _, kant, kvot = ranna(m, y0, y1, True)
        if not kant and kvot < 0.1:
            tydliga += 1
    return tydliga >= 2 and tydliga * 2 >= med_text


def _korningar(aktiv, lucka):
    runs, start, tom, slut = [], None, 0, 0
    for x in range(len(aktiv)):
        if aktiv[x]:
            if start is None:
                start = x
            tom, slut = 0, x
        elif start is not None:
            tom += 1
            if tom > lucka:
                runs.append((start, slut))
                start = None
    if start is not None:
        runs.append((start, slut))
    return runs


def beskar_block(a, minlucka=0.025):
    """Behåller det största textblocket i sidled. Ger (bild, förskjutning i x)."""
    m = a < 140
    h, w = m.shape
    prof = np.convolve(m.sum(axis=0).astype(float), np.ones(9) / 9, mode="same")
    runs = _korningar(prof > max(3.0, 0.004 * h), minlucka * w)
    if len(runs) < 2:
        return a, 0
    x0, x1 = max(runs, key=lambda r: prof[r[0]:r[1] + 1].sum())
    x0 = max(0, x0 - 8)
    return np.ascontiguousarray(a[:, x0:min(w, x1 + 9)]), x0


def maskera_block(a, nband=12, minlucka=0.02, minband=3):
    """Vitmålar en remsa av motstående sida, band för band (se ocr_spalter.py)."""
    a = a.copy()
    m = a < 140
    h, w = m.shape
    kol = m.sum(axis=0).astype(float)
    if kol.sum() == 0:
        return a
    cx = int(np.searchsorted(np.cumsum(kol), kol.sum() / 2))
    kand = {"v": {}, "h": {}}
    for k in range(nband):
        y0, y1 = h * k // nband, h * (k + 1) // nband
        prof = np.convolve(m[y0:y1].sum(axis=0).astype(float), np.ones(7) / 7, mode="same")
        runs = _korningar(prof > max(1.0, 0.01 * (y1 - y0)), minlucka * w)
        if len(runs) < 2:
            continue
        keep = min(runs, key=lambda r: (0 if r[0] <= cx <= r[1] else min(abs(cx - r[0]), abs(cx - r[1])),
                                        -prof[r[0]:r[1] + 1].sum()))
        lucka = 0.04 * w
        i = 0
        while i + 1 < len(runs) and runs[i + 1][0] - runs[i][1] < lucka:
            i += 1
        if i + 1 < len(runs) and keep not in runs[:i + 1] and runs[0][0] <= 0.03 * w \
                and runs[i][1] - runs[0][0] <= 0.45 * w:
            kand["v"][k] = runs[i][1] + 7
        j = len(runs) - 1
        while j > 0 and runs[j][0] - runs[j - 1][1] < lucka:
            j -= 1
        if j > 0 and keep not in runs[j:] and runs[-1][1] >= 0.97 * w \
                and runs[-1][1] - runs[j][0] <= 0.45 * w:
            kand["h"][k] = runs[j][0] - 6
    for sida, band in kand.items():
        grupper, g = [], []
        for k in sorted(band):
            if g and k != g[-1] + 1:
                grupper.append(g)
                g = []
            g.append(k)
        if g:
            grupper.append(g)
        for g in grupper:
            if len(g) < minband:
                continue
            for k in g:
                y0, y1 = h * k // nband, h * (k + 1) // nband
                if sida == "v":
                    a[y0:y1, :max(0, band[k])] = 255
                else:
                    a[y0:y1, max(0, band[k]):] = 255
    return a


def fotnotsgrans(m, grans_x, botten=0.08, vidga=12, ovre=0.25, m_rannan=None):
    """Översta raden i fotnotsblocket (rader som korsar rännan, sökt nerifrån), eller None."""
    h, w = m.shape
    mr = m if m_rannan is None else m_rannan
    i_rannan = np.array([mr[y, max(0, grans_x[y] - 12):grans_x[y] + 13].any() for y in range(h)])
    minkorning = max(6, int(h * 0.002))
    y = 0
    while y < h:
        if i_rannan[y]:
            y1 = y
            while y1 < h and i_rannan[y1]:
                y1 += 1
            if y1 - y < minkorning:
                i_rannan[y:y1] = False
            y = y1
        else:
            y += 1
    F = np.convolve(i_rannan.astype(float), np.ones(2 * vidga + 1), mode="same") > 0
    rad_ = m[:, int(w * 0.12):int(w * 0.88)].any(axis=1)
    yf, y, spaltrader, tak = None, h - 1, 0, 0.055 * h
    while y > h * ovre:
        if rad_[y]:
            if F[y]:
                yf, spaltrader = y, 0
            elif y < h * (1 - botten):
                spaltrader += 1
                if spaltrader > tak:
                    break
        y -= 1
    if yf is None or yf < h * ovre:
        return None
    yb = int(h * (1 - botten))
    if yb - yf > 60:
        blockrader = rad_[yf:yb]
        if blockrader.sum() and (i_rannan[yf:yb] & blockrader).sum() / blockrader.sum() < 0.15:
            return None
    return yf


def spalter(im):
    """Blocken i läsordning: [(bild, x0, y0)] för vänster spalt, höger spalt och fotnoterna."""
    m = im < 140
    h, w = m.shape
    (xo, ko, qo), (xn, kn, qn) = ranna(m, int(h * 0.08), int(h * 0.5), True), ranna(m, int(h * 0.5), int(h * 0.92), True)
    info = ""
    # Utöver Edvins regel (bandet når sökfönstrets kant) räknas en halva utan tydlig ränna (kvot 0,1 eller mer)
    # också om ur banden: på en sida där spalterna slutar högt upp ger nedre halvan annars en ränna som är fel.
    ko, kn = ko or qo >= 0.1, kn or qn >= 0.1
    if ko or kn:
        linje, _ = ranna_ur_band(m)
        nya = None
        if linje:
            nya = (int(round(linje(h * 0.29))) if ko else xo, int(round(linje(h * 0.71))) if kn else xn)
            if not all(w * 0.35 < x < w * 0.65 for x in nya):
                nya = None
        if nya is None and ko != kn:
            nya = (xn, xn) if ko else (xo, xo)
        if nya:
            info = " omräknad ur band"
            xo, xn = nya
    ys = np.arange(h)[:, None]
    xs = np.arange(w)[None, :]
    grans = xo + (xn - xo) * (ys - h * 0.29) / (h * 0.42)
    yf = fotnotsgrans(m, grans[:, 0].astype(int), m_rannan=im < 170)
    yt = (yf - 4) if yf else h
    ut = []
    for sida in ("v", "h"):
        a = im[:yt].copy()
        g = grans[:yt]
        if sida == "v":
            a[np.broadcast_to(xs > g + 4, a.shape)] = 255
            x0, x1 = 0, int(max(xo, xn)) + 10
        else:
            a[np.broadcast_to(xs < g - 4, a.shape)] = 255
            x0, x1 = int(min(xo, xn)) - 10, w
        x0, x1 = max(0, x0), min(w, x1)
        b, bx = beskar_block(np.ascontiguousarray(a[:, x0:x1]))
        ut.append(("v" if sida == "v" else "h", maskera_block(b), x0 + bx, 0))
    if yf:
        ut.append(("fot", np.ascontiguousarray(im[yt:]), 0, yt))
    return ut, f"två spalter, ränna {xo}/{xn}{info}" + (f", fotnoter från {yf}" if yf else "")


# ---------------------------------------------------------------- uträtning (ur utrata.py)


def _jamna(v, k):
    k = max(1, int(k))
    return np.convolve(v, np.ones(k) / k, mode="same")


def _radavstand(prof):
    p = prof - prof.mean()
    ac = np.correlate(p, p, mode="full")[len(p) - 1:]
    lo, hi = 40, min(200, len(ac) - 1)
    return lo + int(np.argmax(ac[lo:hi]))


def _toppar(prof, mindist, troskel):
    t = []
    for y in range(1, len(prof) - 1):
        if prof[y] >= troskel and prof[y] >= prof[y - 1] and prof[y] > prof[y + 1]:
            if t and y - t[-1] < mindist:
                if prof[y] > prof[t[-1]]:
                    t[-1] = y
            else:
                t.append(y)
    return t


def utrata(a, remsor=24):
    """Rätar ut böjda rader. Ger (ny bild, största förskjutning, fält) där fält(y, x) är raden i
    originalet som pixeln (y, x) i den nya bilden kommer från, eller None när inget ändrades."""
    H, W = a.shape
    if H < 250 or W < 200:
        return a, 0.0, None
    m = (a < 140).astype(np.float32)
    P = _radavstand(_jamna(m.sum(axis=1), 9))
    sw = W / remsor
    profs, xs = [], []
    for j in range(remsor):
        x0, x1 = int(j * sw), int((j + 1) * sw)
        profs.append(_jamna(m[:, x0:x1].sum(axis=1), P / 4))
        xs.append((x0 + x1) / 2)
    xs = np.array(xs)
    blacks = np.array([p.sum() for p in profs])
    mitt = remsor // 2
    ref = max(range(max(0, mitt - 3), min(remsor, mitt + 4)), key=lambda j: blacks[j])
    pr = profs[ref]
    yref = _toppar(pr, 0.6 * P, 0.25 * pr.max())
    if len(yref) < 5:
        return a, 0.0, None
    L = len(yref)
    Y = np.full((L, remsor), np.nan)
    Y[:, ref] = yref
    for riktning in (1, -1):
        for i in range(L):
            prev, prev2 = float(yref[i]), None
            j = ref + riktning
            while 0 <= j < remsor:
                pred = prev if prev2 is None else prev + (prev - prev2)
                p = profs[j]
                a0, a1 = int(max(0, pred - 0.4 * P)), int(min(H, pred + 0.4 * P + 1))
                if a1 - a0 > 3 and p[a0:a1].max() > 0.25 * pr.max():
                    y = a0 + int(np.argmax(p[a0:a1]))
                    Y[i, j] = y
                    prev2, prev = prev, float(y)
                else:
                    prev2, prev = prev, pred
                j += riktning
    DY = Y - Y[:, [ref]]
    for i in range(L):
        ok = ~np.isnan(DY[i])
        DY[i] = np.interp(np.arange(remsor), np.flatnonzero(ok), DY[i, ok]) if ok.sum() >= 2 else 0
        DY[i] = np.convolve(np.pad(DY[i], 1, mode="edge"), np.ones(3) / 3, mode="valid")
    for i in range(L):
        lo, hi = max(0, i - 2), min(L, i + 3)
        med = np.median(DY[lo:hi], axis=0)
        if np.abs(DY[i] - med).max() > 0.3 * P:
            DY[i] = med
    yr = np.array(yref, dtype=float)
    ycoords = np.arange(H, dtype=float)
    Dstrip = np.stack([np.interp(ycoords, yr, DY[:, j]) for j in range(remsor)], axis=1)
    xcoords = np.arange(W, dtype=float)
    ut = np.empty_like(a)
    for y0 in range(0, H, 256):
        y1 = min(H, y0 + 256)
        D = np.stack([np.interp(xcoords, xs, Dstrip[y]) for y in range(y0, y1)])
        Ysrc = ycoords[y0:y1, None] + D
        Yi = np.clip(np.floor(Ysrc).astype(int), 0, H - 2)
        f = np.clip(Ysrc - Yi, 0, 1)
        cols = np.arange(W)[None, :]
        v = a[Yi, cols] * (1 - f) + a[Yi + 1, cols] * f
        v[(Ysrc < 0) | (Ysrc > H - 1)] = 255
        ut[y0:y1] = v.astype(np.uint8)

    def falt(y, x):
        yi = int(min(H - 1, max(0, round(y))))
        return y + float(np.interp(x, xs, Dstrip[yi]))

    return ut, float(np.nanmax(np.abs(DY))), falt


# ---------------------------------------------------------------- läsning


def snitt_i_mellanrum(m, y_onskat, sok=80):
    a, b = max(0, y_onskat - sok), min(m.shape[0], y_onskat + sok)
    return a + int(np.argmin(m[a:b].sum(axis=1)))


def las_spalt(lasare, a, mapp, namn, band):
    """Spalten i band som skärs i vita radmellanrum (psm 6). Orden med y i spaltens koordinater."""
    m = a < 140
    h = a.shape[0]
    g = [0] + [snitt_i_mellanrum(m, int(h * k / band)) for k in range(1, band)] + [h]
    orden = []
    for k in range(band):
        if g[k + 1] - g[k] < 12:
            continue
        for blk, rd, text, konf, x0, y0, x1, y1 in lasare.ord(a[g[k]:g[k + 1]], mapp, f"{namn}{k}", "6"):
            orden.append(((k,) + blk, (k,) + rd, text, konf, x0, y0 + g[k], x1, y1 + g[k]))
    return orden


def las_block(lasare, a, mapp, namn, band, snabb):
    """Läser ett block rakt och uträtat, behåller varianten med flest säkra ord om konfidensen håller."""
    o0 = las_spalt(lasare, a, mapp, namn + "r", band)
    k0, _, p0 = konfidens(o0)
    if snabb:
        return o0, f"{namn} rak {k0:.0f}"
    b, dy, falt = utrata(a)
    if falt is None:
        return o0, f"{namn} rak {k0:.0f}"
    o1 = las_spalt(lasare, b, mapp, namn + "u", band)
    k1, _, p1 = konfidens(o1)
    if p1 > p0 and k1 >= k0 - 1:
        # Tillbaka till originalets rader: ordets över- och nederkant i ordets mitt.
        flyttade = []
        for blk, rd, text, konf, x0, y0, x1, y1 in o1:
            xc = (x0 + x1) / 2
            flyttade.append((blk, rd, text, konf, x0, falt(y0, xc), x1, falt(y1, xc)))
        return flyttade, f"{namn} uträtad {k0:.0f}->{k1:.0f}"
    return o0, f"{namn} rak {k0:.0f} (uträtad {k1:.0f})"


def till_rader(orden, dx, dy):
    """Ord i läsordning till rader och stycken: [[[(text, x0, y0, x1, y1)]]], med sidans pixelkoordinater.
    Rader utan ett enda ord på minst tre bokstäver (sidkant, tumme, streck) tas bort, som i Edvins flöde."""
    stycken, stycke, rad_, nyckel_r, nyckel_s = [], [], [], None, None
    for blk, rd, text, konf, x0, y0, x1, y1 in orden:
        if rd != nyckel_r:
            if rad_:
                stycke.append(rad_)
            rad_, nyckel_r = [], rd
            if blk != nyckel_s:
                if stycke:
                    stycken.append(stycke)
                stycke, nyckel_s = [], blk
        rad_.append((text, x0 + dx, y0 + dy, x1 + dx, y1 + dy))
    if rad_:
        stycke.append(rad_)
    if stycke:
        stycken.append(stycke)
    ut = []
    for s in stycken:
        s = [r for r in s if SKRAP.search(" ".join(o[0] for o in r))]
        if s:
            ut.append(s)
    return ut


def las_sida(lasare, im, mapp, spaltval, snabb):
    """Sidans stycken i läsordning och en rad info."""
    m = im < 140
    tva = spaltval == "2" or (spaltval == "auto" and har_tva_spalter(m))
    if not tva:
        orden = lasare.ord(im, mapp, "hel", "3")
        k, n, _ = konfidens(orden)
        return till_rader(orden, 0, 0), f"en spalt, konf {k:.0f}"
    block, info = spalter(im)
    stycken, delar = [], [info]
    for namn, a, dx, dy in block:
        if a.shape[0] < 20 or a.shape[1] < 20:
            continue
        orden, i = las_block(lasare, a, mapp, namn, 1 if namn == "fot" else 4, snabb)
        if namn == "fot":
            # Notblocket både i full bredd och beskuret (tummen nedtill, motstående sida), som hos Edvin.
            bk, bx = beskar_block(a)
            if bk.shape != a.shape:
                o2, i2 = las_block(lasare, bk, mapp, "fotb", 1, snabb)
                k, n, _ = konfidens(orden)
                k2, n2, _ = konfidens(o2)
                if k2 > k + 1 and n2 >= 0.8 * n:
                    orden, i, dx = o2, i2 + " beskuret", dx + bx
        stycken += till_rader(orden, dx, dy)
        delar.append(i)
    return stycken, ", ".join(delar)


# ---------------------------------------------------------------- textlagret


def ta_bort_text(sida):
    """Tar bort befintlig text på sidan (till exempel en helsidesläsning) men behåller bilder och linjer."""
    sida.add_redact_annot(sida.rect)
    sida.apply_redactions(images=fitz.PDF_REDACT_IMAGE_NONE, graphics=fitz.PDF_REDACT_LINE_ART_NONE,
                          text=fitz.PDF_REDACT_TEXT_REMOVE)


_HELV = []


def helvetica():
    if not _HELV:
        _HELV.append(fitz.Font("helv"))
    return _HELV[0]


def _median(varden):
    v = sorted(varden)
    return v[len(v) // 2]


def _tal(v):
    return f"{v:.3f}".rstrip("0").rstrip(".") or "0"


def till_pdf(sida):
    """Matrisen från sidans bildkoordinater (som get_pixmap: roterad, beskuren, origo uppe till vänster) till
    PDF:ens egna koordinater. PyMuPDF:s transformation_matrix tar inte med rotationen (och inte beskärningen i
    sidled) på en roterad sida, så den räknas här som sidan utan rotation följd av rotation_matrix."""
    vinkel = sida.rotation
    if vinkel % 360 == 0:
        return ~sida.transformation_matrix
    sida.set_rotation(0)
    utan = sida.transformation_matrix
    sida.set_rotation(vinkel)
    return ~(utan * sida.rotation_matrix)


def lagg_text(doc, sida, stycken, skala):
    """Lägger orden som osynlig text (render mode 3) på sina platser, i läsordning, som en egen
    innehållsström sist på sidan. Nära Tesseracts egen PDF, som PDFKit på iPaden läser bra:
    * ett textblock (BT) för hela sidan och en teckenstorlek per rad,
    * varje ord placeras med Tm och sträcks till sin ruta med Tz (inte med cm per ord: när CTM byter skala
      mellan orden slår pdf.js ihop orden utan mellanslag, provat 9 november),
    * ordet och ett mellanslag (utom radens sista) pressas in i ordets ruta. PDFKit och MuPDF får
      mellanslaget, och pdf.js, som hoppar över ett mellanslag sist i en textbit, ser glappet till nästa ord,
    * orden står vågrätt, men varje ord på radens lutande baslinje (en trappa). Med lutningen i textmatrisen
      (som Tesseract gör) kände pdf.js inte alltid igen radbytet, och sista ordet på en rad flöt ihop med
      första ordet på nästa. Vågrätt gav 0 hopslagna ord på en riktig Lindqvist-sida (550 ord), lutande 4.
    Helvetica med WinAnsi-kodning, så å, ä och ö följer med. Sidans koordinater (som sidbilden) räknas om till
    PDF:ens med sidans transformation_matrix, så att roterade och beskurna sidor också blir rätt."""
    rader = [r for s in stycken for r in s if r]
    if not rader:
        return
    sida.insert_font(fontname="helv")
    sida.wrap_contents()
    inv = till_pdf(sida)
    lin = fitz.Matrix(inv.a, inv.b, inv.c, inv.d, 0, 0)
    ops = ["q", "BT", "3 Tr"]
    for rad_ in rader:
        ord_ = [(t, x0 / skala, y0 / skala, x1 / skala, y1 / skala) for t, x0, y0, x1, y1 in rad_]
        storlek = max(1.0, _median(o[4] - o[2] for o in ord_))
        # Radens lutning ur ordens nederkant (minsta kvadrat), baslinjen ur medianen: ord med nedstapel (g, p)
        # är färre än ord utan.
        xs = [(o[1] + o[3]) / 2 for o in ord_]
        ys = [o[4] for o in ord_]
        lut = 0.0
        if len(ord_) >= 2 and max(xs) - min(xs) > 1:
            mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
            namnare = sum((x - mx) ** 2 for x in xs)
            lut = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / namnare if namnare else 0.0
            lut = max(-0.15, min(0.15, lut))
        bas = _median(y - lut * x for x, y in zip(xs, ys)) - storlek * 0.12
        u = fitz.Point(1, 0) * lin
        v = fitz.Point(0, -1) * lin  # uppåt på sidan
        lu, lv = abs(u), abs(v)
        u, v = fitz.Point(u.x / lu, u.y / lu), fitz.Point(v.x / lv, v.y / lv)
        ops.append(f"/helv {_tal(storlek)} Tf")
        for nr, (text, x0, _, x1, _) in enumerate(ord_):
            text_ = text if nr == len(ord_) - 1 else text + " "
            # Bara tecken som finns i WinAnsi (cp1252), andra blir ?. Längden mäts med fitz.Font: fitz.get_text_length
            # räknar fel på å, ä och ö (PyMuPDF 1.28, "åäö" ger 1,112 em i stället för 1,668), och då sträcks
            # orden för långt och flyter ihop med nästa ord i pdf.js.
            text_ = text_.encode("cp1252", errors="replace").decode("cp1252")
            langd = helvetica().text_length(text_, fontsize=storlek)
            # Är glappet till nästa ord mindre än en femtedel av teckenstorleken kortas ordet, så att pdf.js ser ett
            # mellanslag (annars blir två ord ett).
            slut = x1
            if nr < len(ord_) - 1:
                slut = max(x0 + 0.5 * (x1 - x0), min(x1, ord_[nr + 1][1] - 0.2 * storlek))
            bredd = slut - x0
            tz = max(5.0, 100.0 * bredd / langd) if langd > 0 else 100.0
            o = fitz.Point(x0, bas + lut * x0) * inv
            kod = text_.encode("cp1252").hex()
            ops.append(f"{_tal(u.x)} {_tal(u.y)} {_tal(v.x)} {_tal(v.y)} {_tal(o.x)} {_tal(o.y)} Tm "
                       f"{_tal(tz)} Tz <{kod}> Tj")
    ops += ["ET", "Q"]
    xref = doc.get_new_xref()
    doc.update_object(xref, "<< >>")
    doc.update_stream(xref, ("\n".join(ops) + "\n").encode("ascii"))
    innehall = sida.get_contents() + [xref]
    doc.xref_set_key(sida.xref, "Contents", "[" + " ".join(f"{x} 0 R" for x in innehall) + "]")


def textfil(stycken):
    return "\n\n".join("\n".join(" ".join(o[0] for o in r) for r in s) for s in stycken)


# ---------------------------------------------------------------- huvudprogrammet


def tolka_sidor(text, antal):
    if not text:
        return list(range(antal))
    ut = set()
    for del_ in text.split(","):
        if "-" in del_:
            a, b = del_.split("-", 1)
            ut.update(range(int(a) - 1, min(antal, int(b))))
        elif del_.strip():
            ut.add(int(del_) - 1)
    return sorted(i for i in ut if 0 <= i < antal)


def tolka_argument(argv):
    flaggor = {"--ersatt-text", "--snabb", "--kontroll"}
    args, fria = {}, []
    it = iter(argv)
    for a in it:
        if a in flaggor:
            args[a[2:]] = True
        elif a.startswith("--"):
            args[a[2:]] = next(it)
        else:
            fria.append(a)
    return args, fria


def kor(args, fria):
    importera()
    if len(fria) != 2:
        raise ValueError("Ange in- och utfil: sokbar_pdf.py <in.pdf> <ut.pdf>")
    infil, utfil = (os.path.abspath(p) for p in fria)
    if os.path.normcase(infil) == os.path.normcase(utfil):
        raise ValueError("Utfilen får inte vara samma fil som infilen.")
    tesseract = hitta_tesseract(args.get("tesseract"))
    if not tesseract:
        raise Saknas("tesseract")
    tessdata = hitta_tessdata(tesseract, args.get("tessdata"))
    sprak = args.get("lang", "swe")
    if not tessdata or not os.path.isfile(os.path.join(tessdata, sprak + ".traineddata")):
        raise Saknas(f"sprak {sprak}")
    spaltval = args.get("spalter", "auto")
    if spaltval not in ("auto", "1", "2"):
        raise ValueError("--spalter ska vara auto, 1 eller 2.")
    arbetare = max(1, int(args.get("arbetare", 2)))
    utmapp = os.path.dirname(utfil) or "."
    os.makedirs(utmapp, exist_ok=True)
    ledigt = shutil.disk_usage(utmapp).free
    behov = os.path.getsize(infil) * 1.2 + 300 * 1024 * 1024
    if ledigt < behov:
        raise RuntimeError(f"För lite ledigt utrymme på disken ({ledigt / 2**30:.1f} GB ledigt).")
    lasare = Lasare(tesseract, tessdata, sprak, args.get("avbryt-fil"))
    las = threading.Lock()  # PyMuPDF är inte trådsäkert
    doc = fitz.open(infil)
    if doc.needs_pass:
        raise RuntimeError("PDF:en är låst med lösenord.")
    sidor = tolka_sidor(args.get("sidor"), len(doc))
    if not args.get("ersatt-text"):
        med_text = [i for i in sidor if len(doc[i].get_text().strip()) > 20]
        if med_text:
            raise HarText(f"{len(med_text)} {len(sidor)}")
    rotmapp = args.get("tmp") or None
    if rotmapp:
        os.makedirs(rotmapp, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="sokbar_", dir=rotmapp)
    rad("START", len(sidor))
    t0 = time.time()
    klara = [0]

    def jobb(i):
        mapp = os.path.join(tmp, f"s{i}")
        os.makedirs(mapp, exist_ok=True)
        try:
            lasare.kolla()
            with las:
                s = doc[i]
                skala = max(1.0, BREDD / s.rect.width)
                pix = s.get_pixmap(matrix=fitz.Matrix(skala, skala), colorspace=fitz.csGRAY, alpha=False)
                im = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.stride)[:, :pix.width].copy()
                del pix
            stycken, info = las_sida(lasare, im, mapp, spaltval, args.get("snabb"))
            return i, stycken, skala, info
        finally:
            shutil.rmtree(mapp, ignore_errors=True)  # sidbilderna tas bort direkt (disken är liten)

    resultat = {}
    try:
        with ThreadPoolExecutor(arbetare) as ex:
            framtid = [ex.submit(jobb, i) for i in sidor]
            try:
                for f in framtid:
                    i, stycken, skala, info = f.result()
                    resultat[i] = (stycken, skala)
                    klara[0] += 1
                    tecken = len(textfil(stycken))
                    rad("SIDA", klara[0], len(sidor), i + 1, tecken, info)
            except BaseException:
                lasare.stopp.set()  # sidorna som pågår slutar vid nästa Tesseract-körning
                for f in framtid:
                    f.cancel()
                raise
        lasare.kolla()
        texter = []
        for i in sidor:
            stycken, skala = resultat[i]
            s = doc[i]
            if args.get("ersatt-text"):
                ta_bort_text(s)
            lagg_text(doc, s, stycken, skala)
            texter.append(f"--- sida {i + 1} ---\n{textfil(stycken)}")
        meta = {k: v for k, v in (doc.metadata or {}).items()
                if k in ("title", "author", "subject", "keywords", "creator", "creationDate", "modDate") and v}
        meta["producer"] = f"Sensus sokbar_pdf.py {VERSION} med Tesseract"
        doc.set_metadata(meta)
        tillfallig = utfil + ".tmp"
        doc.save(tillfallig, garbage=3, deflate=True)
        doc.close()
        os.replace(tillfallig, utfil)
        if args.get("txt"):
            with open(args["txt"], "w", encoding="utf-8") as fil:
                fil.write("\n\n".join(texter))
    except BaseException:
        try:
            doc.close()
        except Exception:  # noqa: BLE001
            pass
        for p in (utfil + ".tmp",):
            if os.path.exists(p):
                os.remove(p)
        raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rad("KLAR", utfil)
    print(f"tid {time.time() - t0:.0f} s", file=sys.stderr, flush=True)
    return 0


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    args, fria = tolka_argument(argv)
    if args.get("kontroll"):
        return kontroll(args)
    try:
        return kor(args, fria)
    except Saknas as fel:
        rad("SAKNAS", fel)
        return 3
    except HarText as fel:
        rad("HAR_TEXT", fel)
        print("Sidorna har redan text. Kör med --ersatt-text för att byta textlagret.", file=sys.stderr)
        return 5
    except Avbruten:
        rad("AVBRUTEN")
        return 4
    except Exception as fel:  # noqa: BLE001 (felet visas i Sensus)
        rad("FEL", str(fel).replace("\n", " "))
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
