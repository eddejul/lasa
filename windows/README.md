# Läsa för Windows (fas 5)

Läsa på datorn: kurslitteratur i PDF, EPUB och textfiler (txt, md), med samma ordfunktion och samma ordbok
som på iPaden. Appen är byggd med Tauri, pdf.js (PDF) och foliate-js (EPUB och text), och den byggs i
GitHub Actions. Ingen Rust eller annan utvecklingsmiljö behövs på datorn.

## Installera

1. Gå till repot på github.com, fliken **Actions**, och välj **Windows build** till vänster.
2. Öppna den senaste körningen med grön bock (på grenen `fas5`, eller `main` när fas 5 är ihopslagen).
3. Längst ner under Artifacts: ladda ner **Lasa-windows** och packa upp zip-filen. Där finns två
   installationsfiler som gör samma sak. Använd den som slutar på `-setup.exe`.
4. Dubbelklicka på `-setup.exe`. Läsa installeras för ditt konto, så det behövs ingen administratör.
5. Installationsfilen är inte signerad, så Windows visar **Windows skyddade datorn**. Klicka på
   **Mer info** och sedan **Kör ändå**.
6. Starta Läsa från Start-menyn. Fönstret öppnas i full storlek.

Uppdatera: kör en nyare `-setup.exe` på samma sätt. Böcker, läspositioner och sparade ord finns kvar.

Läsa behöver Microsoft Edge WebView2, som redan finns i Windows 11. Saknas den hämtar installationen den.

## Använda

* **Lägg till böcker:** knappen Lägg till böcker, eller dra in filer var som helst i fönstret. Filen kopieras
  in i Läsas egen mapp, och originalet rörs inte. Samma fil två gånger läggs inte till igen.
* **Bläddra:** högerpil och vänsterpil, PageDown och PageUp, mellanslag (Skift och mellanslag bakåt),
  mushjulet, eller pilarna som syns i sidans kanter när musen är över sidan. Home och End går till
  början och slutet. Esc går tillbaka till biblioteket.
* **Uppslag:** två sidor bredvid varandra när fönstret är brett nog, annars en. I PDF ligger omslaget ensamt
  till höger och sedan sida 2 och 3, 4 och 5, som på iPaden.
* **PDF, Visning:** Automatiskt (standard) visar hela sidan, och uppslag, om texten blir läsbar. På en
  bärbar dator med 150 procents skalning blir en hel A4-sida för liten, och då visas en sida i läsbar
  storlek som du rullar i. Nedåtpil, mellanslag och mushjulet rullar först och bläddrar när sidan är slut.
  Du kan också välja Hela sidan eller Sidbredd. Ctrl och plus eller minus (eller Ctrl och mushjulet)
  zoomar, Ctrl och 0 återställer.
* **Innehåll** visar bokens innehållsförteckning. **Gå till sida** (PDF) tar bokens egna sidnummer, som
  xii eller 45, och annars sidans plats i filen. Klicka på sidnumret nere till höger för samma sak.
  Reglaget nere hoppar i boken.
* **Tema:** vitt, sepia eller mörkt, för alla böcker. Mörkt vänder ljusheten på PDF-sidor men behåller
  färgerna, så att bilder inte blir negativ.
* **Aa** (EPUB och text): typsnitt och textstorlek.
* Läspositionen sparas per bok och finns kvar när du öppnar boken igen.

### Ordfunktionen

**Dubbelklicka på ett ord**, eller **högerklicka** på det. Beslutet: dubbelklick är det vanliga sättet att
peka ut ett ord i alla Windows-program (det markerar ordet), så det känns naturligt. Högerklick gör samma
sak för den som hellre använder det, eftersom en läsare inte behöver någon egen högerklicksmeny. Ett
vanligt klick gör ingenting, så det går fortfarande att markera text och kopiera den med Ctrl och C.

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

Språket: finns ordet bara i ett språk blir det det språket. Finns det i båda (som "glass" eller "far")
räknar Windows-appen vanliga småord i meningen, eftersom Apples språkigenkänning bara finns på iPaden.
Oavgjort blir svenska, som på iPaden. För engelska ord avgör ordet före vilken ordklass som visas först
("the attribute" ger substantivet, "to attribute" verbet).

Ett avstavat ord över en radbrytning i en PDF ("kun-" och "skap") slås ihop till "kunskap", som på iPaden.

## Synk med iPaden (fas 6)

Läspositioner och sparade ord synkas med iPaden via ditt eget Supabase-projekt (gratisnivån). Hur projektet
skapas, och hur synken fungerar, står i [docs/SYNK.md](../docs/SYNK.md). Böckerna själva synkas inte: lägg
samma fil i Läsa på båda ställena. Böckerna känns igen på filens innehåll (SHA-256), inte på namnet.

1. Fliken **Inställningar**, Synk med iPaden.
2. Fyll i projektets adress (`https://...supabase.co`), den publika nyckeln (börjar med `sb_publishable_`,
   eller den äldre anon-nyckeln, aldrig secret-nyckeln), e-post och lösenord. Samma som på iPaden.
3. Klicka **Logga in**. Läsa synkar direkt, och statusen visar vad som skickades och hämtades.

Lösenordet sparas aldrig. Den publika nyckeln och inloggningen (förnyelsetoken) sparas i Windows
Autentiseringshanteraren (Kontrollpanelen, Autentiseringshanteraren, Windows-autentiseringsuppgifter, namn
som börjar med `sync-` och slutar med `se.edvin.lasa`). Logga ut tar bort inloggningen.

* Läsa synkar när appen startar, när du stänger en bok (högst en gång i minuten) och med **Synka nu**.
  Utan inställningar händer ingenting.
* Den nyaste ändringen vinner, rad för rad. En nyare position från iPaden gäller nästa gång boken öppnas.
  Är boken öppen när synken kommer hoppar den inte, och den skriver inte över iPadens position om du inte
  bläddrar.
* PDF synkar sidan. EPUB synkar kapitlet och hur långt in i kapitlet du är, så på andra enheten hamnar du
  på samma ställe i kapitlet men inte alltid exakt samma rad. Textfiler (txt, md) synkar inte positionen,
  eftersom iPaden delar dem i kapitel på sitt eget sätt.
* Ett ord som tas bort i Sparade ord tas bort på iPaden också. Repetitionen från iPaden följer med orden
  oförändrad (Windows-appen repeterar inte).
* Markeringar och bokmärken synkas inte till datorn än, och iPadens rader rörs inte.

## Var allt sparas

I mappen `%APPDATA%\se.edvin.lasa`:

* `Böcker\` med bokfilerna. Varje fil heter efter sitt id, som är SHA-256 av filens innehåll (64 tecken).
  Samma id används på iPaden i fas 6, så att böckerna kan kännas igen mellan enheterna.
* `bibliotek.sqlite`: biblioteket, läspositioner (med ändringstid för synken) och inställningar, även
  synkens adress och e-post.
* `anvandarord.sqlite`: sparade ord och dolda synonympar. Tabellen `saved_words` har samma kolumner som på
  iPaden, plus `uuid` och `book_id`, `deleted` för borttagna ord och iPadens repetition.

Ordboken (`lasa-ordbok.sqlite`) ligger bland programfilerna och ändras aldrig.

## Kända brister

* Markeringar, anteckningar, bokmärken, sök i boken, repetition, uppläsning och AI-knappen finns inte på
  datorn än. Synken tar bara läspositioner och sparade ord.
* Synken är provad mot en låtsas-Supabase, inte mot ett riktigt Supabase-projekt.
* Skannade PDF:er utan textlager: sidorna visas, men ord går inte att slå upp. Appen säger till.
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
  src-tauri/          Rust-delen: ordboken (dict_query), användarens databaser, bokfilerna, synkens
                      hemligheter i Autentiseringshanteraren (secret_get, secret_set)
  dev/server.py       kör gränssnittet i en vanlig webbläsare utan Tauri
  tests/              paritetstest, enhetstester och provkörning i Chrome
  tools/              vendor.mjs (kopierar pdf.js), make_icons.py (ikonen)
```

**Uppslagslogiken finns i tre kopior:** `tools/dictionary/lookup.py`, `App/Dictionary/WordDictionary.swift`
och `windows/src/js/lookup.js`. Ändras en ska de andra ändras i samma commit. `tests/parity.mjs` kör
lookup.js och lookup.py över hela testlistan mot samma databas och jämför svaren. Den körs i bygget
(jobbet Paritetstest).

**Provkörning utan Tauri:** ladda ner ordboken (artefakten `ordbok` från en körning), starta
`python windows/dev/server.py --dictionary <lasa-ordbok.sqlite> --data <tom mapp>` och öppna
http://127.0.0.1:8955/. Servern svarar på samma kommandon som Rust-delen och skickar samma
Content-Security-Policy som appen.

**Tester:**

* `node --no-warnings windows/tests/parity.mjs <lasa-ordbok.sqlite>`: lookup.js mot lookup.py.
* `node --test windows/tests/wordfind.test.mjs`: avstavning, meningar, språk och normalisering.
* `python windows/tests/make_testbooks.py <mapp>` och sedan
  `python windows/tests/e2e.py --books <mapp> --out <mapp för bilder>`: lägger till böcker, bläddrar,
  slår upp ord, provar teman, zoom, Sparade ord, läspositionen efter omladdning och att skript i EPUB
  stoppas, i huvudlös Chrome mot `dev/server.py` med tom datamapp.
* `python windows/tests/e2e_sync.py --books <mapp> --out <mapp>` (också mot `dev/server.py` med tom
  datamapp): startar `tests/mock_supabase.py` på port 8956 med ett frö, loggar in, synkar och kontrollerar
  vad som hamnar i appen och på servern, att en andra synk skickar och hämtar noll rader, att borttaget blir
  `deleted = true`, att en öppen bok inte hoppar och att markeringar aldrig rörs. Provservern låter sidan
  anropa 127.0.0.1 (bara den, appen får bara anropa `https://*.supabase.co`).

**Bygget:** workflow `Windows build` (`.github/workflows/windows-build.yml`) körs vid push till `main`
och `fas*` när något under `windows/`, `tools/dictionary/` eller själva workflowfilen ändras. Ordboken
byggs med samma steg och cache som i iOS-bygget, och Tauri bygger installationsfilerna på `windows-latest`.
Versionerna är låsta: npm-paketen i `package.json` och `package-lock.json`, Rust i `Cargo.toml` och
`Cargo.lock`.
