# CLAUDE.md

Läsa är en läsapp för iPad och iPhone (Swift, UIKit) med pappersvikning som i Apple Books och en offline ordfunktion. Windows-versionen (fas 5, Tauri) ligger i `windows/`, se `windows/README.md`. Hela specen finns i `docs/SPEC.md`. Läs den innan du börjar på en ny fas.

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
2. Push startar `Windows build` (bara när `windows/`, `tools/dictionary/` eller workflowfilen ändras). iOS-bygget hoppar över ändringar som bara rör `windows/`.
3. Följ bygget: `gh run list --workflow "Windows build" --limit 1`, fel med `gh run view <id> --log-failed`. Samma regel om tre fel som ovan.
4. När bygget är grönt: Edvin laddar ner artefakten `Lasa-windows` och kör filen som slutar på `-setup.exe` (osignerad: Mer info och Kör ändå).
5. Synken på Windows (`windows/src/js/sync.js`) följer `docs/SYNK.md` och iPadens `App/Sync/SyncEngine.swift`. Ändras protokollet ska båda ändras. Provas med `windows/tests/e2e_sync.py` mot `windows/tests/mock_supabase.py`.

## Projektet

* `project.yml` är källan för Xcode-projektet (XcodeGen). Lägg nya Swift-filer under `App/`, de tas med automatiskt. Ändra aldrig en `.xcodeproj` för hand, den checkas inte in.
* `Config/Info.plist` är appens Info.plist. Den ligger utanför `App/` med flit, så att den inte kopieras som resurs.
* Swift språkläge 5 (`SWIFT_VERSION: 5.0`). Klasser som rör UI ska vara `@MainActor` eller vara UIKit-subklasser.
* Paket läggs till under `packages:` i `project.yml`. Lås alltid versionen och kontrollera att paketets lägsta iOS är 15 eller lägre innan du lägger till det.

## Mappar

```
App/
  AppDelegate.swift, SceneDelegate.swift
  Library/     bibliotek, import, lagring
  Reader/      läsare, rendering, pappersvikning
  Dictionary/  ordboken, ordet under fingret, ordrutan, sparade ord
  Support/     haptik och små hjälpare
  Resources/   lasa-ordbok.sqlite läggs här av bygget, checkas inte in
Config/Info.plist
docs/SPEC.md
tools/dictionary/   (fas 2) Python som bygger ordboksdatabasen
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

## Ordboken (fas 2)

* Offline SQLite, byggd av `tools/dictionary/build.py` från Synlex, Swesaurus, SALDO, Open English WordNet och Folkets lexikon. Se licenser i specen och `tools/dictionary/README.md`.
* Bygget i molnet har två jobb: Ordboken (Linux, bygger databasen och testrapporten) och Appen (Mac, lägger databasen i `App/Resources` före XcodeGen). Källfilerna och databasen sparas i Actions cache, så databasen byggs bara om när skripten eller testlistan ändras.
* Uppslagslogiken finns tre gånger: `App/Dictionary/WordDictionary.swift`, `tools/dictionary/lookup.py` (som testrapporten använder) och `windows/src/js/lookup.js` (Windows-appen). Ändras en ska de andra ändras i samma commit. `windows/tests/parity.mjs` jämför lookup.js med lookup.py över testlistan och körs i Windows-bygget.
* Ord slås upp när fingret hålls stilla på ordet i 0,35 s (`wordPressDuration`). Ordet närmast fingret markeras (inte ordet till vänster), en bubbla ovanför fingret visar ordet, markeringen följer med om man drar, och rutan öppnas först när man släpper. Ett vanligt tryck i mitten är fortfarande menyn, och i kanterna bläddring.
* Rutan visar ett tydligt svar överst: för engelska den svenska översättningen (lånad från en synonym om ordet saknas i Folkets lexikon), för svenska definitionen ur Folkets lexikon och de vanligaste synonymerna. Övriga betydelser och ordklasser ligger bakom ett tryck. Edvin tyckte att den första rutan var förvirrande (7 november 2026).
* Det användaren gör (sparade ord, dolda synonympar) ligger i `anvandarord.sqlite` under Application Support, aldrig i ordboksfilen.
* Svenska Akademiens data (SO, SAOL) får aldrig kopieras in. Den visas bara via svenska.se i en `SFSafariViewController`.
* Samma databasfil används i Windows-appen, där Rust-delen läser den skrivskyddat (`dict_query`). Windows-appens egna data ligger i `bibliotek.sqlite` och `anvandarord.sqlite` under `%APPDATA%\se.edvin.lasa`.

## Säkerhet

Repot är publikt. Inga nycklar, lösenord eller personliga data i koden eller i commits. API-nycklar matas in i appens inställningar och sparas i Keychain.

## Text

* Appens texter är på svenska.
* Använd aldrig tankstreck eller bindestreck som skiljetecken i appens texter, i dokumentation eller i meddelanden till Edvin. Skriv om meningen, eller använd komma, punkt eller parentes.
* Svara Edvin på svenska, kort och konkret.
