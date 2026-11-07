# Läsa

Läsapp för iPad och iPhone med pappersvikning som i Apple Books, och en ordfunktion som visar synonymer när man trycker på ett ord. Hela planen finns i [docs/SPEC.md](docs/SPEC.md).

**Status:** fas 0. Appen har ett bibliotek och läser PDF med pappersvikning.

## Kom igång (en gång)

1. Skapa ett **publikt** repo på GitHub som heter `lasa`. Publikt gör att byggena på Mac i molnet blir gratis.
2. Packa upp startpaketet i en tom mapp på datorn.
3. Öppna mappen i Claude Code (desktopappen, fliken Code) och skriv:
   *"Initiera git i den här mappen, koppla den till mitt GitHub-repo lasa och pusha till main."*
   Saknas Git eller GitHub CLI hjälper Claude Code dig att installera dem.
4. Gå till repot på github.com, fliken **Actions**. Körningen **iOS build** tar ungefär 5 till 10 minuter. En grön bock betyder att appen är byggd.

## Installera på iPaden

1. Installera **iTunes** och **iCloud** från Apples webbplats (inte versionerna från Microsoft Store), sedan **Sideloadly** från sideloadly.io. Länkarna finns under "Before you install" på sideloadly.io.
2. Öppna den gröna körningen under Actions, ladda ner artefakten **Lasa-ipa** och packa upp zip-filen. Du får filen `Lasa-unsigned.ipa`.
3. Koppla iPaden till datorn med kabel, lås upp den och tryck **Lita på** datorn. Frågan om att ge datorn åtkomst till bilder gäller bara foton och behövs inte.
4. Öppna programmet Sideloadly. iPaden syns inte i Utforskaren, den väljs i Sideloadly under iDevice. Dra `.ipa`-filen från Utforskaren till IPA-ikonen i Sideloadlys fönster, skriv ditt Apple-ID och tryck **Start**.
5. På iPaden: Inställningar, Allmänt, VPN och enhetshantering. Tryck på ditt Apple-ID och välj **Lita på**.
6. Öppna Läsa, tryck på **+** och välj en PDF. Du kan också välja Öppna i Läsa från Filer-appen.

**iPhone:** samma steg. På iOS 16 och senare behöver du dessutom slå på Utvecklarläge under Inställningar, Integritet och säkerhet, och starta om telefonen.

## Var sjunde dag

Med ett gratis Apple-ID slutar appen starta efter 7 dagar. Kör Sideloadly igen med samma fil. Böckerna och läspositionerna finns kvar.

Vill du slippa det: **AltStore** förnyar appen automatiskt när datorn (med AltServer igång) och iPaden är på samma wifi.

## Testa fas 0

* Dra från högra kanten: sidan ska vikas och följa fingret utan hack.
* Tryck i höger eller vänster kant: bläddrar en sida.
* Tryck i mitten: menyn och sidnumret visas och döljs.
* Gå tillbaka och öppna boken igen: den ska öppnas på samma sida.
* Vänd iPaden till liggande: sidan ska fortfarande vara skarp.

Berätta för Claude Code vad som känns fel, till exempel om vikningen hackar eller om texten är suddig.

## Licenser för ordboken (fas 2)

Ordboken bygger på Swesaurus och SALDO (Språkbanken, Göteborgs universitet), Open English WordNet och Folkets lexikon (KTH). Detaljer i specen.
