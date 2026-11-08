# Sensus: specifikation

Namn: **Sensus** (beslutat 8 november 2026, arbetsnamnet Läsa finns kvar i filnamn, bundle-id och mappar). En läsapp för PDF, EPUB och textfiler som ersätter Apple Books, med en ordfunktion: tryck på ett ord och få synonymer (svenska) eller synonymer plus svensk översättning (engelska).

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
 PDFKit + WKWebView + egen pappersvikning foliate-js + pdf.js
```

### iPad/iPhone-appen

* **Språk och ramverk:** Swift 5 (språkläge 5), UIKit för läsaren. SwiftUI får användas för enkla skärmar som inställningar, men bara med API:er som finns i iOS 15.
* **Lägsta version:** iOS/iPadOS 15.0.
* **Projektfil:** genereras av XcodeGen från `project.yml`. Ingen `.xcodeproj` i repot.
* **PDF:** PDFKit. Sidorna renderas till bilder i bakgrunden och visas i en `UIPageViewController` med övergången `.pageCurl`.
* **EPUB:** en egen liten läsare i appen: zip packas upp med Apples Compression, och OPF, nav och NCX läses med XMLParser. Readium valdes bort i fas 3 (7 november 2026): det drar in många beroenden som inte går att provbygga utan Mac, och appen behöver bara ryggrad, innehållsförteckning och resurser. Visningen sker i en egen navigator med pappersvikning (se 6.3).
* **Textfiler** (txt, md, rtf, html): görs om till enkel HTML när boken öppnas och visas i samma navigator som EPUB.
* **Haptik:** `Haptics`-klassen. Lätt knackning vid sidbyte och ordtryck. iPad saknar motor, anropen ignoreras där.
* **Lagring:** böcker i appens `Documents/Böcker`, synliga i Filer-appen. Läsposition och inställningar lokalt.

### Windows-appen (fas 5)

Tauri med foliate-js (EPUB) och pdf.js (PDF). Samma ordboksfil och samma logik för att hitta ordet under muspekaren. Bläddring med piltangenter och mushjul.

Så blev den (7 november 2026, detaljer i `windows/README.md`):

* **Mappar:** `windows/src` är gränssnittet i vanlig HTML, CSS och JavaScript utan byggsteg. `windows/src-tauri` är en liten Rust-del (Tauri 2.12, rusqlite) som läser ordboken skrivskyddat med parametriserade SELECT-frågor, sparar användarens data i två egna SQLite-filer (`bibliotek.sqlite`, `anvandarord.sqlite`) och bokfilerna i appens datamapp.
* **Uppslagslogiken** är en tredje kopia i JavaScript (`windows/src/js/lookup.js`). Ett paritetstest jämför den med `lookup.py` över testlistan i varje bygge. Språket avgörs som på iPaden, men med vanliga småord i stället för NLLanguageRecognizer när ordet finns i båda språken, och engelsk ordklass med ordet före i stället för NLTagger.
* **Ordet:** dubbelklick eller högerklick. Ordet och meningen tas fram med samma regler som på iPaden (avstavning över radbrytning i PDF, mening runt ordet), rutan har samma innehåll och ordning.
* **PDF:** pdf.js (legacy-bygget) ritar sidorna på canvas med textlager ovanpå. Uppslag med omslaget ensamt till höger när sidan ryms läsbart, annars en sida i läsbar storlek som man rullar i. Visning: Automatiskt, Hela sidan eller Sidbredd, och zoom.
* **EPUB och text:** foliate-js med CSS-kolumner, två kolumner i brett fönster. Textfiler görs om till HTML med samma regler som TextBookConverter.swift. Content-Security-Policy stoppar skript i EPUB-filer.
* **Böcker** identifieras med SHA-256 av filens innehåll (gemener hex), samma id som synken i fas 6 ska använda. Sparade ord har kolumnerna `uuid` och `book_id` utöver iPadens.
* **Bygget:** workflow `Windows build`, ordboken med samma cache som iOS-bygget, installationsfiler (NSIS och MSI) i artefakten `Lasa-windows`. Osignerade.
* **Synk (fas 6):** läspositioner (PDF och EPUB, inte textfiler) och sparade ord enligt `docs/SYNK.md`, i `windows/src/js/sync.js`. Publik nyckel och förnyelsetoken i Windows Autentiseringshanteraren (crate keyring). Markeringar och bokmärken synkas inte till Windows.
* **Natten 8 november 2026 (version 0.7.0):** markeringar i fyra färger med anteckningar och bokmärken (i `bibliotek.sqlite`, ingen synk ännu), sök i boken (Ctrl+F), repetition av sparade ord, AI-knappen, Öppna med i Utforskaren, valet Två sidor under Visning, en lista över kortkommandon (?), tema som följer systemet och stora PDF:er som läses i bitar. Detaljer i `windows/README.md`.
* **Version 0.8.0 (8 november 2026):** böckerna har ett eget id som på iPaden (G3), Ta bort behåller markeringarna och läspositionen, PDF kan visas som Rulla (alla sidor efter varandra, bara de närmaste ritade) eller Bläddra, och appen har Sensus-ikonen.
* **Version 0.8.1 (8 november 2026):** markeringar för böcker som togs bort i 0.7.0 eller tidigare kommer tillbaka när samma fil läggs till igen, och frågan Ny version av boken visar båda filnamnen.

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
| Ursprung, uttal och fler översättningar (O10) | Wiktionary via kaikki.org, strömmas och filtreras i bygget | CC BY-SA 4.0 |
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

Den svåraste delen av appen. Byggd 7 november 2026.

* EPUB packas upp en gång i appens cache (`Caches/Uppackade böcker`), och varje kapitel får en viewport-rad så att webbvyn lägger ut texten i sidans bredd. Kopieringsskyddade böcker (DRM) avvisas med ett meddelande, förvrängda teckensnitt går bra.
* Varje kapitel visas i en `WKWebView` med CSS-kolumner på html-elementet, så att kapitlet delas i sidor lika stora som en sida. Sidan som syns väljs genom att flytta dokumentet i sidled med en transform, webbvyn rullar aldrig.
* Webbvyerna ligger dolda bakom sidorna. Varje blad i `UIPageViewController` är en ögonblicksbild (`takeSnapshot`) av rätt kolumn, så vikningen bara flyttar bilder och ritandet sker i webbvyns egen process.
* Bilden byts inte mot den levande webbvyn efter vikningen, som det först var tänkt. I stället slås ord upp och länkar följs i den dolda webbvyn, på samma ställe som fingret trycker på bilden (`caretRangeFromPoint`). Det ger samma funktion utan att vyer byts under fingret.
* Antal sidor per kapitel mäts när kapitlet laddas och sparas per kombination av kapitel, typsnitt, storlek och skärmstorlek (`Caches/Sidantal`). När alla kapitel är mätta visas bokens sidnummer, annars sidan i kapitlet och hur långt in i boken man är.
* Högst 3 webbvyer samtidigt (nuvarande, nästa, förra kapitel) och högst 5 sidbilder.
* Läsposition sparas som kapitel plus andel av kapitlet, så att den överlever byte av typsnitt, storlek och skärmläge.
* Typsnitt: bokens eget, Iowan, Charter, Georgia, Palatino, Avenir och San Francisco. Storlek från 80 till 200 procent av bokens egen. Gäller alla EPUB- och textböcker.
* Uppslag i liggande på iPad: varje kapitel börjar på en vänstersida.
* Länkar i boken (innehållssidor) hoppar dit och visar Tillbaka (V4, se 6.12). Fotnoter visas i en ruta (V5). Webblänkar öppnas i Safari i appen.
* Bygget kör ett simulatortest (`tools/simtest`): appen öppnar testböcker i en iPad-simulator, bläddrar, slår upp ett ord, byter typsnitt och tema och sparar bilder och logg i artefakten Simulatortest.

### 6.4 Markeringar, anteckningar, bokmärken och sök (fas 4)

Byggd 7 november 2026 på grenen `fas4`.

* **Markera:** pennan i menyn startar markeringsläget. Sidan står still och fingret markerar det det drar över, ord för ord. En rad nere har färgerna (gul, grön, blå, rosa), bläddring och Klar. Ett tryck på ett ord markerar ordet. Långtryck för ordboken fungerar som förut utanför markeringsläget. Överlappande markeringar slås ihop.
* **Markeringens ruta:** ett tryck på en markering visar färgerna, Anteckning, Kopiera och Ta bort. En markering med anteckning får ett streck under.
* **Bokmärken:** knappen i menyn märker sidan man läser med ett rött band. I EPUB sparas bokmärket som kapitel och andel av kapitlet.
* **Listor:** Innehåll har flikarna Innehåll, Bokmärken och Markeringar. Tryck för att hoppa dit, svep för att ta bort.
* **Sök:** i hela boken, i bakgrunden, högst 500 träffar. Skiftläge, radbrytningar och avstavningar spelar ingen roll, men å, ä och ö skiljs från a och o. Träffen visas med en orange ram en kort stund.
* **Bläddringsljud:** ett svagt prassel när en sida börjar vikas, på från början, kan stängas av i menyn Bakgrund.
* Allt sparas i en egen databas och överlever omstart. Borttaget sparas som borttaget, så att synken i fas 6 kan föra det vidare.

### 6.5 Repetition, AI-knappen och synk (fas 6)

Byggd 7 november 2026 på grenen `fas6`.

* **Repetera ord:** kort med ordet och meningen det stod i, svaret ur ordboken bakom ett tryck. Igen, Svårt, Bra och Lätt flyttar ordet i ett schema i stil med Anki (Igen: tio minuter, Bra: en dag, sedan tre dagar och vidare). Högst 20 nya ord per dag.
* **Kortläget (U6, 9 november 2026):** kortet Repetera i biblioteket med antalet ord, en tunn framstegslinje och ett papperskort med ordet, meningen och källan, svaret tonas fram vid ett tryck och betygen ligger längst ner med intervallet under. Filter överst: alla ord, en bok eller en kurs. Svårt ger alltid kortare tid än Bra (nytt ord: 10 min, 6 tim, 1 dag, 4 dagar). Småord sparas aldrig, och ord utan svar i ordboken kommer inte med. Ingen tid för omgången, bara antal ord.
* **Uppläsning:** byggdes med AVSpeechSynthesizer men togs bort 8 november 2026, eftersom rösterna lät som en robot. Ett bättre alternativ undersöks senare.
* **AI-knappen:** se 5.5. Modellen är `gemini-3.5-flash-lite` från början och kan bytas under Inställningar.
* **Synk:** se `docs/SYNK.md`. Supabase med e-post och lösenord, regler som bara släpper fram den inloggades rader, och den nyaste ändringen vinner rad för rad.
* **Inställningar:** kugghjulet i biblioteket: bläddringsljud, AI-nyckel och modell, synkens adress, nyckel och inloggning, säkerhetskopian och Dela loggen.

### 6.6 Grunden (våg 1, 8 november 2026)

* **Säkerhetskopia:** en kopia per dag i Filer (Säkerhetskopia) med markeringar, anteckningar, sparade ord och läspositioner, de sju senaste. Återställ från säkerhetskopia i Inställningar sparar först det som finns nu.
* **Utgångsvarning:** två dagar innan appen går ut visar biblioteket när, och att den ska förnyas i Sideloadly.
* **Logg:** Filer, Diagnostik, med starter, tider, fel och Apples rapporter om krascher (MetricKit). Delas från Inställningar.
* **Databaserna** har versionsnummer och en trappa av uppdateringar, skriver i transaktioner och säger till när något inte kunde sparas.

### 6.7 Våg 2 (8 november 2026)

* **Boken känns igen på innehållet (G3):** varje bok har ett eget id i ett bokregister med kontrollsumma, sökväg och titel. Namnbyte och flytt i Filer behåller markeringar och läsposition. En ny version av en bok (samma namn och nytt innehåll, eller liknande namn när den gamla filen är borta) ger frågan Ny version av boken. Böcker i undermappar syns, med mappen under titeln.
* **EPUB-kapitel som inte kunde visas (G2):** visar Kapitlet kunde inte visas med Försök igen i stället för en tom sida.
* **Import (G10):** sker i bakgrunden med förlopp i biblioteket. Ett upptaget namn ger Ersätt och behåll markeringarna, Ersätt och börja om, Behåll båda eller Avbryt.
* **Vikningen (G6) och fotade PDF:er (G5):** markeringarnas rutor sparas, och färdiga sidbilder sparas på disk (högst cirka 300 MB) så att en fotad sida inte behöver avkodas igen.

### 6.8 Våg 2b (8 november 2026)

* **Sökregister per bok (G11):** bokens text sparas en gång i bakgrunden när boken öppnats (PDF också när den lagts in), och sökningen letar där i stället för att läsa om hela boken. Träffarna och den orange ramen blir desamma som förut. Saknas registret söker appen direkt i boken som förut.
* **Gemensam kod för läsarna (G12):** menyraden, bubblan och hållgesten och markeringsläget finns på ett ställe för både PDF och EPUB. Inget ändrat för den som läser.

### 6.9 Våg 3 (8 november 2026)

* **Sensus och ikonen (U8):** hemskärmen visar Sensus med S-ikonen. Bundle-id och mappar är oförändrade, så appen ersätter den gamla.
* **Papper och bläck (U1):** bakgrunden Papper (varmvitt) är förvald och gäller hela appen: biblioteket, inställningarna, menyraderna och rutorna följer bakgrunden man väljer i läsaren. Vitt finns kvar. Inställningar har Följ systemet (mörkt när iPaden är i mörkt läge).
* **Markeringsraden (U5):** ett tryck på en markering visar en smal rad ovanför markeringen (under om det inte finns plats): färgerna, Anteckning, Kopiera, Slå upp och Ta bort.
* **Menyraden (U3):** Bibliotek och Innehåll till vänster, titeln och kapitlet i mitten, Sök, Markera, Aa och Mer till höger. Bokmärket är ett band i sidans övre hörn: tryck där. Det syns som kontur när menyn är framme och rött när sidan har ett bokmärke.
* **Utseenderutan (U2):** Aa har bakgrunderna och, för EPUB och text, storlek, typsnitt, marginal, radavstånd, justering och Återställ. Raden hålls till ungefär 66 tecken, radavståndet är 1,5 och justerade stycken avstavas på bokens språk. PDF har bakgrunderna och Zooma sidan.
* **Databasrättningar ur granskningen:** säkerhetskopiorna rensas per dag och aldrig kopian före uppdateringen eller den som återställts, synken väntar till nästa start efter en återställning, och böcker från före bokregistret känns igen på storlek och ändringstid.

### 6.10 Våg 4 (8 november 2026)

* **Biblioteket (B1, B2):** ett rutnät med omslag, riktiga titlar och författare ur filerna och en tunn stapel för hur långt man läst. Överst Fortsätt läsa med kapitel, sida och sidor kvar (ingen tid kvar). Filter (Alla, Pågående, Olästa, Utlästa) och Sortera (Senast läst, Titel, Tillagd). Håll fingret på ett omslag för Byt namn, Välj omslag (PDF), Lägg i kurs, Markera som läst och Ta bort. Ta bort behåller markeringarna och läspositionen, som på Windows, så samma fil som läggs in igen öppnas där man var (D3-5).
* **Kurser (B3):** sidopanel med Alla böcker, Läser nu, kurserna (mappar i Böcker blir kurser av sig själva), Repetera med antalet ord som väntar, Sparade ord och Om ordboken, och ett sökfält. En kurs kan få en färg som syns som rand på omslagen. Kurserna synkas inte än.
* **Första start (B5):** en ny installation utan böcker får en välkomstsida och en exempelbok som lär ut bläddring, ordet under fingret och markering, och kortet Gör mer med Sensus (Förklaring med AI). Ett tomt bibliotek har Välj filer, Öppna från Filer och Prova exempelboken.
* **iPhone (U9) och rörelser (U10):** två kolumner och en flikrad längst ner på iPhone. Boken öppnas från omslaget och stängs in i det, omslaget trycks ner lite, och med Minska rörelse blir det toningar.
* **Databasrättningar 2:** dagens säkerhetskopior gallras inte bort, synken står still efter en återställning tills den startas i Inställningar, en fil med samma namn som en borttagen bok ger frågan Ny version, och bokmärkesbandet tar bort med Ångra.

### 6.11 Våg 5 (8 november 2026)

* **Ordkortet (U4):** ordet en gång, stort, med ordklass och SV eller EN. Svaret direkt under, synonymerna som knappar som slår upp ordet i samma ruta, meningen ur boken med ordet understruket och boken och sidan under. Förklara i meningen svarar i samma kort. Längst ner SO och SAOL, Sparat, Fel synonym och betydelserna. Ark i halv höjd på iPhone. Ingen uppläsning. Ett tryck på Sparat tar bort ordet och visar raden Ångra i fem sekunder, och Ångra (eller Spara i samma kort) lägger tillbaka ordet med bok, betydelse och repetition (D3-1).
* **Välj betydelse (O7):** ett tryck på en betydelse sparar den med ordet. Kortet visar den överst och repetitionen bara den. AI-knappen kan föreslå en betydelse, men man väljer själv.
* **Ursprung, uttal och fler översättningar (O10):** ur Wiktionary via kaikki.org (CC BY-SA 4.0). Svenska ord får uttal (IPA) bredvid ordklassen och en rad om ursprunget (första meningen, språknamnen på svenska). Engelska ord får fler svenska översättningar, och ord som saknas i Folkets lexikon får sin översättning därifrån. Bara ord som redan finns i ordboken tas med. Källan står under Om ordboken.
* **Dina ord i texten (O4):** sparade ord får ett streck under sig i alla böjningsformer, helt för ord man övar och prickat för ord man kan (repetitionens intervall minst tre veckor, ingen egen statusvy). Ett tryck på strecket mitt på sidan visar ordkortet med meningen ordet sparades i. Av och på i Aa (Dina ord i texten), från början på.

### 6.12 Våg 6, läsvyn (8 november 2026)

* **Tillbaka och historik (V4):** varje hopp (innehåll, sök, länk, markering, bokmärke, gå till sida, tidslinjen, miniatyrer) sparar platsen man lämnade. Tillbaka till s. N ligger nere till vänster, ett långt tryck visar de fem senaste, krysset döljer knappen. Knappen döljs efter tre vikningar, men Mer har Senaste platser. Ersätter Tillbaka efter länkar i 6.3. Historiken gäller medan boken är öppen.
* **Sidor kvar (V1):** under tidslinjen sidan till vänster och sidor kvar till höger, i kapitlet eller i boken (ett tryck växlar, valet sparas). Ingen tid kvar (Edvins beslut). En PDF utan innehållsförteckning visar boken. EPUB skriver cirka tills alla kapitel är mätta.
* **Tidslinjen (V2):** ersätter reglaget. Streck vid kapitelgränserna, prickar i markeringarnas färger, röda streck för bokmärken, en rund markör. När man drar visar en bubbla kapitlet och sidan, och boken hoppar när man släpper. Kapitlets namn står i mitten under linjen. Lästa sidor (mörkare, även i Innehåll) väntar på läsloggen (K10).
* **Miniatyrer (V3, PDF):** håll på tidslinjen eller välj Mer, Miniatyrer. Rutnät med sidbilder cirka 150 punkter breda, bara synliga ritas. Ett tryck hoppar dit, och Tillbaka ligger kvar tills man går tillbaka eller trycker på krysset. Inte i EPUB.
* **Fotnoter i en ruta (V5):** ett tryck på en fotnotssiffra eller hänvisning visar noten i en ruta vid siffran, med Gå till noten. EPUB: epub:type noteref, role doc-noteref eller en länk till ett ankare vars text är en siffra eller ett tecken. PDF: bara interna länkar med kort text. Hittas noten inte hoppar boken som förut. Trycket går före ordstrecken och bläddringen.
* **Här var du (V6):** öppnas en bok efter mer än ett dygn ligger ett kort över sidan med kapitlets rubrik och de tre senaste markeringarna. Ett tryck stänger det. Ingen fråga (Edvins beslut).

### 6.13 Morgonrättningar (8 november 2026, Edvins test på iPaden)

* **Aa:** efter varje ändring i utseenderutan kontrolleras att sidan får sin nya bild. Saknas den efter några sekunder begärs den igen och läget skrivs i loggen (Diagnostik).
* **Tryckzoner:** bläddring i ett smalt band längs vänster och höger kant (18 procent av bredden, 56 till 110 punkter), resten av sidan visar och döljer menyn, ungefär som i Apple Books. Gäller båda läsarna och uppslag.
* **Marginaler (EPUB och text):** menyraden och nederkanten ligger bara över marginalen, aldrig över text. PDF:ens placering är oförändrad, där ligger menyn oftast över sidans egen vita marginal.
* **Färger:** knappar, sidor kvar och tidslinjen är neutralt grå i stället för blå, som i Apple Books. Vitt ger nästan svart text i EPUB och text, länkar och strecken under dina ord är diskret gråbruna. Sepia är oförändrad.

### 6.14 Våg 7, plugget (8 november 2026)

* **Bokens egna sidnummer (K2, PDF):** `BookPageNumbering` ger bokens sidnummer för en sida i filen, och sidraden, Gå till sida, tidslinjen, bokmärken, citat, anteckningsboken och Anki-exporten använder det. Automatiskt ur filnamnet (`(s63-80)`, uppslag när intervallet är ungefär dubbelt så långt som sidantalet), annars PDF:ens sidetiketter. Mer, Bokens sidnummer: filens första sida som bokens sida N, en eller två boksidor per sida i filen, eller filens egna nummer. Uppslag gäller hela boken, med jämn sida till vänster. Efter granskning 4: filnamnets intervall används av sig självt bara när sidantalet stämmer, valet sparas första gången boken öppnas, och utan inställt sidnummer får citatet ingen sida (rutan säger det och föreslår ett nummer ur sidornas tryckta sidnummer att bekräfta).
* **Kopiera som citat (K3):** knappen Citat i markeringsraden. Harvard, APA 7 och Oxford (fotnot) på svenska (s., u.å., m.fl.), med bokens sidnummer, och referensen. Bokinfo per bok (författare, år, titel, förlag, ort) i Mer, Bokinfo för citat. EPUB fyller i år och förlag ur OPF-filen. EPUB och text får ingen sida.
* **Anteckningsbok (K1):** Mer, Anteckningsbok (en bok, per kapitel) och sidopanelen, Plugg (alla böcker, per bok). Citat, anteckning, färgens namn och sidnummer. Filter för färg, Med anteckning, kurs och sökning. Färgernas namn (Namnge färgerna) gäller alla böcker och blir filter och Anki-taggar.
* **Läsvecka (K10):** läsloggen räknar tiden på sidan som syns (minst 4 s, högst 5 min i taget) och sparar högst en gång i minuten. Kortet överst i biblioteket: sju staplar, veckans lästid, sidor och läst N av 7 dagar, valfritt dagsmål som en ring. Inga svitar, inga notiser, ingen tid kvar. Lästa delar mörkare på tidslinjen, och i Innehåll står läst eller hur stor del av kapitlet som lästs (i EPUB när kapitlens sidor är mätta).
* **Export till Anki (K5):** anteckningsbokens meny. Två textfiler med Ankis rubrikrader och fasta id: markeringarna som lucktext och de sparade orden. Anteckningstypen väljs i Ankis importruta (Lucktext och Grundläggande). Ingen AnkiMobile-knapp.
* **Anteckningar bredvid texten (K12):** Mer, Anteckningar bredvid texten. En panel vid högerkanten OVANPÅ sidan, så att sidans storlek och vikningen är orörda. En anteckning per sida (PDF) eller kapitel (EPUB). Syns i anteckningsboken.
* **Begrepp (K8, första versionen):** knappen Begrepp i markeringsraden gör en term med definition (anteckningen eller markeringen som förslag). Mer, Begrepp listar bokens begrepp, och ett tryck söker efter termen i boken. Ingen karta.
* Databasen: steg 6 `book_info`, 7 `reading_log`, 8 `page_notes`, 9 `concepts` i markeringar.sqlite. Färgernas namn och dagsmålet i `meta`. Allt följer med i säkerhetskopian. Ingen synk, inget i Windows-appen.

## 7. Bygge och installation

1. Claude Code skriver koden på Windows och pushar till `main`.
2. Workflow `iOS build` (`.github/workflows/ios-build.yml`) kör på `macos-26`: XcodeGen (låst version), sedan `xcodebuild archive` utan signering, sedan packas `Lasa-unsigned.ipa` som artefakt, och arkivets dSYM som `Lasa-dSYM`. Ändringar som bara rör `docs/` eller `.md`-filer bygger inte.
3. Vid fel läser Claude Code loggen med `gh run view --log-failed` och rättar.
4. Edvin laddar ner artefakten, installerar med Sideloadly (gratis Apple-ID). AltStore kan förnya automatiskt var 7:e dag över wifi.

Begränsningar med gratis Apple-ID: appen går ut efter 7 dagar, högst 3 egna appar per enhet. Betalt utvecklarkonto (99 USD per år) tar bort båda.

Det finns ingen iOS 15-simulator på byggservern. Allt som beror på iOS 15 testas på iPaden.

## 8. Faser

Varje fas är klar först när Edvin har testat den på iPaden (fas 5 på Windows-datorn).

| Fas | Innehåll | Klar när |
|---|---|---|
| 0 | Byggflöde, bibliotek, PDF med pappersvikning, läsposition | En PDF går att öppna och bläddra i på iPaden |
| 1 | PDF klar: innehållsförteckning, hoppa till sida, zoom, teman för bakgrund | Edvin kan läsa en hel kursbok i PDF |
| 2 | Ordboken: Python-skript, databas, tryck på ord i PDF, popup, SO-knapp, sparade ord, haptik | Testlistan ger rimliga svar och popupen öppnas på under 150 ms |
| 3 | EPUB och textfiler med pappersvikning, typsnitt och storlek, ordfunktion i EPUB | En EPUB-roman läses utan hack |
| 4 | Markeringar, anteckningar, bokmärken, sök, bläddringsljud | Allt sparas och överlever omstart |
| 5 | Windows-appen: bibliotek, PDF och EPUB och text, ordruta, sparade ord, teman, visning och zoom för PDF. Byggd 7 november 2026 på grenen `fas5`, väntar på Edvins test | Kurslitteratur i PDF och EPUB läses på datorn med ordfunktion |
| 6 | Synk, AI-knapp, repetition av sparade ord | Läsposition och sparade ord följer med mellan iPad och dator |

### Synk (fas 6)

* Bokfilerna ligger i en mapp i iCloud Drive. Den nås från iPaden via Filer och från Windows via iCloud för Windows.
* Läsposition, markeringar och sparade ord synkas via Supabase (gratisnivån). Projektet pausas efter en veckas inaktivitet, data finns kvar.
* Böcker identifieras med en hash av filens innehåll, inte med filnamnet.

## 9. Risker

| Risk | Hantering |
|---|---|
| EPUB med pappersvikning är svårt | Bygg det som en isolerad navigator. Prototyp först, mät minne och bildfrekvens på iPaden. |
| Framtida Xcode höjer lägsta iOS över 15 | Lås Xcode-versionen i workflowen med `xcode-select` på en version som stöder 15. |
| Ögonblicksbilderna av webbvyn är för långsamma på A8X | Sidorna görs i förväg, högst fem. Tiderna visas under Text i läsaren. Hjälper inte det: färre förritade sidor under vikningen, eller lägre upplösning. |
| Gemini gratisnivå ändras | AI-knappen är ett tillägg. Allt annat fungerar utan den. |
| Långsam utvecklingsloop utan Mac | Små steg, en sak per push. Skärmbilder från simulator i CI när det behövs. |

## 10. Öppna frågor

* Slutligt namn på appen. Edvin funderar och återkommer.
