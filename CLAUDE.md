# CLAUDE.md

Sensus (tidigare Läsa, arbetsnamnet finns kvar i filnamn, mappar och nycklar) är en läsapp för iPad och iPhone (Swift, UIKit) med pappersvikning som i Apple Books och en offline ordfunktion. Windows-versionen (fas 5, Tauri) ligger i `windows/`, se `windows/README.md`. Hela specen finns i `docs/SPEC.md`. Läs den innan du börjar på en ny fas.

## Viktigast att veta

* **Det finns ingen Mac.** Edvin kör Windows. Swift går inte att kompilera lokalt. Allt iOS-bygge sker i GitHub Actions.
* **Huvudenheten är en iPad Air 2 med iPadOS 15.8.3.** Lägsta version är iOS 15.0. Använd inga API:er som är nyare utan `if #available` och en fallback. Den har 2 GB RAM och en A8X, så prestanda och minne spelar roll.
* Edvin kör Claude Code i desktopappen. Ge instruktioner för desktopappen och webbläsaren, inte terminalkommandon som han ska skriva själv.

## Arbetsloop

1. Gör en avgränsad ändring.
2. Commit och push till `main`.
3. Följ bygget: `gh run watch` (eller `gh run list --workflow "iOS build" --limit 1`).
4. Om det misslyckas: `gh run view <id> --log-failed`, rätta, pusha igen. Ge inte upp efter ett fel, men om samma fel kommer tillbaka tre gånger: stanna och förklara för Edvin vad som är fel.
5. När bygget är grönt: säg till Edvin att ladda ner artefakten `Lasa-ipa` från körningen, och skriv exakt vad han ska testa på iPaden (2 till 5 punkter).

Pusha inte flera orelaterade ändringar i samma commit. Varje runda tar flera minuter, så små och säkra steg går snabbast.

### Windows-appen

1. Provkör gränssnittet först i Chrome: `windows/dev/server.py` svarar på samma kommandon som Rust-delen, och `windows/tests/e2e.py` provar det mesta (se `windows/README.md`). Det finns ingen Rust på datorn.
2. Push startar `Windows build` (bara när `windows/`, `tools/dictionary/` eller workflowfilen ändras). iOS-bygget hoppar över ändringar som bara rör `windows/`, `docs/` eller `.md`-filer.
3. Följ bygget: `gh run list --workflow "Windows build" --limit 1`, fel med `gh run view <id> --log-failed`. Samma regel om tre fel som ovan.
4. När bygget är grönt: Edvin laddar ner artefakten `Lasa-windows` och kör filen som slutar på `-setup.exe` (osignerad: Mer info och Kör ändå).
5. Synken på Windows (`windows/src/js/sync.js`) följer `docs/SYNK.md` och iPadens `App/Sync/SyncEngine.swift`. Ändras protokollet ska båda ändras. Provas med `windows/tests/e2e_sync.py` mot `windows/tests/mock_supabase.py`.
6. Användarens databaser nås bara via namngivna frågor i `windows/src-tauri/statements.json` (`db_read`, `db_write`). En ny fråga eller kolumn läggs där, aldrig som SQL i JavaScript. Tabellerna skapas och kolumner läggs till när appen startar (bara `IF NOT EXISTS` och `ADD COLUMN`). `statements.test.mjs` kontrollerar.
7. Kopior som ska följas åt: repetitionen (`App/Dictionary/UserWords.swift` och `windows/src/js/review.js`, där `review.test.mjs` läser Swift-koden och går sönder om schemat ändras), AI-knappen (`GeminiClient.swift` och `windows/src/js/gemini.js`) och sökningens vikning (`FoldedText` och `windows/src/js/search.js`). Ändras den ena ändras den andra i samma commit.
8. Markeringar och bokmärken på Windows ligger i `bibliotek.sqlite` med samma kolumner som `markeringar.sqlite`. `book` är bokens eget id (G3, ett UUID som aldrig ändras), inte SHA-256. Kontrollsumman ligger i `books.sha256`, bokfilerna heter `<sha256>.<ext>`, och synken skickar sha256 som `book_id` (`contentId` i `store.js`). Matchningen vid import ligger i `windows/src/js/bookmatch.js` med samma regler som `BookMatcher` på iPaden: ändras den ena ändras den andra. Engångsflyttar ligger under `moves` i `statements.json` och körs av både `main.rs` och `dev/server.py`. PDF räknar tecken i pdf.js text (inte PDFKit), EPUB i kapitlets text som på iPaden. Ingen synk av markeringar ännu. `moves` har två engångssteg: G3 och de borttagna böckerna (fynd 5 i nattens granskning), där varje kontrollsumma i `book` utan bokrad får en rad med `missing = 1`, så att samma fil ger `restore` när den läggs till igen. Ett nytt engångssteg läggs sist med egen `pending`, eftersom ett tidigare stegs `pending` redan kan vara 0.
9. `windows/tests/e2e_fas7.py` provar markeringar, sök, repetition, AI-knappen och uppslag. `node --test windows/tests/*.test.mjs` körs i bygget. En ändring i `.github/workflows/windows-build.yml` startar också iOS-bygget. `windows/tests/e2e_fas8.py` provar G3 (påhittade gamla data och importfrågorna) och W10 (Rulla och Bläddra), och startar själv `dev/server.py` på port 8963 med egna datamappar.
10. Namnet är Sensus i fönstret och texterna, men `productName` ("Läsa"), `identifier` (`se.edvin.lasa`) och datamappen är oförändrade, så att installationen ersätter den gamla. Byt inte `productName` utan Edvins ja, det kan ge en andra installation.

## Projektet

* `project.yml` är källan för Xcode-projektet (XcodeGen). Lägg nya Swift-filer under `App/`, de tas med automatiskt. Ändra aldrig en `.xcodeproj` för hand, den checkas inte in.
* `Config/Info.plist` är appens Info.plist. Den ligger utanför `App/` med flit, så att den inte kopieras som resurs.
* Swift språkläge 5 (`SWIFT_VERSION: 5.0`). Klasser som rör UI ska vara `@MainActor` eller vara UIKit-subklasser.
* Paket läggs till under `packages:` i `project.yml`. Lås alltid versionen och kontrollera att paketets lägsta iOS är 15 eller lägre innan du lägger till det.

## Mappar

```
App/
  AppDelegate.swift, SceneDelegate.swift
  Books/       EPUB och textfiler: zip, XML, uppackning, omvandling till HTML-kapitel
  Library/     bibliotek, import, lagring
  Reader/      läsare, rendering, pappersvikning (PDF och, med Reflow i namnet, EPUB och text)
  Dictionary/  ordboken, ordet under fingret, ordrutan, sparade ord
  Annotations/ (fas 4) markeringar, anteckningar, bokmärken, sökning och deras rutor och listor
  Settings/    (fas 6) inställningar och nyckelringen
  Sync/        (fas 6) synken med Supabase och böckernas id (SHA-256 av filen)
  Support/     haptik och små hjälpare
  Resources/   lasa-ordbok.sqlite läggs här av bygget, checkas inte in
Config/Info.plist
docs/SPEC.md
tools/dictionary/   (fas 2) Python som bygger ordboksdatabasen
tools/simtest/      (fas 3) testböcker och skriptet som kör självtestet i en iPad-simulator
Tests/LasaTests/    automatiska tester av ren logik (XCTest), körs sist i Simulatortest
windows/            (fas 5) Windows-appen: src/ (HTML, CSS, JavaScript), src-tauri/ (Rust), dev/, tests/
.github/workflows/ios-build.yml
.github/workflows/windows-build.yml
```

## Regler för läsaren

* Bläddring sker med `UIPageViewController(transitionStyle: .pageCurl)`. Stående: en sida, ryggen till vänster. Liggande på iPad: uppslag, ryggen i mitten, omslaget ensamt till höger. Edvin har godkänt vikningens känsla. Ändra den inte, och byt inte övergång, om han inte ber om det.
* Ingen rendering på huvudtråden, varken under en vikning eller annars. Sidbilder kommer bara via `PDFPageRenderer`, som ritar i bakgrunden med ett eget `PDFDocument`. Läsarens dokument används bara på huvudtråden.
* Håll minnet nere: högst 5 renderade sidbilder (även i uppslag), högst 3 webbvyer för EPUB.
* Sidans placering och renderingsstorlek får bara bero på vyns storlek och läsarens fasta marginaler, aldrig på om menyraden eller statusfältet syns. Använd inte vyns `safeAreaInsets` för sidan, de ändras med menyraden.
* Haptik går genom `Haptics.shared`. iPad har ingen vibrationsmotor, där händer inget, och det är förväntat.
* Det som är lika i PDF- och EPUB-läsaren ligger på ett ställe (G12): menyraden i `ReaderChrome`, hållgestens tider, avbrytandet av vikningen och bubblan i `WordPressGesture` och `WordBubble`, markeringslägets gester och rad i `MarkMode`. Ändra där, inte i läsarna.
* Färgerna (U1) kommer ur `Theme` (`App/Support/Theme.swift`): en `Palette` med token (canvas, surface, page, ink, accent, ribbon med flera) per bakgrund i `ReaderTheme` (Papper är förvalt). Hårdkoda inga färger i nya vyer, läs `Theme.current`. `Theme.apply()` målar fönstret, systemets tabeller och menyrader och skickar `Theme.didChange`. Rubriker, boktitlar och citat i New York (`Theme.serif`).
* Menyraden (U3): vänster Innehåll (bredvid tillbaka), mitten titel och kapitel, höger Sök, Markera, Aa och Mer. Aa är `AppearanceViewController` (U2) i båda läsarna. Bokmärket är bandet i sidans hörn: läsarnas `ribbonTap` går före kanttrycket, och sidorna har `ribbonZone` och `showsRibbonHint`.
* Utseendet i EPUB och text (U2): marginal, radavstånd och justering ligger i `ReaderTypography` och ingår i `key` (nyckeln för sparade sidantal). Radlängden begränsas i CSS (`max(sidmarginal, (100vw minus 29,5 em) / 2)` med Normal, ungefär 66 tecken), kolumn plus mellanrum är alltid 100vw.
* Läsvyn (våg 6): Tillbaka och historiken (V4) är `ReaderBackStack` i `ReaderNavigation.swift`. Varje hopp som användaren gör ska gå genom läsarens `hop(to:)`, aldrig direkt till `jump(to:)`, annars kommer det inte med i historiken. Nederkanten är tidslinjen `ReaderTimeline` (V2, samma gränssnitt som `UISlider`): linjen ritas bara när kapitel, markeringar eller bokmärken ändras, markören är ett lager. Sidor kvar (V1, `PageInfo`) visar aldrig tid. Miniatyrerna (V3, `PDFThumbnailsViewController`) ritas med `PDFPageRenderer.thumbnail` på lägsta prioritet. Fotnoter (V5) i `NotePopover.swift`, Här var du (V6) i `ReaderResumeCard.swift`.
* Tryckzonerna (8 nov) ligger i `ReaderTapZones` (`WordPressGesture.swift`, G12): bläddring i ett kantband om 18 procent av bredden (56 till 110 punkter), resten är menyn. Ändra där, inte i läsarna.
* EPUB och text: marginalen upptill och nedtill (`makeLayout`) rymmer menyradens fasta höjd (`navigationBarHeight`) och nederkantens (`ReaderBottomBar.height`), så att menyn bara ligger över marginalen. Fasta mått, aldrig menyns läge.
* Accenten i `Theme` är neutral grå (Edvin 8 nov, som Apple Books), inte blå. Vitt sätter textfärg i EPUB. Efter en ändring i Aa kontrollerar `watchVisiblePages` att bladen får nya bilder och skriver annars i `AppLog`. Självtestet gör ändringarna via rutan med rutan öppen och räknar bläck (`SelfTest.inkPercent`).
* EPUB-läsarens webbvyer har alltid ljust läge (`overrideUserInterfaceStyle = .light` i `ChapterView`). Bytet mellan Vitt och Mörkt slog annars om ljusläget i alla tre webbvyerna samtidigt, kapitlet hann inte bli klart på iPaden och sidan blev blank för gott (Edvin 8 nov kväll). Färgerna sätts bara av `ReflowStyle`. `SnapshotInk.isBlank` räknar både bara papper och en enda färg (även helt genomskinligt) som tom, och en tom sidbild tas om efter 0,5, 1 och 1,5 sekunder.
* Markeringsraden (U5, `HighlightMenuViewController`) pekar på markeringens hela ruta (`markRects(id:)` på sidorna) och läggs ovanför den, eller under när det inte finns plats.

## EPUB och textfiler (fas 3)

* Inget Readium. `App/Books/` packar upp EPUB med en egen zipläsare och läser OPF, nav och NCX med `XMLTree`. Textfiler görs om till HTML-kapitel av `TextBookConverter`.
* Varje kapitel ligger i en dold `WKWebView` (`ChapterView` i `ReflowRenderer.swift`) med CSS-kolumner. Bladen i vikningen är ögonblicksbilder. Webbvyerna får aldrig synas eller ta tryck, de ligger under `paperCover` i läsaren.
* Högst 3 webbvyer och högst 5 sidbilder. Ett jobb i taget per webbvy, med en vakt som laddar om kapitlet efter 8 sekunder utan svar.
* Skripten i webbvyn (`ReflowStyle.script`) körs i en egen JavaScript-värld (`.defaultClient`) och anropas med `callAsyncJavaScript`.
* Ordfunktionen i EPUB använder ordboken på ett enda ställe: `presentWord` i `ReflowReaderViewController.swift`. Hållgesten är densamma som i PDF (ordet närmast fingret, bubbla, rutan öppnas när man släpper). Ordet hittas i den dolda webbvyn med `lasa.wordAt`, ett uppslag i taget.
* Simulatortestet (jobbet Simulatortest) bygger appen för en iPad-simulator och startar den med `-LasaSelfTest <fil>`. Läs loggen och bilderna i artefakten Simulatortest efter varje ändring i läsaren, innan Edvin får något att testa. Simulatorn kör en nyare iOS än iPaden, och iOS 26 nekar appen att vrida skärmen, så självtestet gör läsarens yta bred för att pröva uppslag. Tider och minne gäller en Mac, inte iPaden.

## Markeringar, bokmärken och sök (fas 4)

* Allt sparas i `markeringar.sqlite` under Application Support (`AnnotationStore`). Böckerna känns igen på sitt id i bokregistret (G3, se Grunden), inte på filnamnet. Inget raderas: borttaget får `deleted = 1` och ny ändringstid, för synken.
* Båda databaserna (`markeringar.sqlite`, `anvandarord.sqlite`) har ett versionsnummer (`PRAGMA user_version`) och en trappa av uppdateringar (`migrations` i `AnnotationStore` och `UserWords`, körs av `SQLiteDatabase.migrate`). Ett nytt fält blir ett nytt steg sist, ändra aldrig ett steg som redan finns. Varje skrivning går i en transaktion, och ett fel skrivs i loggen och visas för användaren (`SaveProblems`).
* En markering är `section` plus ett teckenintervall i UTF-16. PDF: sidan och `PDFPage.string`. EPUB och text: kapitlet och kapitlets text (all text i body utom script och style). `text` sparas också, och skriptet letar upp markeringen via texten om platsen inte stämmer.
* Markeringsläget (pennan): sidans vikning, menyn och ordfunktionen stängs av, och en `UILongPressGestureRecognizer` med tiden 0 följer fingret. Ett vanligt tryck på en markering öppnar `HighlightMenuViewController`.
* PDF: markeringarna ritas som vyer ovanpå sidbilden i `PDFPageViewController` (ingen omritning av sidan). EPUB: `ReflowMarks.script` lägger span-element runt texten i den dolda webbvyn och sidan fotograferas om. `lasa.showPage` lämnar markeringarnas rutor, så att tryck på en markering hittas utan webbvyn.
* Sökningen (`BookSearch`) går i bakgrunden: PDF med ett eget `PDFDocument`, EPUB i kapitelfilerna utan taggar. Sökträffen i EPUB letas upp i webbvyn med samma vikning (`FoldedText` i Swift, `fold` i skriptet), n:te träffen med texten runt som kontroll.
* Sökregistret (G11, `SearchIndex`): bokens text per avsnitt i `sokregister.sqlite` (egen trappa, inte i säkerhetskopian), nyckel bokens id plus en version ur filen. FTS5 med trigram om SQLite har det, annars `instr`. Registret väljer bara avsnitten, träffarna räknas ur originaltexten med `BookSearch.find`, så platserna blir desamma. Saknas eller är det gammalt söks direkt i boken och det byggs om. Höj `SearchIndex.formatVersion` när texten tas fram på ett nytt sätt.
* Bläddringsljudet räknas fram i appen (`PageTurnSound`), ingen ljudfil. Spelas när en vikning börjar. Slås av och på i Inställningar (U2), inte i läsarens menyer.
* Självtestet provar allt detta i alla testböcker, även en PDF (`test.pdf` från `make_books.py`).

## Fas 6: repetition, AI-knappen och synk

* Repetitionen (`WordReviewViewController`, schemat i `UserWords.swift`) ligger i `anvandarord.sqlite`: tabellen `reviews`, och `deleted_words` för borttagna ord (synken behöver dem). Signaturerna för `UserWords.save`, `WordDictionary.lookup` och `WordPopupViewController.present` är oförändrade.
* U6 (9 nov): repetitionen är ett kortläge med filter per bok eller kurs (`ReviewFilter`, sparat som `review.filter` i UserDefaults). Svårt ger alltid kortare tid än Bra (nytt ord: 10 min, 6 tim, 1 dag, 4 dagar). Småord sparas aldrig (`ReviewStopWords`, samma listor i `review.js`), och ord utan svar i ordboken (`ReviewAnswers`, svaret sparas i minnet) hamnar inte i kön. Kortet Repetera i biblioteket är avsnittet `study` (`StudyCards.swift`, `StudyItem`). Ingen tid för omgången, bara antal ord.
* Uppläsningen togs bort 8 november 2026 (Edvin tyckte att iOS röster lät som en robot). Ett bättre alternativ undersöks senare. Lägg inte tillbaka den utan att han ber om det.
* AI-knappen (`GeminiClient`) använder `generateContent` med `responseJsonSchema`. Modellen får bara välja bland ordbokens betydelser och ord, och ord den hittat på själv visas inte. Nyckeln ligger i nyckelringen, modellen är en inställning (från början `gemini-3.5-flash-lite`, gratis enligt Googles prissida 7 november 2026). Gratisnivåns data får användas av Google, det står i Inställningar.
* Synken (`SyncEngine`, `SyncClient`) och protokollet beskrivs i `docs/SYNK.md`. Tabellerna i `tools/supabase/schema.sql`. Inga nycklar i koden: adressen i UserDefaults, nyckel och inloggning i nyckelringen.
* Självtestet `-LasaSelfTest fas6` provar repetitionen, AI-tolkningen och synken mot `tools/simtest/mock_supabase.py`. Läs `fas6.log` och `mock-supabase.json` i artefakten Simulatortest.
* Förklara stycket (A1, våg 8b, `App/Annotations/PassageExplain.swift`) och nyckelguiden (U7, `App/Settings/AIKeyGuideViewController.swift`) går genom `AIClient` (`App/Dictionary/AIClient.swift`): sparade svar och dagens anrop i `ai-svar.sqlite` (egen trappa, en cache som inte ingår i `Backup`), begripliga besked för saknad eller fel nyckel och kvot (429 delas på `quotaId` PerDay och minutens `retryDelay`). Bara stycket (EPUB) eller meningen med två före och två efter (PDF), högst 2 400 tecken, med bokens titel och kapitlet. Svaret läggs som anteckning UNDER en egen anteckning, aldrig i stället. Ordknappens fråga och svar är oförändrade, den räknas bara bland dagens anrop. Självtestet `-LasaSelfTest ai` mot `tools/simtest/mock_gemini.py` (nyckeln väljer svaret: mock-ok, mock-bad, mock-quota-day, mock-quota-minute), läs `ai.log` och `mock-gemini.json`.
* Den osignerade appen i simulatorn kan inte skriva i nyckelringen (`SecItemAdd` svarar -34018). `Keychain` håller då värdet i minnet tills appen stängs, så självtestet fungerar ändå. På iPaden signerar Sideloadly appen och nyckelringen används.
* Simulatorn kör iOS 26: popovers och vissa knappar ritas som glas och kommer inte med i självtestets egna bilder (`drawHierarchy`). Kontrollera sådant i loggen (till exempel antalet träffar) eller i skärmbilderna från `simctl`, inte i appens bilder.

## Grunden (våg 1, 8 november 2026)

* Loggen: `AppLog` skriver `Documents/Diagnostik/logg.txt`, som syns i Filer. Nya fel och tider loggas där, kort och utan text ur böckerna. Apples MetricKit-rapporter sparas i `Diagnostik/MetricKit` (`DiagnosticReports`). Inställningar har Dela loggen, och Simulatortest lägger loggen i artefakten (`Diagnostik/`).
* Säkerhetskopian: `Backup` sparar en kopia per dag i `Documents/Säkerhetskopia/<datum tid>/` (båda databaserna med SQLite:s backup, läspositionerna ur UserDefaults som JSON) och behåller dagens kopior och för tidigare dagar den nyaste av varje slag, de sju senaste dagarna (se Biblioteket). Kopian före en flytt av data ligger i `Före uppdateringen <datum tid>/` och rensas aldrig, och rensningen rör aldrig kopian som just återställts. Efter en återställning är synken pausad tills den startas igen i Inställningar. Ny användardata (en ny databas, nya nycklar i UserDefaults) ska också in i `Backup`.
* Utgångsvarningen: `AppExpiry` läser utgångsdatumet ur `embedded.mobileprovision` och visar en rad i biblioteket två dagar före. Simulatorn har ingen profil.
* Bokregistret (G3, våg 2): tabellen `books` i `markeringar.sqlite` (`BookRegistry`) ger varje bok ett eget id med kontrollsumma (SHA-256, samma som synkens book_id), sökväg i Böcker och titel. Markeringar, bokmärken, läsposition (`bookPosition.<id>`, `bookLocation.<id>`, `bookPositionDate.<id>` i UserDefaults) och sparade ord (`book_id`) hänger på id:t. Matchningen är ren logik i `BookMatcher` (testad i XCTest). Gamla nycklar under filnamnet flyttas en gång av `LegacyBookMigration`, med en säkerhetskopia precis före. Böcker i undermappar syns.
* Import (G10, `BookImporter`): i bakgrunden genom `NSFileCoordinator`, flytt när systemet redan gjort en kopia, kontrollsumman i samma läsning, förlopp under listan i biblioteket och frågan Ersätt eller Behåll båda vid upptaget namn.
* PDF-markeringarnas rutor sparas med markeringen (G6, kolumnen `rects`), och PDF-läsaren läser in bokens markeringar en gång. Ingen PDFKit-text eller databasfråga när en sida viks fram.
* Sidbilder på disk (G5, `PageDiskCache`): `Library/Caches/Sidbilder/<bokens id>-<storlek>-<ändringstid>/<storlek>@<skala>-<tema>/<sida>.jpg`, högst cirka 300 MB, äldst bort först. De närmaste tio sidorna åt varje håll förritas till disken på lägsta prioritet. Simulatortestet har en fotad PDF (`foto.pdf`) som mäter ritad mot från disken.
* Fel vid sparning visas av `SaveProblems` (se fas 4). Ren logik får ett test i `Tests/LasaTests`. XcodeGen är låst (`XCODEGEN_VERSION` i workflowen), och arkivets dSYM sparas som artefakten `Lasa-dSYM`.

## Biblioteket (våg 4, 8 november 2026)

* Rutnät med omslag (`LibraryViewController`, `UICollectionViewCompositionalLayout`, celler i `LibraryCells.swift`, logiken i `LibraryModel.swift` med XCTest). Steg 4 i trappan: `books` har titel och författare ur filen, egna (Byt namn), omslagets fil, vald omslagssida, andel läst, Markera som läst och var man är. `BookRegistry.insert` är en upsert av grundfälten: skriv aldrig `INSERT OR REPLACE INTO books`, den tömmer de nya fälten.
* Omslagen (`CoverStore`, `BookFileReader` i `BookCovers.swift`) ritas i bakgrunden, en bok i taget, till `Library/Caches/Omslag/`. Bara sidan som valts i Välj omslag sparas i registret. Läsarna skickar `ReadingStatus` i `updatePageLabel`. Ingen tid kvar någonstans (Edvins beslut), bara sidor och sidor kvar.
* Kurser (B3, steg 5): `courses` och `course_books` (`CourseStore`, `CourseLogic` i `Courses.swift`). En översta undermapp i Böcker blir en kurs av sig själv, en borttagen kurs skapas inte igen. Ingen synk av kurserna (F1 bygger om synken). Sidopanelen (`LibrarySidebar.swift`) ligger fast i liggande på iPad, är en ruta i stående och ett ark från flikraden på iPhone (U9).
* Första start (B5, `Onboarding.swift`): välkomstsidan bara när det inte finns böcker, markeringar, ord eller läspositioner. Exempelboken är Markdown i koden och skrivs till Böcker, och `OnboardingTips` bockar av stegen i läsaren. Öppningen från omslaget (U10) är `BookOpenTransition`, före och efter läsaren, aldrig i vikningen. `LibrarySelfTest` (i fas 6) provar biblioteket och fotograferar det i stående, liggande, iPhone-bredd, tomt och första start.
* Säkerhetskopiorna (granskning 2): i dag sparas alla kopior (högst tio), tidigare dagar den nyaste av varje slag (automatisk, egen, före återställning). Synkens paus efter en återställning sparas (`sync.pausedAfterRestore`) och hävs bara i Inställningar. En platshållare eller borttagen bok på samma plats ger frågan Ny version, också vid import. Bokmärkesbandet tar bort med Ångra (`UndoBar`).
* Ta bort (`LibraryStore.delete`, D3-5) tar bort filen men lämnar läspositionen och dess tid kvar, liksom markeringarna och registrets sida och andel, så att samma fil som läggs in igen öppnas där man var. Windows gör likadant.

## Plugget (våg 7, 8 november 2026)

* Bokens sidnummer (K2) kommer bara ur `BookPageNumbering` (`App/Annotations/BookInfo.swift`). Visa aldrig PDF:ens egen sidetikett direkt, gå via läsarens `printedLabel` eller `citationPage`. Inställningen och bokinfon (K3) ligger i `book_info` (steg 6) genom `BookInfoStore`.
* Sidnumren i citat (granskning 4): ett citat får aldrig en sida som inte bevisligen är bokens. `page_first` 0 är inte valt (citatet får ingen sida), -1 filens nummer är bokens, -2 PDF:ens sidetiketter, större än 0 förskjutningen. Filnamnets intervall gäller av sig självt bara när sidantalet stämmer exakt, och läsaren sparar det automatiska valet första gången boken öppnas, så att ett nytt filnamn inte räknar om sidorna. Tryckta sidnummer i textlagret (`PrintedPageNumbers`) är bara ett förslag att bekräfta. I uppslag står den jämna sidan till vänster (`spreadStart`).
* Citaten (K3) i `Citations.swift`, anteckningsboken (K1) och färgernas namn (`HighlightColorNames`, i `meta`) i `Notebook.swift`, Anki (K5) i `AnkiExport.swift`, begreppen (K8, steg 9) i `Concepts.swift`, anteckningarna bredvid texten (K12, steg 8) i `App/Reader/SideNotes.swift`. Panelen ligger ovanpå sidan, läsarnas `shouldReceive` släpper inte igenom tryck i den.
* Läsloggen (K10, `App/Library/ReadingLog.swift`, steg 7): läsarna anropar `ReadingLog.shared.pageShown` i `updatePageLabel` och `pause` när läsaren stängs. Den skriver högst en gång i minuten, aldrig vid varje sidvändning. Dagen räknas i lokal tid. Kortet Läsvecka är avsnittet `week` i biblioteket. Ingen tid kvar.
* Logiken testas i `Tests/LasaTests/StudyTests.swift`, även att en databas i formen före våg 7 går genom stegen 6 till 9. Självtestet (`selfTestStudy` i PDF-läsaren) fotograferar citatrutan, begreppen, panelen, anteckningsboken och tidslinjen (`12*`).

## Ordboken (fas 2)

* Offline SQLite, byggd av `tools/dictionary/build.py` från Synlex, Swesaurus, SALDO, Open English WordNet och Folkets lexikon. Se licenser i specen och `tools/dictionary/README.md`.
* Bygget i molnet har två jobb: Ordboken (Linux, bygger databasen och testrapporten) och Appen (Mac, lägger databasen i `App/Resources` före XcodeGen). Källfilerna och databasen sparas i Actions cache, så databasen byggs bara om när skripten eller testlistan ändras.
* Uppslagslogiken finns tre gånger: `App/Dictionary/WordDictionary.swift`, `tools/dictionary/lookup.py` (som testrapporten använder) och `windows/src/js/lookup.js` (Windows-appen). Ändras en ska de andra ändras i samma commit. `windows/tests/parity.mjs` jämför lookup.js med lookup.py över testlistan och körs i Windows-bygget.
* Ord slås upp när fingret hålls stilla på ordet i 0,35 s (`wordPressDuration`). Ordet närmast fingret markeras (inte ordet till vänster), en bubbla ovanför fingret visar ordet, markeringen följer med om man drar, och rutan öppnas först när man släpper. Ett vanligt tryck i mitten är fortfarande menyn, och i kanterna bläddring.
* Rutan visar ett tydligt svar överst: för engelska den svenska översättningen (lånad från en synonym om ordet saknas i Folkets lexikon), för svenska definitionen ur Folkets lexikon och de vanligaste synonymerna. Övriga betydelser och ordklasser ligger bakom ett tryck. Edvin tyckte att den första rutan var förvirrande (7 november 2026).
* Ordkortet (U4, våg 5): `WordPopupViewController` är egna vyer, ingen tabell: ordet i New York med ordklass och SV eller EN, svaret i stor stil, synonymerna som knappar (`ChipFlowView`, ett tryck slår upp ordet i samma ruta), meningen med ordet understruket, AI-knappen vars svar växer fram i kortet, och längst ner SO och SAOL, Sparat, Fel synonym och betydelserna. Höjden följer innehållet (`preferredContentSize`). Popover på iPad, ark i halv höjd på iPhone med stängknapp. Ingen uppläsning. Självtestet fotograferar kortet i en ruta (`fas6-07*`).
* Sparat i ordkortet (D3-1) tar bort ordet och visar `UndoBar` i fönstret i fem sekunder. Ångra, eller Spara i samma kort, kör `UserWords.restoreDeleted` med raden som `delete` gav tillbaka (`SavedWordRecord`): samma id, bok-id, betydelse, mening och hela raden i `reviews`, raden i `deleted_words` tas bort och ordets `updated` blir nu, så att synken skickar ordet som levande. XCTest i `UserWordsUndoTests`, självtestet i `fas6.log`.
* Vald betydelse (O7): kolumnen `sense_id` i `saved_words` (steg 3 i trappan, på Windows en kolumn i `statements.json`). Väljs i kortets lista över betydelser eller via AI:ns förslag, och repetitionen visar sedan bara den. Följer inte med i synken.
* Dina ord i texten (O4): `SavedWordMarks` räknar i bakgrunden fram böjningsformerna för de sparade orden (egen anslutning till ordboken, `WordDictionary.forms(ofLemma:)`) till en tabell form till `w:` (övar) eller `k:` (kan, intervallet i `reviews` minst 21 dagar) plus id. PDF: `SavedWordMatcher` letar i sidans text på renderingskön och strecken ritas som vyer ovanpå sidbilden. EPUB: `lasaMarks.applyWords` i webbvyn. Strecken finns bland sidans markeringar med id `ord:` plus språk och grundform, så ett tryck mitt på sidan öppnar ordkortet (i kanterna bläddrar det). Av och på i Aa.
* Wiktionary (O10): `tools/dictionary/wiktionary.py` strömmar de svenska orden ur engelska Wiktionary från kaikki.org och filtrerar i bygget (rådata sparas aldrig). Tabellerna `sv_wiktionary` (uttal, ursprung) och `en_sv_wiktionary` (fler översättningar) hör inte till uppslaget, så de tre kopiorna av uppslagslogiken är oförändrade. Ordkortet läser dem med `WordDictionary.extras`. Licensen CC BY-SA står under Om ordboken och i README.
* Det användaren gör (sparade ord, dolda synonympar) ligger i `anvandarord.sqlite` under Application Support, aldrig i ordboksfilen.
* Svenska Akademiens data (SO, SAOL) får aldrig kopieras in. Den visas bara via svenska.se i en `SFSafariViewController`.
* Samma databasfil används i Windows-appen, där Rust-delen läser den skrivskyddat (`dict_query`). Windows-appens egna data ligger i `bibliotek.sqlite` och `anvandarord.sqlite` under `%APPDATA%\se.edvin.lasa`.

## Säkerhet

Repot är publikt. Inga nycklar, lösenord eller personliga data i koden eller i commits. API-nycklar matas in i appens inställningar och sparas i Keychain.

## Text

* Appens texter är på svenska.
* Använd aldrig tankstreck eller bindestreck som skiljetecken i appens texter, i dokumentation eller i meddelanden till Edvin. Skriv om meningen, eller använd komma, punkt eller parentes.
* Svara Edvin på svenska, kort och konkret.
