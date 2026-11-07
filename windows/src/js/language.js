// Svenska eller engelska, efter meningen runt ordet. Används bara när ordet finns i båda språkens
// tabeller (som "a", "under", "far" eller "glass").
//
// iPaden använder Apples språkigenkänning (NLLanguageRecognizer). Den finns inte i Windows-appen, och
// lookup.py har ingen alls. Här räknas i stället vanliga småord som bara finns i det ena språket, och
// ord med å, ä eller ö räknas som svenska. Engelska vinner bara med fler träffar. Oavgjort, eller för
// lite text, blir svenska, som på iPaden.

const SWEDISH = new Set((
  'och att det som en på är av för med till den har de inte om ett var jag så vi från när kan sig '
  + 'han hon där vid eller efter också vara skulle detta dessa hur vad vilket vilka mot utan genom '
  + 'mellan blir blev mycket alla andra även bara här nu då dem deras sina sitt hade inom något '
  + 'några ska vill måste kunde både samt därför eftersom medan dock alltså alltid aldrig ofta'
).split(' '));

const ENGLISH = new Set((
  'the and of to is that it for as was with by on not are this but from or have they which at his '
  + 'her were has had their been would there what when can who will more if no out so said about into '
  + 'than them some could these other its may only also such any after because through should between '
  + 'while however therefore those our we you your my he she does did being where why how'
).split(' '));

const WORD = /[\p{L}']+/gu;

export function guessLanguage(sentence) {
  let swedish = 0;
  let english = 0;
  for (const match of String(sentence).toLowerCase().matchAll(WORD)) {
    const word = match[0];
    if (SWEDISH.has(word) || /[åäö]/.test(word)) swedish += 1;
    else if (ENGLISH.has(word)) english += 1;
  }
  return english > swedish ? 'en' : 'sv';
}
