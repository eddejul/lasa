# Gör sökbar (P1)

`sokbar_pdf.py` gör en skannad PDF sökbar: sidorna läses med Tesseract och orden läggs som osynlig text på
originalsidorna, i läsordning. Bilderna i PDF:en rörs inte. Windows-appen kör skriptet med knappen Gör sökbar
(se `windows/README.md`), och det går också att köra själv:

```
python tools/ocr/sokbar_pdf.py <in.pdf> <ut.pdf> [--tessdata <mapp med swe.traineddata>] [--txt <ut.txt>]
python tools/ocr/sokbar_pdf.py --kontroll [--tesseract <tesseract.exe>] [--tessdata <mapp>]
```

Fler val: `--spalter auto|1|2`, `--sidor 1,3-5`, `--arbetare 2`, `--tmp <mapp>`, `--ersatt-text` (byter ett
befintligt textlager, till exempel en äldre helsidesläsning), `--avbryt-fil <fil>` (skriptet slutar när filen
finns) och `--snabb` (ingen uträtning). Det behövs Python 3 med PyMuPDF, numpy och Pillow, Tesseract och
språkmodellen (`swe.traineddata`). En egen tessdata-mapp behöver bara modellen, inga konfigurationsfiler.

## Läsordningen

Tesseracts egen sökbara PDF (helsidesläsningen) blandar ihop spalterna där raderna böjer sig mot bokryggen.
Ordet och sökningen fungerar ändå, men meningen som sparas med ordet, markeringar över flera rader och
sökning efter en fras följer fel ordning. Här läses varje spalt för sig, som i Edvins flöde för kurslitteraturen
(`ocr_spalter.py` och `utrata.py`, oktober 2026):

* mittrännan hittas som en sned linje, och räknas om ur band när fotnoterna tar halva sidan eller spalterna
  slutar högt upp,
* fotnotsblocket är raderna som korsar rännan, sökt nerifrån, och läses sist över hela bredden,
* en remsa av motstående boksida vitmålas bara när den når spaltens kant, är smal och syns i flera band,
* varje spalt läses både som den är och uträtad (varje rad följs genom 24 remsor), och varianten med flest
  säkra ord behålls. Uträtningens förskjutning räknas tillbaka till originalsidan,
* en sida utan tydlig ränna läses som en spalt.

## Textlagret

En egen innehållsström sist på varje sida: Helvetica med WinAnsi-kodning (å, ä och ö följer med), ett ord i
taget med `Tm` och `Tz` så att ordet täcker sin ruta, mellanslaget inne i ordets ruta som i Tesseracts egen
PDF, och varje ord vågrätt på radens lutande baslinje. Så läser både pdf.js (Windows-appen), MuPDF och,
härlett, PDFKit (iPaden) orden med mellanslag och radbyten i rätt ordning.

## Rader till standard ut

`START <sidor>`, `SIDA <klara> <sidor> <sidnummer> <tecken> <info>`, `KLAR <ut.pdf>`. Fel: `FEL <text>`
(returkod 1), `SAKNAS <vad>` (3), `AVBRUTEN` (4) och `HAR_TEXT <sidor med text> <sidor>` (5).

## Prov

`python tools/ocr/test_sokbar.py [--tessdata <mapp>]` gör påhittade testsidor med `testsidor.py` (två spalter
med böjda rader, en spalt, en sned sida med kanten av motstående sida) och kontrollerar läsordningen, å, ä och
ö, att sidorna ser likadana ut, `--ersatt-text`, avbrottet, en saknad språkmodell och orden på roterade sidor.
Inga sidor ur riktiga böcker ligger i repot. Bygget läser bara in skripten (ingen Tesseract där).
