# Sensus för Windows (tidigare Läsa, fas 5 och 7)

Sensus på datorn: kurslitteratur i PDF, EPUB och textfiler (txt, md, rtf, html), med samma ordfunktion och
samma ordbok som på iPaden. Appen hette Läsa: installationen, Start-menyn och datamappen heter fortfarande
Läsa och `se.edvin.lasa`, så att böcker och data finns kvar.

Appen är byggd med Tauri, pdf.js (PDF) och foliate-js (EPUB och text), och den byggs i GitHub Actions. Ingen Rust eller annan utvecklingsmiljö behövs på datorn.

## Installera

1. Gå till repot på github.com, fliken **Actions**, och välj **Windows build** till vänster.
2. Öppna den senaste körningen med grön bock (på `main`, eller grenen du vill prova).
3. Längst ner under Artifacts: ladda ner **Lasa-windows** och packa upp zip-filen. Där finns två
   installationsfiler som gör samma sak. Använd den som slutar på `-setup.exe`.
4. Dubbelklicka på `-setup.exe`. Läsa installeras för ditt konto, så det behövs ingen administratör.
5. Installationsfilen är inte signerad, så Windows visar **Windows skyddade datorn**. Klicka på
   **Mer info** och sedan **Kör ändå**.
6. Starta Läsa från Start-menyn (i fönstret heter appen Sensus). Fönstret öppnas i full storlek.

Uppdatera: kör en nyare `-setup.exe` på samma sätt. Böcker, läspositioner och sparade ord finns kvar.

Läsa behöver Microsoft Edge WebView2, som redan finns i Windows 11. Saknas den hämtar installationen den.

**Öppna med:** installationen lägger till Sensus under Öppna med för PDF och EPUB i Utforskaren (högerklick,
Öppna med). Sensus blir inte standardprogram för filerna, det väljer du själv i Windows. Boken läggs till och
öppnas, och är appen redan öppen kommer fönstret fram i stället för att en ny startas.

## Använda

* **Lägg till böcker:** knappen Lägg till böcker (Ctrl och O), eller dra in filer var som helst i fönstret.
  Filen kopieras in i appens egen mapp, och originalet rörs inte. Samma fil två gånger läggs inte till igen,
  inte heller med ett annat namn.
* **Ny version av en bok** (G3): heter filen som en bok du redan har, men innehållet är nytt (till exempel efter
  ny OCR), frågar Sensus: Ersätt och behåll markeringarna, Ersätt och börja om, Behåll båda (den nya heter då
  `Bok 2.pdf`) eller Avbryt. **Ta bort** tar bort boken ur biblioteket, men markeringar och läsposition finns
  kvar: lägger du till samma fil igen kommer allt tillbaka, och en fil med liknande namn (`Bok (OCR) 2.pdf`)
  ger frågan Ny version av boken, behåll markeringarna? Frågan visar både den borttagna bokens och den nya
  filens namn, eftersom siffror inte räknas (`Föreläsning 3.pdf` och `Föreläsning 4.pdf` liknar varandra).
  Medan filerna läses in visas hur långt det har kommit. Låsta (lösenord) och trasiga PDF:er läggs inte till,
  och appen säger varför.
* **Bläddra:** högerpil och vänsterpil, PageDown och PageUp, mellanslag (Skift och mellanslag bakåt),
  mushjulet, eller pilarna som syns i sidans kanter när musen är över sidan. Home och End går till
  början och slutet. Esc går tillbaka till biblioteket.
* **Uppslag:** Automatiskt (två sidor när fönstret är brett nog), En sida eller Två sidor, under Visning (PDF)
  och Aa (EPUB och text). I PDF ligger omslaget ensamt till höger och sedan sida 2 och 3, 4 och 5, som på
  iPaden.
* **Bläddra eller rulla** (PDF, under Visning): Bläddra visar en sida eller ett uppslag i taget. Rulla visar
  alla sidor efter varandra som en lång remsa (bra för artiklar), med en eller två sidor per rad efter valet
  Uppslag. Bara sidorna som syns och några runt dem ritas, högst 6 (10 med två sidor per rad). Pilarna
  höger och vänster går en rad, Home och End till början och slutet. Ordfunktionen, markeringar, sök och
  läspositionen fungerar i båda lägena. Valet gäller alla böcker.
* **PDF, Visning:** Automatiskt (standard) visar hela sidan, och uppslag, om texten blir läsbar. På en
  bärbar dator med 150 procents skalning blir en hel A4-sida för liten, och då visas en sida i läsbar
  storlek som du rullar i. Nedåtpil, mellanslag och mushjulet rullar först och bläddrar när sidan är slut.
  Du kan också välja Hela sidan eller Sidbredd. Ctrl och plus eller minus (eller Ctrl och mushjulet)
  zoomar, Ctrl och 0 återställer.
* **Innehåll** visar bokens innehållsförteckning. **Gå till sida** (PDF) tar bokens egna sidnummer, som
  xii eller 45, och annars sidans plats i filen. Klicka på sidnumret nere till höger för samma sak.
  Reglaget nere hoppar i boken.
* **Tema:** vitt, sepia, mörkt eller Följ systemet (ljust eller mörkt som Windows), för alla böcker. T byter
  tema. Mörkt vänder ljusheten på PDF-sidor men behåller färgerna, så att bilder inte blir negativ.
* **Aa** (EPUB och text): typsnitt och textstorlek.
* Läspositionen sparas per bok och finns kvar när du öppnar boken igen.
* **Sök i boken** (knappen Sök eller Ctrl och F): träfflista med utdrag, klick visar träffen. Samma sökning som
  på iPaden: stora och små bokstäver räknas lika, och ett ord avstavat över en radbrytning hittas.
* **Markeringar:** dra över texten med musen och välj en av fyra färger, eller Anteckning. Klicka på en
  markering för att byta färg, skriva en anteckning, kopiera eller ta bort. **Bokmärke** (eller B) på sidan.
  Panelen **Markeringar** listar bokmärken och markeringar. Synkas inte än (se Kända brister).
* **Gör sökbar** (P1, under varje PDF i biblioteket): en skannad PDF får osynlig text genom datorns OCR, så
  att ordfunktionen, sök och markeringar fungerar. Sensus kör `tools/ocr/sokbar_pdf.py` (se
  `tools/ocr/README.md`) med Python och Tesseract. Texten kommer i läsordning, vänster spalt, höger spalt och
  sist fotnoterna, inte i helsidesläsningens blandade ordning. Förloppet visar sida N av M och har Avbryt.
  Den nya filen heter `<namn> (sökbar).pdf` och läggs i biblioteket bredvid originalet, som inte ändras. En
  bok som redan har text (till exempel en äldre sökbar PDF) ger frågan Läs om sidorna. Det behövs Python 3 med
  PyMuPDF, numpy och Pillow, Tesseract OCR och den svenska modellen `swe.traineddata`. Saknas något säger en
  ruta vad. Sökvägarna ställs in under Inställningar, Gör sökbar (OCR): Python (tomt är `python`),
  Tesseract (tomt är Program Files) och Mapp med språkmodeller (tomt är Tesseracts egen tessdata-mapp, som
  från början bara har engelska). Spara och kontrollera visar vad som hittades. Ett jobb i taget. Sidbilderna
  ligger i datamappen under `OCR` medan de behövs och tas bort direkt, och mappen töms när appen startar.
* **Tangentbordet:** ? visar alla genvägar. F11 helskärm, Ctrl och G gå till sida (i EPUB en plats eller
  procent). Webbläsarens egna tangenter (F5, Ctrl och R, Ctrl och P) gör ingenting.

### Ordfunktionen

**Dubbelklicka på ett ord**, eller **högerklicka** på det. Beslutet: dubbelklick är det vanliga sättet att
peka ut ett ord i alla Windows-program (det markerar ordet), så det känns naturligt. Högerklick gör samma
sak för den som hellre använder det, eftersom en läsare inte behöver någon egen högerklicksmeny. Ett
vanligt klick gör ingenting. Att dra över text visar färgerna för en markering, och Ctrl och C kopierar
fortfarande den markerade texten.

Rutan har samma innehåll och ordning som på iPaden:

* Överst grundform och ordklass ("grundform till sprang", "efterled i kurslitteraturläsning").
* Engelskt ord: **På svenska** med översättningen, lånad från en synonym om ordet saknas i Folkets lexikon.
  Sedan förklaringen på engelska med liknande engelska ord.
* Svenskt ord: **Betydelse** ur Folkets lexikon med de vanligaste synonymerna, eller Andra ord för det.
* Klicka på betydelsen för synonymerna en och en (klicka på en synonym för att slå upp den, Fel synonym
  döljer den). N betydelser till och Även som (andra ordklasser) ligger bakom ett klick.
* **Visa i SO och SAOL** öppnar svenska.se i webbläsaren. Svenska Akademiens data kopieras aldrig in.
* Visa som engelska eller svenska, när ordet finns i båda språken.
* Ordet sparas i **Sparade ord** med meningen det stod i, boken och sidan.
* **Förklara i meningen** (AI-knappen): finns när en nyckel till Google Gemini är inskriven under
  Inställningar, Förklaring med AI. Samma regler som på iPaden: modellen väljer bara bland ordbokens
  betydelser och ord. Nyckeln sparas i Windows Autentiseringshanteraren.
* **Repetera** i Sparade ord: ordet och meningen, Visa svaret (mellanslag) och fyra betyg (1 till 4), med
  exakt samma schema som på iPaden (`src/js/review.js`). Repetitionen synkas.

Språket: finns ordet bara i ett språk blir det det språket. Finns det i båda (som "glass" eller "far")
räknar Windows-appen vanliga småord i meningen, eftersom Apples språkigenkänning bara finns på iPaden.
Oavgjort blir svenska, som på iPaden. För engelska ord avgör ordet före vilken ordklass som visas först
("the attribute" ger substantivet, "to attribute" verbet).

Ett avstavat ord över en radbrytning i en PDF ("kun-" och "skap") slås ihop till "kunskap", som på iPaden.

## Synk med iPaden (F1)

Läspositioner och sparade ord synkas med iPaden via en mapp i iCloud Drive, med en liten fil per enhet. Inget
konto och ingen nyckel. Formatet och hur synken fungerar står i [docs/SYNK.md](../docs/SYNK.md). Böckerna
själva synkas inte här: lägg samma fil i Sensus på båda ställena. Böckerna känns igen på filens innehåll
(SHA-256), inte på namnet.

1. Installera iCloud för Windows och slå på iCloud Drive. Mappen syns som `C:\Users\<namn>\iCloudDrive`.
2. Välj en mapp där på iPaden först (Inställningar, Synk), till exempel `Sensus`.
3. Fliken **Inställningar**, Synk med iPaden: tryck **Hitta iCloud Drive** (eller skriv in mappen, till
   exempel `C:\Users\<namn>\iCloudDrive\Sensus`) och **Spara och prova**. Sensus provar att skriva och läsa
   där, synkar direkt och visar iPaden under Status.

* Sensus skriver bara i undermappen `Sensus synk`, och bara sin egen fil (`<datorns id>.json`, id:t ligger i
  inställningarna som `syncDevice`). Filen skrivs först som `.tmp` och byter sedan namn.
* Sensus synkar när appen startar, när du stänger en bok (högst en gång i minuten) och med **Synka nu**.
  Utan vald mapp händer ingenting.
* Den nyaste ändringen vinner, rad för rad. En nyare position från iPaden gäller nästa gång boken öppnas.
  Är boken öppen när synken kommer hoppar den inte.
* En fil som inte går att läsa (tom, trasig, från en nyare version, eller inte hämtad från iCloud inom 15
  sekunder) hoppas över och syns under Status. Inget tas bort för att en fil saknas.
* PDF synkar sidan. EPUB synkar kapitlet och hur långt in i kapitlet du är. Textfiler (txt, md) synkar inte
  positionen, eftersom iPaden delar dem i kapitel på sitt eget sätt.
* Ett ord som tas bort i Sparade ord tas bort på iPaden också. Repetitionen synkas åt båda hållen.
* Markeringar och bokmärken från iPaden följer med oförändrade i datorns fil men visas inte här än.
  Datorns egna markeringar synkas inte än.
* **Sluta synka** glömmer mappen. Inga filer tas bort.

## Var allt sparas

I mappen `%APPDATA%\se.edvin.lasa`:

* `Böcker\` med bokfilerna. Varje fil heter efter SHA-256 av filens innehåll (64 tecken). Samma
  kontrollsumma är synkens `book_id`, så att böckerna känns igen mellan enheterna.
* Varje bok har dessutom ett eget id (G3, ett UUID) som aldrig ändras, inte heller när en ny version ersätter
  filen. Markeringar, bokmärken och läsposition hänger på det. Tabellen `books` har kolumnerna `sha256`,
  `file_name` (namnet på filen som lades till, som `file` på iPaden), `missing` (borttagen ur biblioteket,
  raden finns kvar) och `modified`. Böcker från före version 0.8.0 flyttas en gång när appen startar
  (`moves` i `statements.json`): först en kopia, `bibliotek före bokens id <tid>.sqlite` i datamappen, sedan
  flytten i en transaktion. Den går att köra om. Version 0.5.0 till 0.7.0 tog bort hela raden vid Ta bort men
  lämnade markeringar och bokmärken under kontrollsumman. Från 0.8.1 får varje sådan kontrollsumma en
  borttagen rad (`missing = 1`, tom filtyp och tomt filnamn) med kopian `bibliotek före borttagna böcker
  <tid>.sqlite` först, så att boken kommer tillbaka med markeringarna när samma fil läggs till igen.
* `bibliotek.sqlite`: biblioteket, läspositioner (med ändringstid för synken) och inställningar, även
  synkens adress och e-post. Tabellerna `highlights` och `bookmarks` har samma kolumner som iPadens
  `markeringar.sqlite` (book är bokens id): section, start, length (UTF-16) och text, som i docs/SYNK.md.
* `anvandarord.sqlite`: sparade ord och dolda synonympar. Tabellen `saved_words` har samma kolumner som på
  iPaden, plus `uuid` och `book_id`, `deleted` för borttagna ord och iPadens repetition.

Ordboken (`lasa-ordbok.sqlite`) ligger bland programfilerna och ändras aldrig.

## Kända brister

* Markeringar och bokmärken synkas inte. Uppläsning finns inte på datorn. Synken tar läspositioner och
  sparade ord med repetitionen.
* En PDF över 16 MB läses i bitar (bara det pdf.js behöver), en mindre läses hel. Hur mycket som slipper
  läsas beror på PDF:en: om alla sidor delar en resurslista (som PDF:er från reportlab) läses ändå nästan
  allt. Minnet hålls nere med högst 4 ritade sidor (6 i uppslag) och högst 8 miljoner bildpunkter per sida.
* Synken (F1) är provad mot en vanlig mapp med påhittade iPad-filer, inte mot iCloud för Windows.
* Skannade PDF:er utan textlager: sidorna visas, men ord går inte att slå upp förrän boken gjorts sökbar
  (Gör sökbar). Appen säger till.
* Språkgissningen och den engelska ordklassen är enklare än iPadens, som använder Apples språkverktyg.
  Knappen Visa som engelska eller svenska rättar fel språk.
* I EPUB visas platsen som "plats 12 av 340". En plats är ungefär 1 500 tecken, inte en tryckt sida.
* EPUB med fast layout (som bilderböcker) visas med foliate-js egen visning och är inte provad.
* Skript i EPUB-filer körs inte, med flit (Content-Security-Policy stoppar dem).
* Installationsfilen är inte signerad (se Installera).
* Ingen pappersvikning, och den är inte tänkt för datorn.

## För utveckling

```
windows/
  src/                gränssnittet (vanlig HTML, CSS och JavaScript-moduler, inget byggsteg)
    js/lookup.js      uppslagslogiken, tredje kopian (se nedan)
    js/wordfind.js    ordet och meningen ur en PDF-sida (som PDFWordFinder.swift)
    js/pdfreader.js   PDF med pdf.js
    js/reflowreader.js EPUB och text med foliate-js
    js/popup.js       ordrutan
    js/sync.js        synken med iPaden (som App/Sync/SyncEngine.swift), js/settings.js inställningarna
    vendor/           pdf.js och foliate-js med licenser, se vendor/VENDOR.md
  src-tauri/          Rust-delen: ordboken (dict_query), användarens databaser med namngivna frågor
                      (db_read, db_write, frågorna i statements.json), bokfilerna, hemligheterna i
                      Autentiseringshanteraren (secret_get, secret_set), Öppna med (pending_take,
                      pending_read) och installationens krokar (nsis-hooks.nsh)
  dev/server.py       kör gränssnittet i en vanlig webbläsare utan Tauri
  tests/              paritetstest, enhetstester och provkörning i Chrome
  tools/              vendor.mjs (kopierar pdf.js)
  src-tauri/icons/    ikonen (S med gul överstrykning), ritad utanför repot och incheckad som filer
```

**Uppslagslogiken finns i tre kopior:** `tools/dictionary/lookup.py`, `App/Dictionary/WordDictionary.swift`
och `windows/src/js/lookup.js`. Ändras en ska de andra ändras i samma commit. `tests/parity.mjs` kör
lookup.js och lookup.py över hela testlistan mot samma databas och jämför svaren. Den körs i bygget
(jobbet Paritetstest).

**Provkörning utan Tauri:** ladda ner ordboken (artefakten `ordbok` från en körning), starta
`python windows/dev/server.py --dictionary <lasa-ordbok.sqlite> --data <tom mapp>` och öppna
http://127.0.0.1:8955/. Servern svarar på samma kommandon som Rust-delen och skickar samma
Content-Security-Policy som appen.

**Databasen:** gränssnittet kan inte skicka egen SQL mot användarens databaser. Varje fråga har ett namn i
`src-tauri/statements.json` (read eller write), som byggs in i appen och läses av `dev/server.py`. Ny fråga:
lägg den där och anropa `read('namn', [...])` eller `write(...)` i `src/js/store.js`. Nya kolumner läggs under
`columns` och läggs till när appen startar. Provservern har dessutom `test_sql` för testerna, appen har det inte.

**Tester:**

* `node --no-warnings windows/tests/parity.mjs <lasa-ordbok.sqlite>`: lookup.js mot lookup.py.
* `node --test windows/tests/*.test.mjs`: avstavning, meningar och språk, RTF, repetitionens schema mot
  `UserWords.swift`, AI-knappens regler och de namngivna databasfrågorna. Körs i bygget.
* `python windows/tests/make_testbooks.py <mapp>` och sedan
  `python windows/tests/e2e.py --books <mapp> --out <mapp för bilder>`: lägger till böcker, bläddrar,
  slår upp ord, provar teman, zoom, Sparade ord, läspositionen efter omladdning och att skript i EPUB
  stoppas, i huvudlös Chrome mot `dev/server.py` med tom datamapp.
* `python windows/tests/e2e_sync.py --url http://127.0.0.1:8968/ --books <mapp> --out <mapp>` (mot
  `dev/server.py` med tom datamapp): gör en synkmapp i `--out` med en påhittad iPad-fil och tre filer som ska
  hoppas över, väljer mappen, synkar och kontrollerar appen och datorns egen fil, att en andra synk inte skriver
  om filen, att borttaget blir `deleted = true`, att en öppen bok inte hoppar, att iPadens markering följer med
  oförändrad och att Sluta synka inte tar bort något. `node --test windows/tests/syncfile.test.mjs` provar
  formatet och sammanslagningen mot `App/Sync/SyncFile.swift` (körs i bygget).
* `python windows/tests/e2e_fas7.py --books <mapp> --out <mapp> --data <serverns datamapp>` (mot
  `dev/server.py` med tom datamapp): tema och Följ systemet, förlopp och fel vid import, rtf och html,
  synkadressen, sök, genvägarna, markeringar och bokmärken i PDF och EPUB, minnestaket, repetitionen,
  uppslagen, de namngivna frågorna och AI-knappen (Gemini besvaras av testet).
* `python windows/tests/e2e_fas8.py --dictionary <lasa-ordbok.sqlite> --books <mapp> --out <mapp>`: startar själv
  `dev/server.py` (port 8963) med egna datamappar. G3: påhittade data från 0.7.0, flytten med kopian före, en
  andra start, namnbyte, ny version, Behåll båda, Ersätt och börja om, Ta bort och tillbaka, och en bok som
  togs bort i 0.7.0 som läggs till igen med markeringen kvar. W10: Rulla och Bläddra med uppslagen,
  ordfunktionen, markeringar, sök och läspositionen.
* `dev/server.py --open <fil> ...` gör som Öppna med: filerna läggs till och den första öppnas.
* `python windows/tests/e2e_ocr.py --dictionary <lasa-ordbok.sqlite> --out <mapp> --tessdata <mapp med
  swe.traineddata>`: Gör sökbar med riktig Python och Tesseract. Startar själv `dev/server.py` (port 8967) med
  tom datamapp och en påhittad tvåspaltig sida (`tools/ocr/testsidor.py`): rutan när modellen saknas,
  Inställningar, förloppet, den nya boken bredvid originalet, pdf.js textlager i spaltordning, meningen som
  sparas med ett ord över en radbrytning, frågan Läs om sidorna och Avbryt. `dev/server.py` kör skriptet
  direkt ur `tools/ocr`, appen ur sina resurser (`ocr/sokbar_pdf.py`, se `tauri.conf.json`).

**Bygget:** workflow `Windows build` (`.github/workflows/windows-build.yml`) körs vid push till `main`
och `fas*` när något under `windows/`, `tools/dictionary/`, `tools/ocr/` eller själva workflowfilen ändras. Ordboken
byggs med samma steg och cache som i iOS-bygget, och Tauri bygger installationsfilerna på `windows-latest`.
Versionerna är låsta: npm-paketen i `package.json` och `package-lock.json`, Rust i `Cargo.toml` och
`Cargo.lock`.
