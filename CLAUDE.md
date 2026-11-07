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
  Library/   bibliotek, import, lagring
  Reader/    läsare, rendering, pappersvikning
  Support/   haptik och små hjälpare
Config/Info.plist
docs/SPEC.md
tools/dictionary/   (fas 2) Python som bygger ordboksdatabasen
.github/workflows/ios-build.yml
```

## Regler för läsaren

* Bläddring sker med `UIPageViewController(transitionStyle: .pageCurl)`, ryggen till vänster, ensidigt. Byt inte övergång om inte Edvin ber om det.
* Ingen rendering på huvudtråden under en pågående vikning. Förrendera grannsidor i bakgrunden.
* Håll minnet nere: högst 5 renderade sidbilder, högst 3 webbvyer för EPUB.
* Renderingsstorleken får bara bero på vyns storlek, inte på om menyraden syns.
* Haptik går genom `Haptics.shared`. iPad har ingen vibrationsmotor, där händer inget, och det är förväntat.

## Ordboken (fas 2)

* Offline SQLite, byggd av `tools/dictionary/build.py` från Swesaurus, SALDO, Open English WordNet och Folkets lexikon. Se licenser i specen.
* Svenska Akademiens data (SO, SAOL) får aldrig kopieras in. Den visas bara via svenska.se i en `SFSafariViewController`.
* Samma databasfil ska fungera i Windows-appen senare.

## Säkerhet

Repot är publikt. Inga nycklar, lösenord eller personliga data i koden eller i commits. API-nycklar matas in i appens inställningar och sparas i Keychain.

## Text

* Appens texter är på svenska.
* Använd aldrig tankstreck eller bindestreck som skiljetecken i appens texter, i dokumentation eller i meddelanden till Edvin. Skriv om meningen, eller använd komma, punkt eller parentes.
* Svara Edvin på svenska, kort och konkret.
