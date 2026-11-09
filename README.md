# Läsa

Läsapp för iPad och iPhone med pappersvikning som i Apple Books, och en ordfunktion som visar synonymer när man trycker på ett ord. Hela planen finns i [docs/SPEC.md](docs/SPEC.md).

**Status:** fas 3 (EPUB och textfiler) byggs på grenen `fas3`, fas 2 (ordboken) på grenen `fas2`. Fas 1 testas på iPaden. Fas 0 är testad och godkänd.

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

Vill du slippa det finns två gratis vägar (F3 steg två). Kontrollerat mot deras egna sidor 9 november 2026:

* **SideStore** fungerar från iOS och iPadOS 15.0 (docs.sidestore.io, Prerequisites), alltså på iPad Air 2 med
  iPadOS 15.8.3. Datorn behövs bara vid installationen. Så går det till enligt deras instruktioner:
  1. På datorn: installera iTunes från Apple (inte Microsoft Store) och programmet iloader (MSI-filen).
  2. Koppla iPaden med kabel, lita på datorn och skriv koden. Öppna iloader, logga in med ditt Apple-ID, välj
     iPaden och installera SideStore (stable).
  3. På iPaden: Inställningar, Allmänt, VPN och enhetshantering, lita på ditt Apple-ID. Installera appen
     LocalDevVPN från App Store, öppna den och välj Connect. Öppna SideStore och logga in med samma Apple-ID.
  4. Lägg in Sensus i SideStore (Lasa-unsigned.ipa från Actions). SideStore förnyar apparna i bakgrunden, och
     under My Apps förnyar ett tryck på räknaren 7 DAYS direkt. LocalDevVPN ska vara på när SideStore
     installerar eller förnyar.
  Gränser med gratis Apple-ID (SideStores FAQ): högst 3 appar åt gången och SideStore räknas som en av dem, och
  högst 10 olika appar (App ID) per vecka. Har du redan installerat Sensus med Sideloadly räknas den också.
  Att LocalDevVPN går att installera på iPadOS 15 står inte på SideStores sidor och är inte kontrollerat.
* **AltStore Classic** förnyar när datorn med AltServer är igång, men version 2.3 (14 september 2026) kräver
  iOS 17.4 enligt AltStores versionsanteckningar. Den går alltså inte på iPaden. Om en äldre version går att
  installera på iPadOS 15 är inte kontrollerat. På iPhone 12 med nyare iOS fungerar den: AltServer på datorn
  (Windows 10 eller senare, iTunes och iCloud från Apple), samma wifi, och Bakgrundsuppdatering på.

**Steg tre, betalt utvecklarkonto** (99 USD per år): appen går inte ut efter 7 dagar och kan delas via
TestFlight. Det bryter målet om gratis drift och är ett beslut för senare. Inget i repot förutsätter det.

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

## Testa fas 3

* Lägg in en EPUB (helst en roman och en kursbok) och en textfil (txt eller md) med plus. Den öppnas med samma pappersvikning som PDF.
* Bläddra genom några kapitelgränser, framåt och bakåt, snabbt och långsamt. Säg till om vikningen hackar eller om en sida är tom en stund.
* Knappen med två A i menyn: ändra storlek och typsnitt. Sidan ska hamna ungefär där du var.
* Vänd iPaden till liggande: två sidor bredvid varandra. Varje kapitel börjar till vänster.
* Håll fingret på ett ord i EPUB:en och dra lite: markeringen och bubblan ska följa fingret som i PDF, och rutan öppnas när du släpper. Tryck på en fotnot och sedan Tillbaka.

Under knappen med två A står längst ner hur många millisekunder en sidbild tar på din iPad. Skriv gärna av det.

## Testa fas 4

Fas 4 byggs på grenen `fas4`, som innehåller fas 2 och fas 3.

* **Markera:** tryck på pennan i menyn. Sidan står still och en rad med färger visas nere. Dra med fingret över några rader i en PDF och i en EPUB. Prova också att trycka på ett enda ord, och att dra från texten ut i den tomma ytan under sista raden. Klar avslutar, pilarna i raden bläddrar.
* **Anteckning:** tryck på en markering (utan pennan). Byt färg, skriv en anteckning, kopiera eller ta bort. En markering med anteckning får ett streck under.
* **Bokmärke:** bokmärket i menyn märker sidan du läser (ett rött band i hörnet). Tryck igen för att ta bort det.
* **Listorna:** knappen Innehåll har nu tre flikar: Innehåll, Bokmärken och Markeringar. Tryck på en rad för att hoppa dit, svep åt vänster för att ta bort.
* **Sök:** förstoringsglaset söker i hela boken. Tryck på en träff: sidan visas och träffen blinkar orange en stund.
* **Bläddringsljud:** menyn Bakgrund (den halvfyllda cirkeln) har ett val för bläddringsljud. Det är på från början. Säg till om ljudet låter fel.
* Stäng appen helt och öppna igen: markeringar, anteckningar och bokmärken ska finnas kvar.

## Testa fas 6

Fas 6 byggs på grenen `fas6`, som innehåller fas 2, 3 och 4.

* **Repetera ord:** knappen uppe till vänster i biblioteket, Repetera ord (eller Repetera under Sparade ord). Ordet och meningen visas, tryck Visa svaret och välj Igen, Svårt, Bra eller Lätt. Under knapparna står när ordet kommer tillbaka. Högst 20 nya ord per dag.
* **AI-knappen:** skapa en gratis nyckel i Google AI Studio (aistudio.google.com) och klistra in den under Inställningar, Förklaring med AI. Tryck Prova nyckeln. Håll sedan fingret på ett ord: rutan har Förklara i meningen. Utan nyckel syns ingen AI-knapp. Meningen skickas till Google.
* **Synk:** kräver ett eget Supabase-projekt, se [docs/SYNK.md](docs/SYNK.md). Fyll i adress, nyckel, e-post och lösenord under Inställningar och tryck Logga in. Synken går också när appen öppnas och när du stänger en bok. Windows-appen behöver synken för att det ska märkas.

## Licens

* **Koden** (appen för iPad, Windows-appen, skripten under `tools/`) är öppen källkod under MIT-licensen, se
  [LICENSE](LICENSE).
* **Ordboken** (databasen `lasa-ordbok.sqlite` som byggs av `tools/dictionary/build.py` och följer med apparna)
  delas under **CC BY-SA 4.0** (https://creativecommons.org/licenses/by-sa/4.0/). Den är en bearbetning av
  Folkets lexikon (KTH, CC BY-SA 2.5, som tillåter en senare version med samma villkor), wordfreq (CC BY-SA 4.0)
  och Wiktionary via kaikki.org (CC BY-SA 4.0), och bygger också på Folkets synonymlexikon Synlex (KTH, fri med
  upphovsnotisen kvar), Swesaurus och SALDO (Språkbanken, Göteborgs universitet, CC BY 4.0) och Open English
  WordNet (CC BY 4.0). Detaljer i `tools/dictionary/README.md` och under Om ordboken i appen. Svenska
  Akademiens data (SO, SAOL) ingår inte, den visas bara via svenska.se.
* **Biblioteken i Windows-appen** behåller sina egna licenser: pdf.js (Apache 2.0), foliate-js (MIT) och zip.js
  (BSD 3-Clause), se `windows/src/vendor/VENDOR.md`.
