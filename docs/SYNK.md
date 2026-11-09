# Synken (F1, våg 9)

Läsposition, markeringar med anteckningar, bokmärken och sparade ord (med repetitionen) synkas mellan iPaden och Windows-appen via en mapp i iCloud Drive, med en liten fil per enhet. Inget konto, ingen nyckel och ingen server. Den gamla Supabase-synken (fas 6) är borttagen och sattes aldrig upp.

## Ställa in (en gång)

1. iPaden: Inställningar, Synk, Välj mapp i iCloud Drive. Gå till iCloud Drive överst och tryck Öppna. Sensus skapar då mappen `Sensus` där (en liten befintlig `Sensus` används), provar att skriva och läsa där och att iCloud tar emot filen, och visar en grön bock.
2. Granskning 6, M1: roten i iCloud Drive blir aldrig själva synkmappen (bokmärket gäller då roten och undermappen sparas som `sync.folder.subfolder`). En mapp med fler än 20 böcker, fler än 10 undermappar eller böcker djupare än tre nivåer ger frågan Skapa mappen Sensus i mappen, Använd ändå eller Avbryt. Är den för stor (fler än 300 böcker, djupare än fyra nivåer eller fler än 3 000 poster) går bara en ny mapp. En mapp utanför iCloud Drive vägras.
3. Datorn: installera iCloud för Windows och slå på iCloud Drive. Mappen syns då som `C:\Users\<namn>\iCloudDrive\Sensus`. I Sensus för Windows: Inställningar, Synk, fyll i mappen (eller tryck Hitta iCloud Drive) och tryck Spara och prova.

Mappen sparas på iPaden som ett säkerhetsbokmärke. Går den inte att nå (mappen borttagen eller flyttad till papperskorgen, bokmärket för gammalt) står det i orange i biblioteket och under Synk, och ingenting tas bort.

## Böcker i mappen (B4)

Böcker som ligger i mappen (också i undermappar, som blir kurser som i Böcker) syns i biblioteket på iPaden och finns på alla enheter. Böcker i appens egen mapp Böcker finns bara på iPaden. Valet görs per bok i hållmenyn: Flytta till iCloud-mappen eller Flytta till bara iPaden. Flytten kopierar först, läser kopian igen och jämför kontrollsumman, och tar bort originalet först sedan. Bokens id i bokregistret följer med, och därmed markeringar, bokmärken, läsposition och sparade ord. I registret har en bok i mappen sökvägen `/iCloud/<sökväg i mappen>`. En sökväg i Böcker börjar aldrig med snedstreck, så de två går aldrig ihop.

Mappen läses i bakgrunden, aldrig på huvudtråden, med gränserna ovan (`LibraryStore.readCloud`). Biblioteket visar den senaste läsningen, och innan mappen lästs en gång räknas dess böcker som utom räckhåll, så att inget markeras som borta. Saknas mappen medan appen kör (L2) gäller samma sak. Samma bok (samma kontrollsumma) i Böcker och i mappen är en bok med ett id (M2, `BookMatch.duplicate`): den andra filen visas inte, biblioteket säger Samma bok på två ställen, och tas den som visas bort tar den andra över markeringarna. Flytten räknar en platshållare med samma namn som upptagen (M3), byter namn genom filkoordineringen, använder en likadan fil som redan ligger på den nya platsen i stället för en kopia, och avbryts om iCloud inte tar emot boken (L10, till exempel fullt iCloud). Kvarlämnade kopior från en avbruten flytt tas bort efter en timme (L5).

En bok som iCloud inte hämtat än (en platshållare, `.Bok.pdf.icloud` i iOS 15) börjar hämtas och visas när den är hämtad (högst 20 nya hämtningar per läsning). Biblioteket säger Hämtar 2 böcker från iCloud så länge. Undermappen `Sensus synk` och filer som inte är böcker visas inte. Windows-appen läser inte böcker ur mappen än, där läggs böckerna in som förut.

## Hur det fungerar

* Varje enhet skriver bara sin egen fil, `Sensus synk/<enhetens id>.json`. Ingen annan skriver i den, så filerna krockar aldrig i iCloud.
* Filen är enhetens hela sammanslagna bild: de egna raderna och allt den läst från de andra filerna, också rader för böcker som inte finns på enheten (de sparas när boken läggs in). En ny enhet får därför allt från vilken fil som helst.
* Den nyaste ändringen vinner, rad för rad, räknat i hela millisekunder. Vid lika tid vinner det som redan finns på enheten. För ett sparat ord jämförs ordet och repetitionen var för sig. Ett borttaget ord har ingen repetition.
* Borttaget raderas aldrig ur filen: raden får `deleted: true` och en ny tid. En rad som saknas i en fil betyder aldrig borttagen, så en tom, trasig eller halvt hämtad fil kan inte ta bort något.
* Filen skrivs atomiskt: först `<id>.json.tmp`, sedan byts namnet (rename), och sist läses filen tillbaka och jämförs. Den skrivs när något ändrats och annars högst var sjätte timme.
* En fil som inte går att läsa hoppas över med en rad i loggen (`Documents/Diagnostik/logg.txt` på iPaden) och under Synk: tom, trasig JSON (halvt hämtad), inte en synkfil, ett format som är nyare än appen, eller inte hämtad från iCloud än (då begärs hämtningen och filen kommer med nästa gång). Enstaka rader som inte går att läsa hoppas över, resten av filen används.
* Den egna filen: är den inte hämtad skrivs den inte över den gången. Är den trasig sparas den undan som `<id>.trasig-<datum tid>` innan en ny skrivs. Är den från en nyare version av appen rörs den inte, och synken säger till.
* Synken går när appen kommer fram, när man stänger en bok (högst en gång i minuten) och med Synka nu. Efter en återställning från säkerhetskopian är den pausad tills den startas igen under Inställningar, Synk.
* Enhetens id är ett UUID som sparas en gång. På iPaden byts det om `identifierForVendor` ändras (appen förd till en ny iPad via en säkerhetskopia), så att två enheter aldrig skriver samma fil.

## Filformatet (för Windows-appen)

En JSON-fil i UTF-8. Läsare hoppar över fält de inte känner till. `format` höjs bara när en äldre app inte längre kan läsa filen rätt, och en fil med högre `format` än appen känner till läses inte.

```json
{
  "format": 1,
  "app": "Sensus",
  "device": {"id": "<uuid>", "name": "Edvins iPad", "platform": "ios"},
  "written_at": "2026-11-09T01:23:45.678Z",
  "positions": [{"book_id": "<sha256>", "title": "Bok", "kind": "pdf", "section": 12, "progression": 0,
                 "updated_at": "2026-11-09T01:20:00.123Z"}],
  "highlights": [{"id": "<uuid>", "book_id": "<sha256>", "section": 3, "start": 120, "length": 42, "text": "...",
                  "color": "yellow", "note": "", "created_at": "...", "updated_at": "...", "deleted": false}],
  "bookmarks": [{"id": "<uuid>", "book_id": "<sha256>", "section": 4, "progression": 0.25, "label": "...",
                 "created_at": "...", "updated_at": "...", "deleted": false}],
  "saved_words": [{"lemma": "bro", "language": "sv", "word": "bron", "sentence": "...", "book": "Bok", "page": 3,
                   "lookups": 2, "created_at": "...", "updated_at": "...", "deleted": false, "due": 1794000000.5,
                   "interval": 3, "ease": 2.5, "reps": 2, "lapses": 1, "review_updated_at": "..."}]
}
```

* `platform`: `ios` eller `windows`.
* Tider skrivs som ISO 8601 i UTC med millisekunder (`2026-11-07T18:35:07.123Z`). Längre bråkdelar och `+00:00` läses också och kortas till millisekunder. Jämför i hela millisekunder. En tid utan tidszon eller utan klockslag är en rad som inte går att läsa, `format` ska vara ett tal och en fil med BOM läses, på båda plattformarna (granskning 6, L7).
* `id` för markeringar och bokmärken är UUID med gemener, `book_id` är SHA-256 av hela bokfilen med gemener.
* Nycklar: `book_id` (positions), `id` (highlights, bookmarks), `language` plus `lemma` (saved_words). Samma nyckel två gånger i en fil: den nyaste gäller.
* `progression` skrivs med högst sex decimaler.
* Platserna i en bok:
  * PDF: `kind` är `pdf`, `section` är sidan från 0. Markeringens `start` och `length` gäller sidans text i UTF-16.
  * EPUB och text: `kind` är `reflow`, `section` är kapitlet i läsordningen (spine) från 0, `progression` andelen av kapitlet (0 till 1). Markeringens `start` och `length` gäller kapitlets text: all text i body i dokumentordning utom i script och style, i UTF-16. `text` är den markerade texten, så att markeringen kan letas upp när platsen inte stämmer.
  * Textfiler delas i kapitel av iPad-appen. Deras platser stämmer bara om Windows-appen delar filen på samma sätt, och Windows synkar inte deras läspositioner.
* Sparade ord: `language` är `sv` eller `en`. Repetitionen: `due` (sekunder sedan 1970), `interval` (dagar), `ease`, `reps`, `lapses` och `review_updated_at`. Utan repetition, och för ett borttaget ord, är de `null`.
* Windows-appen synkar läspositioner (PDF och EPUB) och sparade ord. Markeringar och bokmärken från iPaden följer med oförändrade i Windows-appens fil, men visas inte på datorn än.

## Provat

* XCTest (`Tests/LasaTests/SyncFileTests.swift`): filformatet fram och tillbaka, trasiga, tomma och nyare filer, rader som inte går att läsa, krockar mellan två och tre enheter, borttaget och det som saknas, ord och repetition var för sig, den atomiska skrivningen och sökvägarna för böcker i mappen.
* Självtestet `-LasaSelfTest fas6` (`App/Support/SyncSelfTest.swift`) med en vanlig mapp i stället för iCloud Drive (simulatorn har inget iCloud): guiden, en fil från en påhittad Windows-dator, tre filer som ska hoppas över, krockar, flytten av en bok till mappen och tillbaka, och en mapp som inte går att nå. Läs `fas6.log` och `synkmappen/` i artefakten Simulatortest.
* Windows: `windows/tests/e2e_sync.py` mot en mapp med en påhittad iPad-fil.
* Bara på iPaden går att prova: riktiga iCloud Drive, dokumentväljarens mapp och säkerhetsbokmärket efter omstart, platshållare som hämtas, och att Windows-appens fil når iPaden via iCloud för Windows.
