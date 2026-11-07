# CLAUDE.md

Läsa är en läsapp för iPad och iPhone (Swift, UIKit) med pappersvikning som i Apple Books och en offline ordfunktion. En Windows-version kommer i fas 5. Hela specen finns i `docs/SPEC.md`. Läs den innan du börjar på en ny fas.

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
  Support/     haptik och små hjälpare
  Resources/   lasa-ordbok.sqlite läggs här av bygget, checkas inte in
Config/Info.plist
docs/SPEC.md
tools/dictionary/   (fas 2) Python som bygger ordboksdatabasen
tools/simtest/      (fas 3) testböcker och skriptet som kör självtestet i en iPad-simulator
.github/workflows/ios-build.yml
```

## Regler för läsaren

* Bläddring sker med `UIPageViewController(transitionStyle: .pageCurl)`. Stående: en sida, ryggen till vänster. Liggande på iPad: uppslag, ryggen i mitten, omslaget ensamt till höger. Edvin har godkänt vikningens känsla. Ändra den inte, och byt inte övergång, om han inte ber om det.
* Ingen rendering på huvudtråden, varken under en vikning eller annars. Sidbilder kommer bara via `PDFPageRenderer`, som ritar i bakgrunden med ett eget `PDFDocument`. Läsarens dokument används bara på huvudtråden.
* Håll minnet nere: högst 5 renderade sidbilder (även i uppslag), högst 3 webbvyer för EPUB.
* Sidans placering och renderingsstorlek får bara bero på vyns storlek och läsarens fasta marginaler, aldrig på om menyraden eller statusfältet syns. Använd inte vyns `safeAreaInsets` för sidan, de ändras med menyraden.
* Haptik går genom `Haptics.shared`. iPad har ingen vibrationsmotor, där händer inget, och det är förväntat.

## EPUB och textfiler (fas 3)

* Inget Readium. `App/Books/` packar upp EPUB med en egen zipläsare och läser OPF, nav och NCX med `XMLTree`. Textfiler görs om till HTML-kapitel av `TextBookConverter`.
* Varje kapitel ligger i en dold `WKWebView` (`ChapterView` i `ReflowRenderer.swift`) med CSS-kolumner. Bladen i vikningen är ögonblicksbilder. Webbvyerna får aldrig synas eller ta tryck, de ligger under `paperCover` i läsaren.
* Högst 3 webbvyer och högst 5 sidbilder. Ett jobb i taget per webbvy, med en vakt som laddar om kapitlet efter 8 sekunder utan svar.
* Skripten i webbvyn (`ReflowStyle.script`) körs i en egen JavaScript-värld (`.defaultClient`) och anropas med `callAsyncJavaScript`.
* Ordfunktionen i EPUB använder ordboken på ett enda ställe: `presentWord` i `ReflowReaderViewController.swift`. Hållgesten är densamma som i PDF (ordet närmast fingret, bubbla, rutan öppnas när man släpper). Ordet hittas i den dolda webbvyn med `lasa.wordAt`, ett uppslag i taget.
* Simulatortestet (jobbet Simulatortest) bygger appen för en iPad-simulator och startar den med `-LasaSelfTest <fil>`. Läs loggen och bilderna i artefakten Simulatortest efter varje ändring i läsaren, innan Edvin får något att testa. Simulatorn kör en nyare iOS än iPaden, och iOS 26 nekar appen att vrida skärmen, så självtestet gör läsarens yta bred för att pröva uppslag. Tider och minne gäller en Mac, inte iPaden.

## Markeringar, bokmärken och sök (fas 4)

* Allt sparas i `markeringar.sqlite` under Application Support (`AnnotationStore`), böckerna känns igen på filnamnet som läspositionen. Inget raderas: borttaget får `deleted = 1` och ny ändringstid, för synken.
* En markering är `section` plus ett teckenintervall i UTF-16. PDF: sidan och `PDFPage.string`. EPUB och text: kapitlet och kapitlets text (all text i body utom script och style). `text` sparas också, och skriptet letar upp markeringen via texten om platsen inte stämmer.
* Markeringsläget (pennan): sidans vikning, menyn och ordfunktionen stängs av, och en `UILongPressGestureRecognizer` med tiden 0 följer fingret. Ett vanligt tryck på en markering öppnar `HighlightMenuViewController`.
* PDF: markeringarna ritas som vyer ovanpå sidbilden i `PDFPageViewController` (ingen omritning av sidan). EPUB: `ReflowMarks.script` lägger span-element runt texten i den dolda webbvyn och sidan fotograferas om. `lasa.showPage` lämnar markeringarnas rutor, så att tryck på en markering hittas utan webbvyn.
* Sökningen (`BookSearch`) går i bakgrunden: PDF med ett eget `PDFDocument`, EPUB i kapitelfilerna utan taggar. Sökträffen i EPUB letas upp i webbvyn med samma vikning (`FoldedText` i Swift, `fold` i skriptet), n:te träffen med texten runt som kontroll.
* Bläddringsljudet räknas fram i appen (`PageTurnSound`), ingen ljudfil. Spelas när en vikning börjar.
* Självtestet provar allt detta i alla testböcker, även en PDF (`test.pdf` från `make_books.py`).

## Ordboken (fas 2)

* Offline SQLite, byggd av `tools/dictionary/build.py` från Synlex, Swesaurus, SALDO, Open English WordNet och Folkets lexikon. Se licenser i specen och `tools/dictionary/README.md`.
* Bygget i molnet har två jobb: Ordboken (Linux, bygger databasen och testrapporten) och Appen (Mac, lägger databasen i `App/Resources` före XcodeGen). Källfilerna och databasen sparas i Actions cache, så databasen byggs bara om när skripten eller testlistan ändras.
* Uppslagslogiken finns två gånger: `App/Dictionary/WordDictionary.swift` och `tools/dictionary/lookup.py` (som testrapporten använder). Ändras den ena ska den andra ändras i samma commit.
* Ord slås upp när fingret hålls stilla på ordet i 0,35 s (`wordPressDuration`). Ordet närmast fingret markeras (inte ordet till vänster), en bubbla ovanför fingret visar ordet, markeringen följer med om man drar, och rutan öppnas först när man släpper. Ett vanligt tryck i mitten är fortfarande menyn, och i kanterna bläddring.
* Rutan visar ett tydligt svar överst: för engelska den svenska översättningen (lånad från en synonym om ordet saknas i Folkets lexikon), för svenska definitionen ur Folkets lexikon och de vanligaste synonymerna. Övriga betydelser och ordklasser ligger bakom ett tryck. Edvin tyckte att den första rutan var förvirrande (7 november 2026).
* Det användaren gör (sparade ord, dolda synonympar) ligger i `anvandarord.sqlite` under Application Support, aldrig i ordboksfilen.
* Svenska Akademiens data (SO, SAOL) får aldrig kopieras in. Den visas bara via svenska.se i en `SFSafariViewController`.
* Samma databasfil ska fungera i Windows-appen senare.

## Säkerhet

Repot är publikt. Inga nycklar, lösenord eller personliga data i koden eller i commits. API-nycklar matas in i appens inställningar och sparas i Keychain.

## Text

* Appens texter är på svenska.
* Använd aldrig tankstreck eller bindestreck som skiljetecken i appens texter, i dokumentation eller i meddelanden till Edvin. Skriv om meningen, eller använd komma, punkt eller parentes.
* Svara Edvin på svenska, kort och konkret.
