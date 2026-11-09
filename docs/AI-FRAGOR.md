# AI-frågor: frågor för läsförståelse i alla böcker (K6b)

Frågorna i marginalen (K6) kommer i dag bara ur en frågefil som görs på datorn. K6b låter appen själv göra frågorna med Gemini, kapitel för kapitel, i vilken bok som helst. Samma upplägg på iPaden och i Windows-appen. Den här filen är kravet för båda.

## Edvins beslut (9 november 2026)

* Frågorna ska finnas i alla böcker han läser, även facklitteratur, på iPaden och i Windows-appen.
* Han svarar ur minnet med egna ord. Bokens citat är aldrig det han mäts mot: det är appens dolda kontroll och syns först efter svaret, som knappen Visa i boken.
* Det ska finnas frågor som kräver större kopplingar än boken: till andra böcker han läst, till verkligheten, följder, var idén slutar gälla, överföring till andra områden, debatt och en syntes vid bokens slut.
* Gratisnivån med hans vanliga nyckel räcker. "Det spelar ingen som helst roll att böckerna hamnar hos google." Hela kapitlets text får därför skickas till Gemini. Det gäller bara K6b: Förklara kapitlet (A2) skickar fortfarande aldrig kapitlets text.
* En frågefil från datorn går före. Har boken en frågefil görs inga AI-frågor i den.
* Allt ligger under av- och påvalet Frågor i marginalen. Under det finns valet Gör frågor med AI, påslaget från början.

## När frågorna görs

* Bara när Frågor i marginalen och Gör frågor med AI är på, boken saknar frågefil och det finns en nyckel.
* När ett kapitel visas och saknar frågor görs det kapitlets frågor i bakgrunden, och sedan nästa kapitels. En fråga till Gemini åt gången i hela appen, i en kö.
* Fliken Frågor har knappen Gör frågor till hela boken: resten av kapitlen i läsordning, med förlopp, Avbryt och fyra sekunders paus mellan anropen.
* Ett kapitel som redan har frågor skickas aldrig igen. Gör nya frågor till kapitlet (i fliken Frågor, med en bekräftelse) byter ut kapitlets frågor, och de gamla svaren hör då inte längre till någon fråga.
* Modellen är inställningen för AI (`GeminiClient.model` på iPaden, `aiModel()` i Windows). Typen i de sparade svaren är `fragor-1` och `jamfor-1`. Tidsgränsen för ett kapitel är 90 sekunder, `maxOutputTokens` 8 192, `temperature` 0,3.

## Kapitlen och texten

* **EPUB och text:** ett kapitel i läsordningen. Texten är kapitlets text utan taggar, samma text som markeringarna räknar i, med stycken åtskilda av en tom rad.
* **PDF:** ett kapitel i innehållet (bokmärkena), som K7. Utan innehåll: tio sidor i taget. Texten är sidornas text i ordning, med en tom rad mellan sidorna. Har boken en textfil från OCR:en (P4, `Bok.txt`) används den för sina sidor. En PDF utan text får inga frågor, och fliken Frågor säger: "Boken har ingen text att göra frågor av. Gör den sökbar först."
* **Nyckel för kapitlet:** `k<kapitlets plats från 0>` för EPUB och text, `p<första sidan>-<sista sidan>` (från 1) för PDF.
* **För korta kapitel:** under 1 500 tecken (omslag, innehåll, tack) får inga frågor. Kapitlet sparas ändå som klart, utan frågor, så att det inte skickas igen.
* **Långa kapitel:** över 40 000 tecken delas i `ceil(längd / 36 000)` lika stora delar, vid närmaste tomma rad (annars radbrytning, annars mellanslag). Varje del är ett eget anrop med egen kontroll, och platserna räknas om till hela kapitlets text.

## Antal frågor

För en del med `n` tecken (samma som `antal()` i `tools/simtest/ai-fragor/referens.py`):

* efter: `min(max(round(n / 3500), 2), 10)`
* fore: 2 om `n` är minst 8 000, annars 1. Bara i kapitlets första del, annars 0.
* kopplingar: 2 om `n` är minst 8 000, annars 1.
* slut: 1 (sammanfatta) plus kopplingarna, plus 1 (syntes) i bokens sista kapitel med text. Bara i kapitlets sista del, annars 0 och kopplingarna 0.
* Tak efter kontrollen: efter högst antalet plus 2, fore högst 2, slut högst 4.

## Frågan till modellen

Frågan byggs tecken för tecken som `bygg_prompt` i `tools/simtest/ai-fragor/referens.py`, och schemat är `SCHEMA_FRAGOR` där (`responseJsonSchema`). Fixturen `tools/simtest/ai-fragor/fixtur-1.json` har den väntade frågan för sina indata (`prompt`), och båda apparna ska bygga exakt samma sträng.

* **Tidigare kapitel:** sammanfattningarna som sparats för bokens tidigare kapitel, i läsordning, högst de tolv senaste.
* **Andra böcker:** högst fem andra böcker som har AI-frågor, de senast lästa först. Per bok titeln, en sammanfattning (de två senaste kapitelsammanfattningarna ihop, högst 400 tecken) och högst åtta begrepp ur deras sparade begrepp. Ingen text ur böckerna.
* Frågetyperna (`typ`) och hur de visas: huvudpoang Huvudpoäng, egna_ord Med egna ord, svar_mening Svår mening, vems_rost Vems röst, varfor Varför, uppgift Styckets uppgift, koppling Koppling bakåt, skillnad Skillnad, tillampa Tillämpa, falla Fälla, belagg Belägg, kritisk Kritisk, anvand Använd det, sammanfatta Sammanfatta, annan_bok Koppling till en annan bok, verkligheten Till verkligheten, foljder Följder, gransen Gränsen, overforing Överföring, debatt Debatt, syntes Syntes.
* Öppna typer (inget rätt svar, Jämför ger en kommentar): kritisk, anvand, annan_bok, verkligheten, foljder, gransen, overforing, debatt, syntes, och varje fråga där modellen satt `oppen` till true.

## Kontrollen

Ren logik, en fråga i taget i modellens ordning. Samma regler som `kontrollera` i `referens.py`, och båda apparna ska ge fixturens `vantat` (vilka som behålls, med id och plats, och varför de andra slängs).

1. `typ` eller `nar` utanför schemat: släng (`typ`).
2. Frågan kortare än 8 tecken: släng (`fraga`). Inga svarspunkter på en fråga som inte är öppen: släng (`svar`).
3. `nar` är efter: `plats` måste hittas i delens text, annars släng (`plats`). Frågans plats är slutet av träffen.
4. `kalla`: hittas den inte och frågan behöver en källa, släng (`kalla`). Hittas den inte i en öppen fråga, töm den och behåll frågan. Tom `kalla` går bara för öppna frågor, sammanfatta och syntes, annars släng (`kalla`).
5. Frågan innehåller sex ord i rad ur texten: släng (`kopierad`). Ord är följder av bokstäver och siffror i den vikta texten, allt annat skiljer.
6. annan_bok, och debatt med en bok angiven: `bok` måste vara en av de andra böckernas titlar (vikt, exakt lika), annars släng (`bok`).
7. Frågorna med efter ordnas efter plats. En fråga närmare än 400 tecken efter förra behållna efter-frågan slängs (`avstand`).
8. Ordningen blir fore (modellens ordning), efter (textens ordning), slut (modellens ordning). Över taket slängs (`tak`).

**Hitta** betyder att den vikta texten (`FoldedText` på iPaden, `fold` i `search.js`: små bokstäver, ett mellanslag mellan orden, mjuka och radslutets avstavningar bort) innehåller det vikta citatet. Hittas det inte görs ett försök till där typografiska citattecken och streck i båda texterna först byts mot raka, ett tecken mot ett (tabellen `LOSA` i referens.py), så att platserna stämmer. Första träffen gäller.

Slängda frågor skrivs aldrig ut, men antalet per orsak loggas (iPaden i `AppLog`, Windows i konsolen), till exempel `AI-frågor k3: 6 av 13 behölls (plats 1, kalla 1, kopierad 1, avstand 1, bok 1, typ 1, svar 1)`.

## Id och lagring

* Frågans id: `"ai" + base36(FNV-1a 64 över UTF-8 av "<bokens id>|<kapitlets nyckel>|<delen från 1>|<nar>|<frågan>")`, samma som `fraga_id` i referens.py (FNV-1a som `BookQuestionFile.stableHash`).
* **iPaden:** steg 13 i trappan i markeringar.sqlite (följer med i säkerhetskopian):
  * `ai_questions (book TEXT, chapter TEXT, part INTEGER, chapter_title TEXT, model TEXT, created REAL, summary TEXT, concepts TEXT, questions TEXT, PRIMARY KEY (book, chapter, part))`. `questions` är de behållna frågorna som JSON (id, typ, nar, fraga, svar, oppen, plats, kalla, bok, position), `concepts` en JSON-lista. Ett för kort kapitel sparas med tom lista.
  * `ALTER TABLE question_answers ADD COLUMN my_answer TEXT NOT NULL DEFAULT ''` och `ADD COLUMN feedback TEXT NOT NULL DEFAULT ''` (Jämförs svar som JSON).
* **Windows:** samma tabeller i bibliotek.sqlite via `statements.json`: `question_answers` (samma kolumner som iPadens steg 10 plus `my_answer` och `feedback`) och `ai_questions`. `book` är bokens eget id (G3) på båda.
* Ingen synk av frågorna i den här omgången: varje enhet gör sina egna.

## Visning

* **Prickarna:** efter-frågorna står som de numrerade prickarna i marginalen, vid platsen, precis som frågefilens frågor. Numret räknas i bokens ordning. Fore och slut får ingen prick.
* **Rutan med en AI-fråga:** rubriken är typens namn (för annan_bok "Koppling till <bok>"), sedan frågan, en ruta Ditt svar (flera rader, platshållaren "Skriv eller diktera ditt svar"), Visa svaret, och Kan, Osäker och Kan inte. Varken platsen eller källan syns innan svaret visas. Efter Visa svaret: punkterna, "Ur boken:" med källan i kursiv och knappen Visa i boken som hoppar dit (iPaden genom `hop(to:)`, så att det kommer med i historiken). Utan källa syns ingen av dem. Jämför med mitt svar syns när det finns en nyckel och något skrivet. Sist en liten rad "Gjord med AI". Det skrivna svaret sparas när rutan stängs och står kvar nästa gång.
* **Frågefilens frågor** ser ut som i dag. Frågefilens format får också de valfria fälten `typ`, `nar` och `kalla` (se `docs/FRAGOR.md`), som då gör samma sak som för AI-frågorna.
* **Före läsningen:** när första sidan i ett kapitel med fore-frågor visas, en gång per kapitel medan boken är öppen, en liten rad överst: "Läs för att ta reda på" med första frågan (förkortad), Visa och Stäng. Visa öppnar kapitlets fore-frågor utan svar.
* **Efter kapitlet:** iPaden tar med kapitlets AI-frågor (fore, efter och slut) i självtestet efter kapitlet (K7), och raden efter kapitlet visas också när kapitlet bara har AI-frågor. Windows har ingen K7: där visas en rad "Kapitlet är slut: N frågor" när man bläddrar förbi kapitlets sista sida, och den öppnar kapitlets slut-frågor och fore-frågorna en i taget.
* **Fliken Frågor:** bokens frågor kapitel för kapitel, med Före läsningen, I texten (sidan eller kapitlet) och Efter kapitlet, och svaret som i dag. Överst en rad om AI-frågorna: hur många kapitel som har frågor av hur många, Gör frågor till hela boken, och beskedet när något hindrar (ingen nyckel med en knapp till nyckelguiden, kvoten slut med klockslaget, ingen text, inget nät).
* **Inställningen:** Gör frågor med AI under Frågor i marginalen (Aa på iPaden, motsvarande ruta i Windows), på från början, bara valbar när Frågor i marginalen är på.

## Jämför

* Frågan byggs som `bygg_jamfor` i referens.py, schemat är `SCHEMA_JAMFOR`. Bara frågan, svarspunkterna, källan och det skrivna svaret skickas, aldrig kapitlets text. Fixturen har två väntade frågor (`jamfor`).
* Resultatet visas i rutan: Med (grön), Saknas (gul), Fel (röd) och kommentaren. För en öppen fråga bara kommentaren och Fel om det finns. `omdome` föreslår ett val (bra Kan, delvis Osäker, saknas_mycket Kan inte) genom att knappen markeras, men Edvin trycker själv. Resultatet sparas i `feedback` med svaret.

## Fel och kvot

* Samma besked som Förklara stycket (`AIClient.Failure`): ingen nyckel, fel nyckel, okänd modell, minutens kvot, dagens kvot med klockslaget, inget nät. Minutens kvot: vänta `retryDelay` (högst 60 s) och försök en gång till. Dagens kvot: kön stoppas, och fliken Frågor säger när den fylls på.
* Ett svar som inte går att läsa försöks en gång till. Går det inte heller sparas inget, och kapitlet försöks igen nästa gång det visas.
* Allt anropas och sparas utanför huvudtråden där det tar tid (iPaden: texten tas fram i bakgrunden, aldrig under en vikning).

## Prov

* **Logiken:** iPaden ett XCTest och Windows ett node-test som läser `tools/simtest/ai-fragor/fixtur-1.json` och kontrollerar frågan, Jämförs frågor, schemana, kontrollens resultat och id:na. Fixturen är det gemensamma facit, så att båda apparna bevisligen bygger samma fråga och behåller samma frågor.
* **iPaden:** självtestet mot `tools/simtest/mock_gemini.py`, som svarar på `fragor-1` med frågor vars platser och källor tas ur den text som skickats, plus en som inte hittas. Läs loggen och bilderna: prickarna, rutan före och efter Visa svaret, Jämför, raden före läsningen och fliken Frågor.
* **Windows:** e2e med `dev/server.py` och Gemini-anropen fångade i testet (Playwright `route`), aldrig mot Google.
* Inget prov mot riktiga Gemini utan Edvins ja.

## Inte nu

Synk av frågor och svar mellan enheterna, K7 på Windows, frågor i fotade PDF:er utan text, uppläsning.
