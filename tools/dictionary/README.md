# Ordboken

**Wiktionary (O10, 8 november 2026):** `wiktionary.py` strömmar de svenska orden ur engelska Wiktionary
från kaikki.org (Wiktextract av Tatu Ylonen, cirka 360 MB JSON Lines) och sparar bara en filtrerad fil bland
källorna (`sources/wiktionary-sv-filtrerad.json`). Rådata sparas aldrig, varken där eller i repot. Ordboken
får `sv_wiktionary` (uttal och ursprung för svenska grundformer som finns i SALDO, ursprunget kortat till en
mening och delvis översatt till svenska) och `en_sv_wiktionary` (svenska ord vars engelska förklaring är ett
engelskt ord i Open English WordNet, bara par som Folkets lexikon saknar). Licens: CC BY-SA 4.0, och den
bearbetade versionen delas under samma licens. Tabellerna hör inte till uppslaget (`lookup.py`, `lookup.js`
och `WordDictionary.lookup` är oförändrade), ordkortet läser dem med `WordDictionary.extras`. Går källan inte
att nå byggs ordboken utan dem. Testrapporten visar dem på raderna WIKTIONARY.

`build.py` bygger `out/lasa-ordbok.sqlite` (cirka 50 MB) och en testrapport, `out/testrapport.txt`.
Det kräver wordfreq: `pip install wordfreq==3.1.1`.
Bygget körs i GitHub Actions (jobbet Ordboken i `ios-build.yml`) och databasen läggs in i appen.
Testrapporten laddas upp som artefakten **Ordbok-testrapport**, så att svaren för orden i
`testwords.txt` kan jämföras med svenska.se.

```
python tools/dictionary/build.py
python tools/dictionary/lookup.py tools/dictionary/out/lasa-ordbok.sqlite sprang went kurslitteraturläsning
```

## Källor

| Källa | Används till | Licens |
|---|---|---|
| Folkets synonymlexikon, Synlex (KTH, Viggo Kann), `synpairs.xml` | Svenska synonympar med betyg 3 till 5 | Fri att använda, kopiera och bearbeta med upphovsnotisen kvar |
| Swesaurus (Språkbanken) | Vilken SALDO-betydelse ett Synlex-par hör till | CC BY 4.0 |
| SALDO och SALDO morfologi (Språkbanken) | Grundformer, ordklasser, böjningsformer, betydelser | CC BY 4.0 |
| Open English WordNet 2025 | Engelska betydelser, definitioner, synonymer, oregelbundna former | CC BY 4.0 |
| Folkets lexikon (KTH), `folkets_en_sv_public.xml` | Svensk översättning, oregelbundna engelska former | CC BY-SA 2.5 |
| Folkets lexikon (KTH), `folkets_sv_en_public.xml` | Definitioner på enkel svenska per SALDO-betydelse, och omvända översättningar | CC BY-SA 2.5 |
| wordfreq 3.1.1 (Robyn Speer) | Hur vanliga synonymerna är (Zipf-skalan) | CC BY-SA 4.0, källorna anges under Om ordboken |

Databasen är en bearbetning av Folkets lexikon och wordfreq och delas därför under CC BY-SA 4.0.
Svenska Akademiens data (SO, SAOL) finns inte här. Appen visar dem bara via svenska.se.

## Hur de svenska synonymerna väljs

Den första versionen använde Swesaurus rakt av och gav fel som "avvika" och "bogsera", eller
"giltig" och "ogiltig". Swesaurus har par från flera källor, och bara paren från Synlex har betyg.
Därför:

1. Paren och betygen kommer från Synlex (2020). Bara par med betyg 3,0 eller högre (`MIN_SCORE`).
2. Swesaurus bestämmer bara vilken betydelse paret hör till (källorna `fsl` och `dfsl`).
3. En synonym måste passa ordklassen. Böjda former byts mot grundformen ("riktigt" blir "riktig"),
   former av ordet självt tas bort ("brister" för "brista"), och substantiv blandas inte med verb
   ("ersätta" och "byte"). Adjektiv får ha particip ("giltig" och "gällande").
4. Ett par som Swesaurus inte känner till hamnar i ordets enda betydelse, eller i en grupp utan
   betydelse (`sense_id` tom) som visas sist.

## Vad rutan visar (schema version 2)

Edvin tyckte att den första rutan var förvirrande: allt visades på en gång och engelska ord saknade
ofta svensk översättning. Därför:

* Engelska ord: den svenska översättningen överst. Folkets egna översättningar först. Saknas de används
  omvända par ur den svensk-engelska delen (rank från 500). Saknas de också lånas översättningen från
  den vanligaste synonymen i någon av de tre första betydelserna ("exceedingly" får "ytterst" från "extremely").
* Svenska ord: definitionen ur Folkets lexikon (omkring 8 000 betydelser) med de vanligaste synonymerna.
* Synonymerna sorteras efter vanlighet (svenska: Synlex-betyget plus 0,5 gånger Zipf-värdet).
  Ord under Zipf 2,0 räknas som ovanliga och visas sist. Fem visas direkt, resten bakom ett tryck.

## Schemat

Alla tabeller är vanlig SQLite (`WITHOUT ROWID` med sammansatta nycklar), så att Windows-appen kan
läsa samma fil. Former och `en_sv.en_lemma` är normaliserade: NFKC, raka apostrofer, gemener.

```sql
sv_forms (form, lemma, pos)                       -- SALDO:s ordklasser: nn, vb, av, ab, pp, pn, kn, sn, in, nl, al, ie
sv_synonyms (lemma, pos, sense_id, synonym, score, freq) -- score är Synlex-betyget, freq Zipf-värdet
sv_definitions (lemma, pos, sense_id, rank, definition)    -- Folkets lexikon, sense_id tom när den är okänd
en_forms (form, lemma, pos)                       -- pos: n, v, a, r (och Folkets övriga klasser)
en_senses (lemma, synset_id, pos, rank)           -- rank: WordNets ordning, vanligast först
en_synsets (synset_id, definition)
en_synset_members (synset_id, lemma, rank, freq)
en_sv (en_lemma, rank, sv, pos, comment)          -- rank: Folkets ordning, från 500 omvända par
meta (key, value)                                 -- byggdatum, källornas adresser och sha256
```

## Uppslag (samma i appen, i lookup.py och i Windows-appen)

`App/Dictionary/WordDictionary.swift` och `lookup.py` gör samma sak. Ändras den ena ska den andra
ändras också.

1. Normalisera ordet: NFKC, raka apostrofer, ta bort mjukt bindestreck, gemener, ta bort
   skiljetecken först och sist.
2. Leta i `sv_forms` och i de engelska kandidaterna (nedan). Finns ordet i båda avgör meningen
   (`NLLanguageRecognizer`, begränsad till svenska och engelska). Oavgjort blir svenska.
3. Svenska ord som inte finns: dela som sammansatt ord. Det längsta efterledet som finns, med ett
   förled som också finns (eventuellt med foge-s), vinner. Efterledet slås upp.
4. Engelska kandidater: först `en_forms`, sedan böjningsreglerna nedan, där resultatet måste
   finnas i `en_forms` med regelns ordklass. Saknas formen och stammen slutar på dubbelteckning
   (stopped, bigger) prövas stammen utan den sista bokstaven.

| Ordklass | Regler (ändelse till ersättning) |
|---|---|
| substantiv | s, ses → s, xes → x, zes → z, ches → ch, shes → sh, men → man, ies → y |
| verb | s, ies → y, es → e, es, ed → e, ed, ing → e, ing |
| adjektiv | er, est, er → e, est → e, ier → y, iest → y |

5. Ordning när ett ord kan vara flera: svenska efter (har synonymer, är grundformen själv, flest
   synonymer, ordklass vb nn av ab pp kn sn pn nl in al ie). Engelska efter ordklassen i meningen
   (`NLTagger`), innehåll, grundformen själv, ordklass v n a r.
