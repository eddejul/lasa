# Läsa

Läsapp för iPad och iPhone med pappersvikning som i Apple Books, och en ordfunktion som visar synonymer när man trycker på ett ord. Hela planen finns i [docs/SPEC.md](docs/SPEC.md).

**Status:** fas 1. Appen läser PDF med pappersvikning, med uppslag i liggande läge på iPad, innehållsförteckning, Gå till sida, reglage, zoom och tre bakgrunder. Fas 0 är testad och godkänd på iPaden.

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

## Testa fas 1

* Tryck i mitten: menyn visas och sidan står still, den krymper inte.
* Vänd iPaden till liggande: två sidor bredvid varandra, omslaget ensamt till höger. Bläddra och vänd tillbaka till stående.
* Menyn: innehållsförteckningen hoppar till rätt kapitel, reglaget längst ner hoppar i boken, och sidnumret öppnar Gå till sida (prova bokens egna sidnummer).
* Dubbeltryck mitt på en sida: den öppnas i zoom, nyp för att förstora. Klar stänger.
* Bakgrund (den halvfyllda cirkeln i menyn): vitt, sepia och mörkt. Bilder i boken ska inte bli negativ i mörkt.

Berätta för Claude Code vad som känns fel, till exempel om vikningen hackar eller om texten är suddig.

## Licenser för ordboken (fas 2)

Ordboken bygger på Swesaurus och SALDO (Språkbanken, Göteborgs universitet), Open English WordNet och Folkets lexikon (KTH). Detaljer i specen.
