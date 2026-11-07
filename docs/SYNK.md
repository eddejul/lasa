# Synken (fas 6)

Läsposition, markeringar med anteckningar, bokmärken och sparade ord (med repetitionen) synkas mellan iPaden och Windows-appen via ett eget Supabase-projekt på gratisnivån. Böckerna själva synkas inte här: lägg dem i en mapp i iCloud Drive och öppna samma fil på båda ställena.

## Ställa in (en gång)

Namnen i Supabase kontrollerades mot Supabases egna sidor 7 november 2026. Knapptexter kan ändras, så leta efter något liknande om ett namn inte stämmer.

1. Skapa ett gratis konto på supabase.com och ett nytt projekt (välj en region i EU).
2. Öppna SQL Editor, klistra in hela `tools/supabase/schema.sql` och kör den. Det skapar fyra tabeller och regler som gör att bara den inloggade ser sina rader.
3. Lägg till dig själv som användare under Authentication, Users (Add user), med e-post och lösenord, och bekräfta användaren direkt.
4. Stäng av "Allow new users to sign up" under Authentication, så att ingen annan kan skapa ett konto i projektet.
5. Hämta projektets adress och den publika nyckeln (publishable key, börjar med `sb_publishable_`, eller den äldre anon-nyckeln) under Settings, API Keys, eller i dialogen Connect. Använd aldrig secret-nyckeln i apparna.
6. iPaden: Bibliotek, kugghjulet, Synk med Windows-appen. Fyll i adress, publik nyckel, e-post och lösenord, och tryck Logga in. Lösenordet sparas inte, bara inloggningen (i nyckelringen).

Gratisprojekt pausas efter en veckas inaktivitet. Data finns kvar, och projektet startas igen från Supabase.

## Hur det fungerar

* Appen synkar när den kommer fram, när man stänger en bok (högst en gång i minuten) och med Synka nu.
* Varje rad har en ändringstid i UTC med millisekunder. Den nyaste vinner, rad för rad. För ett sparat ord jämförs ordet och repetitionen var för sig.
* Borttaget raderas inte i Supabase utan får `deleted = true`, så att det försvinner på alla enheter.
* Allt läses och jämförs varje gång. Det är små mängder, och det gör synken enkel och tålig.

## Protokollet (för Windows-appen)

Anropen är vanlig Supabase REST, utan bibliotek:

* Inloggning: `POST {adress}/auth/v1/token?grant_type=password` med rubriken `apikey: <publik nyckel>` och `{"email", "password"}`. Svaret har `access_token`, `refresh_token`, `expires_in` och `user.id`. Förnyelse: samma adress med `grant_type=refresh_token` och `{"refresh_token"}`.
* Läsa: `GET {adress}/rest/v1/<tabell>?select=*&order=updated_at.asc&limit=1000&offset=<n>` med `apikey` och `Authorization: Bearer <access_token>`.
* Skriva: `POST {adress}/rest/v1/<tabell>?on_conflict=<kolumner>` med `Prefer: resolution=merge-duplicates,return=minimal` och en lista med rader som alla har samma nycklar. Kolumnerna: `user_id,book_id` (positions), `id` (highlights, bookmarks), `user_id,lemma,language` (saved_words).
* Tider skrivs som ISO 8601 i UTC med millisekunder (`2026-11-07T18:35:07.123Z`). Supabase svarar med mikrosekunder och `+00:00`. Jämför i hela millisekunder.
* `id` för markeringar och bokmärken är UUID med gemener.
* Bokens id: SHA-256 av hela filen, gemener, hex.
* Platserna i en bok:
  * PDF: `section` är sidan från 0. Markeringens `start` och `length` gäller sidans text i UTF-16.
  * EPUB: `section` är kapitlet i läsordningen (spine) från 0. `progression` är andelen av kapitlet (0 till 1). Markeringens `start` och `length` gäller kapitlets text: all text i body i dokumentordning utom i script och style, räknad i UTF-16. `text` är den markerade texten (blanktecken ihopslagna), så att markeringen kan letas upp när platsen inte stämmer.
  * Textfiler delas i kapitel av iPad-appen. Deras platser stämmer bara om Windows-appen delar filen på samma sätt.
* Sparade ord: `language` är `sv` eller `en`. Repetitionen: `due` (sekunder sedan 1970), `interval` (dagar), `ease`, `reps`, `lapses` och `review_updated_at`. Ett borttaget ord har `deleted = true` och ingen repetition.

## Provat

Simulatortestet i bygget (jobbet Simulatortest, `-LasaSelfTest fas6`) loggar in mot en låtsas-Supabase (`tools/simtest/mock_supabase.py`) som svarar på samma anrop, synkar tre gånger och skriver vad servern fick i `mock-supabase.json` i artefakten. Mot ett riktigt Supabase-projekt är synken inte provad än, eftersom inget projekt finns.
