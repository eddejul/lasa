// Repetitionen av sparade ord (W5): exakt samma schema som iPaden, ReviewSchedule och reviewQueue i
// App/Dictionary/UserWords.swift. Ändras schemat där ska det ändras här i samma commit, och testet
// windows/tests/review.test.mjs jämför (det läser också Swift-koden och säger till om den har ändrats).

export const NEW_PER_DAY = 20;
export const MINIMUM_EASE = 1.3;
const DAY = 86400;

export const GRADES = [
  { id: 'again', title: 'Igen' },
  { id: 'hard', title: 'Svårt' },
  { id: 'good', title: 'Bra' },
  { id: 'easy', title: 'Lätt' },
];

/** Nästa intervall i ett enkelt schema i stil med Anki: ett ord man kan kommer tillbaka allt mer sällan,
 *  ett ord man glömt kommer tillbaka om tio minuter. Ger { interval (dagar), ease, reps, lapse }. */
export function nextReview(grade, { interval, ease, reps }) {
  switch (grade) {
    case 'again':
      return { interval: 10 / 1440, ease: Math.max(MINIMUM_EASE, ease - 0.2), reps: 0, lapse: reps > 0 };
    case 'hard':
      return { interval: reps === 0 ? 1 : Math.max(1, interval * 1.2), ease: Math.max(MINIMUM_EASE, ease - 0.15), reps: reps + 1, lapse: false };
    case 'good': {
      const days = reps === 0 ? 1 : (reps === 1 ? 3 : Math.max(interval * ease, interval + 1));
      return { interval: days, ease, reps: reps + 1, lapse: false };
    }
    case 'easy': {
      const days = reps === 0 ? 4 : Math.max(interval * ease * 1.3, interval + 2);
      return { interval: days, ease: ease + 0.15, reps: reps + 1, lapse: false };
    }
    default:
      throw new Error(`Okänt betyg: ${grade}`);
  }
}

// Swift rundar .5 bort från noll, som Math.round för positiva tal.
const swiftRound = (value) => Math.sign(value) * Math.round(Math.abs(value));

/** "10 min", "1 dag", "3 dagar", "2 veckor", "4 mån". */
export function intervalLabel(days) {
  if (days < 1) return `${Math.max(1, Math.trunc(swiftRound(days * 1440)))} min`;
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
 *  introduced (när ordet repeterades första gången) för ord som har repeterats. */
export function buildQueue(words, now, limit = 200) {
  const midnight = startOfDay(now);
  let introducedToday = 0;
  const due = [];
  const fresh = [];
  for (const word of words) {
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
