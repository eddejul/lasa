# Läsa

Läsapp för iPad och iPhone med pappersvikning som i Apple Books, och en ordfunktion som visar synonymer när man trycker på ett ord. Hela planen finns i [docs/SPEC.md](docs/SPEC.md).

**Status:** fas 2 byggs på grenen `fas2`: ordboken. Fas 1 (uppslag i liggande läge, innehållsförteckning, Gå till sida, reglage, zoom och tre bakgrunder) testas på iPaden. Fas 0 är testad och godkänd.

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

## Testa fas 2

* Håll fingret stilla på ett ord i en PDF en kort stund. Ordet markeras och en ruta visar grundform, ordklass och synonymer per betydelse. Ett vanligt tryck i mitten visar fortfarande menyn.
* Prova en böjd form (till exempel "sprang" eller "svårigheter") och ett ord som är avstavat över två rader.
* Prova ett engelskt ord: rutan ska visa svensk översättning och engelska synonymer med definition.
* Tryck på en betydelse för att se synonymerna en och en. Svep åt vänster på en synonym för Fel synonym. Visa i SO och SAOL öppnar svenska.se.
* I biblioteket, knappen uppe till vänster: Sparade ord (orden du slagit upp, med meningen) och Om ordboken (källor och hur snabbt uppslagen gick).

Testrapporten för ordboken (150 ord ur kurslitteraturen och appens svar) finns som artefakten **Ordbok-testrapport** i samma körning som appen.

## Licenser för ordboken

Ordboken bygger på Folkets synonymlexikon och Folkets lexikon (KTH), Swesaurus och SALDO (Språkbanken, Göteborgs universitet) och Open English WordNet. Detaljer i `tools/dictionary/README.md` och under Om ordboken i appen.
