# Läsa: specifikation

Arbetsnamn: **Läsa**. En läsapp för PDF, EPUB och textfiler som ersätter Apple Books, med en ordfunktion: tryck på ett ord och få synonymer (svenska) eller synonymer plus svensk översättning (engelska).

Senast uppdaterad: 7 november 2026.

## 1. Mål

1. Bläddringen ska kännas som Apple Books: pappersvikning som följer fingret, utan hack, även på en iPad Air 2.
2. Tryck på ett ord och få hjälp direkt, utan internet.
3. Gratis i drift. Inga servrar som kostar pengar, ingen betald AI.
4. Fungera för kurslitteratur (PDF och EPUB) både på iPaden och på Windows-datorn.

## 2. Enheter

| Enhet | Roll | Begränsning |
|---|---|---|
| iPad Air 2, iPadOS 15.8.3 | Huvudenhet | Kan inte uppdateras längre än iPadOS 15. A8X, 2 GB RAM. Ingen vibrationsmotor. |
| Windows-dator | Kurslitteratur, PDF och EPUB | Ingen Mac. All iOS-kompilering sker i molnet. |
| iPhone 12 | Ibland | Har vibrationsmotor, så mikrovibrationer fungerar här. |

## 3. Arkitektur

```
            ┌──────────────────────────────┐
            │  Ordboksdatabas (SQLite)     │  byggs av tools/dictionary (Python)
            │  samma fil i båda apparna    │
            └──────────────┬───────────────┘
                           │
        ┌──────────────────┴───────────────────┐
        │                                      │
 iPad/iPhone-app (Swift, UIKit)        Windows-app (Tauri, fas 5)
 PDFKit + Readium + egen pappersvikning   foliate-js + pdf.js
```

### iPad/iPhone-appen

* **Språk och ramverk:** Swift 5 (språkläge 5), UIKit för läsaren. SwiftUI får användas för enkla skärmar som inställningar, men bara med API:er som finns i iOS 15.
* **Lägsta version:** iOS/iPadOS 15.0.
* **Projektfil:** genereras av XcodeGen från `project.yml`. Ingen `.xcodeproj` i repot.
* **PDF:** PDFKit. Sidorna renderas till bilder i bakgrunden och visas i en `UIPageViewController` med övergången `.pageCurl`.
* **EPUB:** Readium Swift Toolkit (ReadiumStreamer) för att öppna och tolka filen. Visningen sker i en egen navigator med pappersvikning (se 6.3), eftersom Readiums egen navigator inte har pappersvikning.
* **Textfiler** (txt, md, rtf, html): görs om till enkel HTML vid import och visas i samma navigator som EPUB.
* **Haptik:** `Haptics`-klassen. Lätt knackning vid sidbyte och ordtryck. iPad saknar motor, anropen ignoreras där.
* **Lagring:** böcker i appens `Documents/Böcker`, synliga i Filer-appen. Läsposition och inställningar lokalt.

### Windows-appen (fas 5)

Tauri med foliate-js (EPUB) och pdf.js (PDF). Samma ordboksfil och samma logik för att hitta ordet under muspekaren. Bläddring med piltangenter och mushjul.

## 4. Funktioner, i prioritetsordning

1. Bibliotek: lista, importera (plusknapp, "Öppna i Läsa" från Filer, dra in i Filer), ta bort.
2. Läsning med pappersvikning, tryck i kanten för att bläddra, läsposition sparas per bok.
3. Ordfunktionen (avsnitt 5).
4. Innehållsförteckning, hoppa till sida, reglage för sidnummer.
5. Teman (vitt, sepia, mörkt) och typsnitt/storlek för EPUB och text.
6. Markeringar, anteckningar, bokmärken, sök i boken.
7. Sparade ord med repetition.
8. Bläddringsljud på iPad (avstängbart).
9. Synk mellan iPad och dator.
10. AI-knappen "Förklara i sammanhang".
11. Uppläsning (AVSpeechSynthesizer).

## 5. Ordfunktionen

### 5.1 Flöde

1. Användaren håller fingret på ett ord (0,35 s). Ett vanligt tryck i mitten visar menyn och i kanterna bläddrar det, så ordfunktionen kan inte ligga på ett vanligt tryck. Vald i fas 2, Edvin bedömer det på iPaden.
2. Appen tar fram ordet och meningen runt det.
   * PDF: `PDFPage.selectionForWord(at:)` på tryckpunkten, omräknad till sidans koordinater. Avstavade ord över radbrytning ("kun-" + "skap") slås ihop.
   * EPUB/text: litet JavaScript i webbvyn med `document.caretRangeFromPoint` som utökas till hela ordet.
3. Normalisering: gemener, ta bort skiljetecken.
4. Språk: slå upp i båda formtabellerna. Om ordet finns i båda avgör `NLLanguageRecognizer` på meningen. Oavgjort blir svenska.
5. Grundform via formtabellen ("sprang" blir "springa", "went" blir "go").
6. Popup visas. iPad: popover vid ordet. iPhone: bottenark (`UISheetPresentationController`, finns från iOS 15).
7. Ordet sparas automatiskt i "Sparade ord" tillsammans med meningen.

### 5.2 Popupens innehåll

**Svenskt ord**
* Grundform och ordklass
* Synonymer grupperade per betydelse, sorterade efter styrka
* Knapp **Visa i SO/SAOL** som öppnar svenska.se i en `SFSafariViewController`

**Engelskt ord**
* Grundform och ordklass
* Synonymer på engelska grupperade per betydelse, med kort definition
* Svensk översättning (flera kandidater, vanligast först)

### 5.3 Datakällor

| Behov | Källa | Licens |
|---|---|---|
| Svenska synonymer och betyg | Folkets synonymlexikon Synlex (KTH) | fri med upphovsnotis |
| Vilken betydelse en svensk synonym hör till | Swesaurus (Språkbanken), bygger på Folkets synonymlexikon | CC BY 4.0 |
| Svenska böjningsformer | SALDO morfologi (Språkbanken) | öppen, kontrollera vid nedladdning |
| Engelska synonymer och definitioner | Open English WordNet | CC BY 4.0 |
| Engelska till svenska | Folkets lexikon (KTH) | CC BY-SA 2.5 |
| Svensk definition | svenska.se i webbvy | visas, lagras inte |

Appen ska ha en sida "Om ordboken" som anger källorna och licenserna.

Svenska Akademiens data (SO/SAOL) har inget öppet API och ingen öppen licens. Den visas bara via svenska.se i webbvy, den kopieras aldrig in i databasen.

### 5.4 Databasen

Byggs av `tools/dictionary/build.py` (Python), körs i GitHub Actions på Linux och läggs in i appen som resurs. Mål: under 80 MB.

```sql
CREATE TABLE sv_forms (form TEXT, lemma TEXT, pos TEXT);
CREATE TABLE sv_synonyms (lemma TEXT, sense_id TEXT, synonym TEXT, score REAL);
CREATE TABLE en_forms (form TEXT, lemma TEXT, pos TEXT);
CREATE TABLE en_senses (lemma TEXT, synset_id TEXT, pos TEXT);
CREATE TABLE en_synsets (synset_id TEXT PRIMARY KEY, definition TEXT);
CREATE TABLE en_synset_members (synset_id TEXT, lemma TEXT);
CREATE TABLE en_sv (en_lemma TEXT, sv TEXT, pos TEXT, rank INTEGER);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
-- index på alla form- och lemma-kolumner
```

Kvalitetsregler:
* Visa bara synonympar med betyg 3 eller högre på Synlex femgradiga skala. Tröskeln ligger i en konstant så den kan justeras.
* Paren tas från Synlex, och Swesaurus används bara för att placera dem i rätt betydelse. Swesaurus egna par utan betyg (wiktionary, beräknade par) gav fel som "giltig" och "ogiltig", se `tools/dictionary/README.md`.
* Testlista: `tools/dictionary/testwords.txt` med 150 ord ur riktig kurslitteratur. Skriptet skriver ut appens svar för varje ord så att Edvin kan jämföra med svenska.se.
* Knapp "Fel synonym" i popupen döljer paret lokalt.

### 5.5 AI-knappen (fas 6)

* Google Gemini, gratisnivån (Flash-Lite eller Flash). Modellnamnet är en inställning, inte hårdkodat.
* API-nyckeln skrivs in av Edvin i appens inställningar och sparas i Keychain. Aldrig i repot.
* Modellen får meningen, ordet och kandidaterna från ordboken, och ska bara välja bland dem (strukturerat JSON-svar). Den får inte hitta på egna synonymer.
* Ingen nyckel eller inget nät: knappen döljs.

## 6. Läsaren i detalj

### 6.1 PDF (fas 0 och 1)

* `PDFPageRenderer` renderar sidor till `UIImage` på en egen kö med ett eget `PDFDocument`, högst 5 bilder i minnet. Sidan som ska visas går före förritningen, och förritning som inte längre behövs avbryts. Saknas bilden visas papperet tills den är klar, huvudtråden ritar aldrig.
* Renderingsstorleken beror bara på vyns storlek och fasta marginaler, inte på om menyraden eller statusfältet syns. Sidan står still när menyn visas, och inget behöver ritas om.
* Menyraden: innehållsförteckning (ur PDF:ens bokmärken), zoom och bakgrund. Nederkanten: reglage för att hoppa i boken och sidnumret, som öppnar Gå till sida.
* Gå till sida tar bokens egna sidnummer (sidetiketter som "xii" eller "45") först, annars sidans plats i filen.
* Zoom: dubbeltryck i mitten av sidan, eller knappen i menyn, öppnar sidan i en zoombar `PDFView` för små tabeller och figurer.
* Bakgrund: vitt, sepia eller mörkt. Mörkt vänder ljusheten men behåller färgtonen, så att bilder inte blir negativ. Gäller alla böcker. Zoomvyn visar alltid originalfärgerna.
* Skannade PDF:er utan textlager: ordfunktionen fungerar inte. Textigenkänning med Vision undersöks senare.

### 6.2 Känsla

* Pappersvikning med `UIPageViewController(transitionStyle: .pageCurl)`. Edvin har godkänt känslan (7 november 2026).
* Stående: en sida i taget, ryggen till vänster.
* Liggande på iPad: uppslag med två sidor och ryggen i mitten, som i Apple Books (Edvins beslut 7 november 2026). Omslaget ligger ensamt till höger, sedan sida 2 och 3, 4 och 5 och så vidare, som i en tryckt bok. iPhone visar alltid en sida.
* Menyraden döljs vid första sidbytet och visas med tryck i mitten av sidan.
* Sidnummer nere i mitten, tonas bort tillsammans med menyn.
* Mål: 60 bilder per sekund under vikningen på iPad Air 2. Ingen rendering på huvudtråden under en pågående vikning.

### 6.3 EPUB med pappersvikning (fas 3)

Den svåraste delen av appen.

* ReadiumStreamer öppnar boken: ryggrad (spine), innehållsförteckning, resurser.
* Varje kapitel visas i en `WKWebView` med CSS-kolumner så att kapitlet delas i sidor lika stora som skärmen.
* Varje sida i `UIPageViewController` är en ögonblicksbild (`takeSnapshot`) av rätt kolumn. När vikningen är klar ersätts bilden av den levande webbvyn så att text kan tryckas på.
* Antal sidor per kapitel räknas i förväg och sparas per kombination av kapitel, typsnitt, storlek och skärmstorlek.
* Högst 3 webbvyer samtidigt (förra, nuvarande, nästa) för att spara minne.
* Läsposition sparas som Readium Locator (kapitel plus andel), så att den överlever byte av typsnitt.

## 7. Bygge och installation

1. Claude Code skriver koden på Windows och pushar till `main`.
2. Workflow `iOS build` (`.github/workflows/ios-build.yml`) kör på `macos-26`: XcodeGen, sedan `xcodebuild archive` utan signering, sedan packas `Lasa-unsigned.ipa` som artefakt.
3. Vid fel läser Claude Code loggen med `gh run view --log-failed` och rättar.
4. Edvin laddar ner artefakten, installerar med Sideloadly (gratis Apple-ID). AltStore kan förnya automatiskt var 7:e dag över wifi.

Begränsningar med gratis Apple-ID: appen går ut efter 7 dagar, högst 3 egna appar per enhet. Betalt utvecklarkonto (99 USD per år) tar bort båda.

Det finns ingen iOS 15-simulator på byggservern. Allt som beror på iOS 15 testas på iPaden.

## 8. Faser

Varje fas är klar först när Edvin har testat den på iPaden.

| Fas | Innehåll | Klar när |
|---|---|---|
| 0 | Byggflöde, bibliotek, PDF med pappersvikning, läsposition | En PDF går att öppna och bläddra i på iPaden |
| 1 | PDF klar: innehållsförteckning, hoppa till sida, zoom, teman för bakgrund | Edvin kan läsa en hel kursbok i PDF |
| 2 | Ordboken: Python-skript, databas, tryck på ord i PDF, popup, SO-knapp, sparade ord, haptik | Testlistan ger rimliga svar och popupen öppnas på under 150 ms |
| 3 | EPUB och textfiler med pappersvikning, typsnitt och storlek, ordfunktion i EPUB | En EPUB-roman läses utan hack |
| 4 | Markeringar, anteckningar, bokmärken, sök, bläddringsljud | Allt sparas och överlever omstart |
| 5 | Windows-appen | Kurslitteratur i PDF och EPUB läses på datorn med ordfunktion |
| 6 | Synk, AI-knapp, repetition av sparade ord, uppläsning | Läsposition och sparade ord följer med mellan iPad och dator |

### Synk (fas 6)

* Bokfilerna ligger i en mapp i iCloud Drive. Den nås från iPaden via Filer och från Windows via iCloud för Windows.
* Läsposition, markeringar och sparade ord synkas via Supabase (gratisnivån). Projektet pausas efter en veckas inaktivitet, data finns kvar.
* Böcker identifieras med en hash av filens innehåll, inte med filnamnet.

## 9. Risker

| Risk | Hantering |
|---|---|
| EPUB med pappersvikning är svårt | Bygg det som en isolerad navigator. Prototyp först, mät minne och bildfrekvens på iPaden. |
| Framtida Xcode höjer lägsta iOS över 15 | Lås Xcode-versionen i workflowen med `xcode-select` på en version som stöder 15. |
| Readium höjer lägsta iOS | Lås Readium på en version som stöder iOS 15. |
| Gemini gratisnivå ändras | AI-knappen är ett tillägg. Allt annat fungerar utan den. |
| Långsam utvecklingsloop utan Mac | Små steg, en sak per push. Skärmbilder från simulator i CI när det behövs. |

## 10. Öppna frågor

* Slutligt namn på appen. Edvin funderar och återkommer.
