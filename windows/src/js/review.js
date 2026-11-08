// Repetitionen av sparade ord (W5): exakt samma schema som iPaden, ReviewSchedule och reviewQueue i
// App/Dictionary/UserWords.swift. Ändras schemat där ska det ändras här i samma commit, och testet
// windows/tests/review.test.mjs jämför (det läser också Swift-koden och säger till om den har ändrats).

import { normalize } from './lookup.js';

export const NEW_PER_DAY = 20;
export const MINIMUM_EASE = 1.3;
const DAY = 86400;

// U6: småord (funktionsord) som aldrig sparas och aldrig repeteras. Samma listor som ReviewStopWords i
// UserWords.swift, och review.test.mjs jämför dem.
export const STOP_WORDS = {
  sv: new Set([
    'att', 'och', 'i', 'på', 'som', 'är', 'en', 'ett', 'det', 'den', 'de', 'dem', 'av', 'för', 'med', 'till',
    'från', 'om', 'men', 'eller', 'så', 'inte', 'också', 'har', 'hade', 'haft', 'ha', 'var', 'varit', 'blir',
    'bli', 'blev', 'blivit', 'kan', 'kunde', 'ska', 'skall', 'skulle', 'vill', 'ville', 'måste', 'jag', 'du',
    'han', 'hon', 'hen', 'vi', 'ni', 'sig', 'sin', 'sitt', 'sina', 'din', 'ditt', 'dina', 'hans', 'hennes',
    'deras', 'vår', 'vårt', 'våra', 'er', 'ert', 'mig', 'dig', 'honom', 'henne', 'oss', 'denna', 'detta',
    'dessa', 'där', 'här', 'nu', 'då', 'när', 'vad', 'vem', 'vilken', 'vilket', 'vilka', 'hur', 'varför', 'än',
    'efter', 'mot', 'utan', 'genom', 'hos', 'mellan', 'ut', 'upp', 'in', 'ner', 'ju', 'nog', 'bara', 'mycket',
    'många', 'alla', 'allt', 'något', 'någon', 'några', 'inget', 'ingen', 'inga', 'eftersom', 'medan', 'både',
    'samt', 'ej', 'ens', 'väl', 'redan', 'dock',
  ]),
  en: new Set([
    'the', 'a', 'an', 'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with', 'from', 'into', 'onto', 'about', 'and',
    'or', 'but', 'nor', 'if', 'as', 'than', 'then', 'so', 'not', 'no', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'am', 'do', 'does', 'did', 'have', 'has', 'had', 'could', 'would', 'should', 'might', 'shall', 'it',
    'its', 'this', 'that', 'these', 'those', 'i', 'you', 'he', 'she', 'we', 'they', 'me', 'him', 'her', 'us',
    'them', 'my', 'your', 'his', 'our', 'their', 'there', 'here', 'what', 'which', 'who', 'whom', 'whose',
    'when', 'where', 'why', 'how', 'up', 'out', 'all', 'any', 'some', 'each', 'also', 'very', 'too', 'because',
    'while',
  ]),
};

/** Sant om ordet som det stod i texten, eller dess grundform, är ett småord på ordets språk. */
export function isStopWord(word, lemma, language) {
  const list = language === 'en' ? STOP_WORDS.en : STOP_WORDS.sv;
  return list.has(normalize(word ?? '')) || list.has(normalize(lemma ?? ''));
}

export const GRADES = [
  { id: 'again', title: 'Igen' },
  { id: 'hard', title: 'Svårt' },
  { id: 'good', title: 'Bra' },
  { id: 'easy', title: 'Lätt' },
];

/** Nästa intervall i ett enkelt schema i stil med Anki: ett ord man kan kommer tillbaka allt mer sällan,
 *  ett ord man glömt kommer tillbaka om tio minuter. U6: Igen, Svårt, Bra och Lätt ger alltid allt längre
 *  tid, också för ett nytt ord (10 min, 6 tim, 1 dag, 4 dagar). Ger { interval (dagar), ease, reps, lapse }. */
export function nextReview(grade, { interval, ease, reps }) {
  const good = reps === 0 ? 1 : (reps === 1 ? Math.max(3, interval * ease) : Math.max(interval * ease, interval + 1));
  switch (grade) {
    case 'again':
      return { interval: 10 / 1440, ease: Math.max(MINIMUM_EASE, ease - 0.2), reps: 0, lapse: reps > 0 };
    case 'hard':
      // Ett nytt ord är fortfarande nytt efter Svårt och kommer tillbaka om sex timmar.
      if (reps === 0) return { interval: 0.25, ease: Math.max(MINIMUM_EASE, ease - 0.15), reps: 0, lapse: false };
      return { interval: Math.max(1, interval * 1.2), ease: Math.max(MINIMUM_EASE, ease - 0.15), reps: reps + 1, lapse: false };
    case 'good':
      return { interval: good, ease, reps: reps + 1, lapse: false };
    case 'easy': {
      const days = reps === 0 ? 4 : Math.max(good * 1.3, interval + 2);
      return { interval: days, ease: ease + 0.15, reps: reps + 1, lapse: false };
    }
    default:
      throw new Error(`Okänt betyg: ${grade}`);
  }
}

// Swift rundar .5 bort från noll, som Math.round för positiva tal.
const swiftRound = (value) => Math.sign(value) * Math.round(Math.abs(value));

/** "10 min", "6 tim", "1 dag", "3 dagar", "2 veckor", "4 mån". */
export function intervalLabel(days) {
  if (days < 1) {
    const minutes = Math.max(1, Math.trunc(swiftRound(days * 1440)));
    return minutes < 60 ? `${minutes} min` : `${Math.trunc(swiftRound(days * 24))} tim`;
  }
  const whole = Math.trunc(swiftRound(days));
  if (whole < 14) return whole === 1 ? '1 dag' : `${whole} dagar`;
  if (whole < 60) return `${Math.trunc(swiftRound(days / 7))} veckor`;
  if (whole < 365) return `${Math.trunc(swiftRound(days / 30))} mån`;
  const years = days / 365;
  return years < 1.5 ? '1 år' : `${years.toFixed(1).replace('.', ',')} år`;
}

/** Midnatt i dag (lokal tid) i sekunder, som Calendar.current.startOfDay. */
export function startOfDay(now) {
  const date = new Date(now * 1000);
  date.setHours(0, 0, 0, 0);
  return date.getTime() / 1000;
}

/** Orden att repetera nu: först de som är på tur (äldst först), sedan nya ord (de äldsta), högst 20 nya
 *  per dag. words: sparade ord med senast ändrade först, med due, interval, ease, reps, lapses och
 *  introduced (när ordet repeterades första gången) för ord som har repeterats. U6: småord kommer inte med
 *  (iPaden hoppar dessutom över ord som ordboken inte har något svar för). */
export function buildQueue(words, now, limit = 200) {
  const midnight = startOfDay(now);
  let introducedToday = 0;
  const due = [];
  const fresh = [];
  for (const word of words) {
    if (isStopWord(word.word, word.lemma, word.language)) {
      // Ett småord som repeterats före U6 räknas ändå bland orden som påbörjats i dag, som på iPaden.
      if (word.due !== null && word.due !== undefined && (word.introduced ?? 0) >= midnight) introducedToday += 1;
      continue;
    }
    if (word.due !== null && word.due !== undefined) {
      if ((word.introduced ?? 0) >= midnight) introducedToday += 1;
      if (word.due <= now) {
        due.push({ word, interval: word.interval ?? 0, ease: word.ease ?? 2.5, reps: word.reps ?? 0, lapses: word.lapses ?? 0, isNew: false });
      }
    } else {
      fresh.push({ word, interval: 0, ease: 2.5, reps: 0, lapses: 0, isNew: true });
    }
  }
  const newAllowed = Math.max(0, NEW_PER_DAY - introducedToday);
  due.sort((a, b) => a.word.due - b.word.due);
  return due.concat(fresh.reverse().slice(0, newAllowed)).slice(0, limit);
}

/** Det som sparas efter ett betyg: { due, interval, ease, reps, lapses } och antalet dagar. */
export function graded(grade, card, now) {
  const next = nextReview(grade, card);
  return {
    due: now + next.interval * DAY, interval: next.interval, ease: next.ease, reps: next.reps,
    lapses: card.lapses + (next.lapse ? 1 : 0),
  };
}

/** Kortet kommer igen i slutet av omgången efter Igen, som på iPaden. */
export function againCard(card) {
  return { word: card.word, interval: 10 / 1440, ease: Math.max(1.3, card.ease - 0.2), reps: 0, lapses: card.lapses + 1, isNew: false };
}
