# Frågefilen (K6, frågor i marginalen)

En frågefil är en JSON-fil bredvid boken. Varje fråga hör till ett ställe i texten och syns som en liten
numrerad prick i marginalen när Frågor i marginalen är påslaget (Aa i läsaren). Ett tryck på pricken visar
frågan, Visa svaret visar svaret, och Kan, Osäker och Kan inte sparar hur det gick (tabellen
`question_answers` i markeringar.sqlite, steg 10). Innehåll får då fliken Frågor.

## Var filen ligger

Filen heter som boken plus `.fragor.json` och läggs i samma mapp som boken i Filer (På min iPad, Sensus,
Böcker, eller kursmappen där boken ligger). Appen prövar i den här ordningen:

1. `Bok.pdf.fragor.json` bredvid boken (bäst, gäller bara den filen).
2. `Bok.fragor.json` bredvid boken (gäller alla filer som heter Bok, till exempel både Bok.pdf och Bok.epub).
3. Samma två namn direkt i Böcker.

Frågefiler visas aldrig som böcker i biblioteket. Utan fil har fliken Frågor knappen Välj frågefil, som
kopierar en vald JSON-fil till plats 1.

En frågefil får vara högst 2 MB. En större fil läses inte, och fliken Frågor säger varför. Sätt alltid `id` på varje fråga och ändra det aldrig: svaren sparas under id:t, och utan id börjar svaret om när frågan eller citatet rättas.

## Formatet

```json
{
  "sensus": "frågor",
  "version": 1,
  "bok": "Herrick kap 4 (s99-102).pdf",
  "fragor": [
    {
      "id": "s1a",
      "sida": 1,
      "citat": "De Oratore was written",
      "titel": "Varför skrev han boken?",
      "fraga": "Vem svarar han på, och i vilket läge i sitt eget liv skriver han?",
      "svar": ["Han svarar Platon.", "Han skriver efter landsflykten, år 55 f.Kr."]
    },
    {
      "sida": 3,
      "y": 0.4,
      "fraga": "En fråga till en fotad sida utan text: pricken står på 40 procent av sidans höjd.",
      "svar": "Svaret kan också vara en enda text."
    }
  ]
}
```

| Fält | Krävs | Betydelse |
|---|---|---|
| `fraga` | ja | Frågan. |
| `citat` | ja, eller `sida` | Några ord ordagrant ur boken där frågan hör hemma. Letas upp som markeringarna och sökningen: stora och små bokstäver, radbrytningar och avstavningar spelar ingen roll. Håll det kort (3 till 8 ord) och unikt. |
| `sida` | nej | PDF: sidan i filen, från 1. Där letar appen först, och står citatet på flera ställen väljs det närmast sidan. En fråga utan citat (fotad sida) får sin prick på den här sidan. |
| `kapitel` | nej | EPUB och text: kapitlets rubrik som i Innehåll (eller början av den), eller kapitlets nummer i filens läsordning från 1 (omslaget räknas). |
| `y` | nej | Fotad sida utan text: prickens höjd, 0 överst och 1 nederst. Annars 0,08. |
| `titel` | nej | Kort rubrik i rutan och i fliken Frågor. |
| `svar` | nej | En text eller en lista med punkter. |
| `id` | nej | Frågans id. Svaren sparas under det, så behåll samma id när filen ändras. Utan id räknas ett ur frågan och citatet, och då börjar svaret om när frågan skrivs om. |

Filen får också vara bara listan med frågor. Fälten kan heta `question`, `quote`, `page`, `chapter`,
`title` och `answer` i stället.

## Från läskompanjonen

I läskompanjonen för Cicero (`innehall.js`) blir en läspunkt under `leta` en fråga: `titel` som
`titel`, `text` som `fraga`, och raderna i `stod` för samma fråga som `svar`. Läspunktens ställe
(`var.sida` och ordet i `fran`) blir `sida` och `citat`, men citatet ska vara bokens egna ord, några ord
från stället där läspunkten börjar.

## Kontrollera en fil

```
python tools/fragor/kontrollera.py "Bok.pdf.fragor.json" "Bok.pdf"
```

Skriptet säger vilka frågor appen hoppar över och var varje citat står i boken. PDF kräver PyMuPDF.
