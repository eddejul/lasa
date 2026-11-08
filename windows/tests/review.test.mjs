// Repetitionen på Windows (src/js/review.js) mot iPadens schema (App/Dictionary/UserWords.swift).
//   node --test windows/tests/review.test.mjs
//
// Två slags kontroller:
// * Facit: svaren nedan är uträknade för hand ur formlerna i ReviewSchedule.next och label i Swift.
// * Swift-koden: testet läser UserWords.swift och jämför ReviewSchedule och kön med en kopia här. Ändras
//   schemat på iPaden går testet sönder, så att review.js (och kopian) ändras i samma commit.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  NEW_PER_DAY, STOP_WORDS, againCard, buildQueue, graded, intervalLabel, isStopWord, nextReview, startOfDay,
} from '../src/js/review.js';

const close = (a, b) => Math.abs(a - b) < 1e-9;

test('nästa intervall: samma formler som ReviewSchedule.next', () => {
  const cases = [
    // [betyg, interval, ease, reps] -> [interval, ease, reps, lapse]
    ['again', 0, 2.5, 0, 10 / 1440, 2.3, 0, false],
    ['again', 12, 1.4, 5, 10 / 1440, 1.3, 0, true],
    // U6: Svårt för ett nytt ord är sex timmar, och ordet är fortfarande nytt (reps 0).
    ['hard', 0, 2.5, 0, 0.25, 2.35, 0, false],
    ['hard', 0.5, 1.35, 2, 1, 1.3, 3, false],
    ['hard', 10, 2.5, 3, 12, 2.35, 4, false],
    ['hard', 4, 2.65, 1, 4.8, 2.5, 2, false],
    ['good', 0, 2.5, 0, 1, 2.5, 1, false],
    ['good', 1, 2.5, 1, 3, 2.5, 2, false],
    ['good', 3, 2.5, 2, 7.5, 2.5, 3, false],
    ['good', 1, 1.3, 2, 2, 1.3, 3, false],
    // Efter Lätt på ett nytt ord (4 dagar) blir Bra längre än Svårt: 4 * 2,65 = 10,6.
    ['good', 4, 2.65, 1, 10.6, 2.65, 2, false],
    ['easy', 0, 2.5, 0, 4, 2.65, 1, false],
    ['easy', 3, 2.5, 2, 9.75, 2.65, 3, false],
    ['easy', 1, 1.3, 3, 3, 1.45, 4, false],
    // Lätt är alltid längre än Bra: Bra 3 dagar gånger 1,3.
    ['easy', 0.25, 2.35, 1, 3.9, 2.5, 2, false],
  ];
  for (const [grade, interval, ease, reps, wantInterval, wantEase, wantReps, wantLapse] of cases) {
    const next = nextReview(grade, { interval, ease, reps });
    assert.ok(close(next.interval, wantInterval), `${grade} ${interval}: interval ${next.interval} != ${wantInterval}`);
    assert.ok(close(next.ease, wantEase), `${grade} ${interval}: ease ${next.ease} != ${wantEase}`);
    assert.equal(next.reps, wantReps);
    assert.equal(next.lapse, wantLapse);
  }
});

test('Igen, Svårt, Bra och Lätt ger alltid allt längre tid (U6)', () => {
  for (const reps of [0, 1, 2, 5]) {
    for (const interval of [10 / 1440, 0.25, 1, 3, 4, 10, 40]) {
      for (const ease of [1.3, 1.7, 2.5, 3]) {
        const days = ['again', 'hard', 'good', 'easy'].map((grade) => nextReview(grade, { interval, ease, reps }).interval);
        for (let i = 1; i < days.length; i++) {
          assert.ok(days[i] > days[i - 1], `reps ${reps}, ${interval} dagar, ease ${ease}: ${days.join(' ')}`);
        }
      }
    }
  }
});

test('etiketterna: samma som ReviewSchedule.label', () => {
  const cases = [[10 / 1440, '10 min'], [0.0001, '1 min'], [59 / 1440, '59 min'], [1 / 24, '1 tim'], [0.25, '6 tim'],
    [1, '1 dag'], [3, '3 dagar'], [13.4, '13 dagar'], [14, '2 veckor'],
    [45, '6 veckor'], [60, '2 mån'], [200, '7 mån'], [400, '1 år'], [600, '1,6 år']];
  for (const [days, label] of cases) assert.equal(intervalLabel(days), label, `${days} dagar`);
});

test('sparat efter betyg: nästa gång, och en miss räknas bara för ett ord man kunnat', () => {
  const now = 1_800_000_000;
  const saved = graded('good', { interval: 3, ease: 2.5, reps: 2, lapses: 1 }, now);
  assert.ok(close(saved.due, now + 7.5 * 86400));
  assert.equal(saved.lapses, 1);
  assert.equal(graded('again', { interval: 3, ease: 2.5, reps: 2, lapses: 1 }, now).lapses, 2);
  assert.equal(graded('again', { interval: 0, ease: 2.5, reps: 0, lapses: 0 }, now).lapses, 0);
  const again = againCard({ word: {}, interval: 3, ease: 1.4, reps: 2, lapses: 1, isNew: false });
  assert.deepEqual([again.interval, again.ease, again.reps, again.lapses, again.isNew], [10 / 1440, 1.3, 0, 2, false]);
});

test('kön: ord på tur först (äldst först), sedan högst 20 nya per dag med de äldsta först', () => {
  const now = 1_800_000_000;
  const midnight = startOfDay(now);
  const words = [];
  // Senast ändrade först, som saved_words ORDER BY updated DESC.
  for (let i = 0; i < 30; i++) words.push({ lemma: `nytt${i}`, due: null });
  words.push({ lemma: 'senare', due: now + 100, introduced: midnight - 10 });
  words.push({ lemma: 'tur2', due: now - 10, introduced: midnight + 5, interval: 1, ease: 2.5, reps: 1, lapses: 0 });
  words.push({ lemma: 'tur1', due: now - 500, introduced: midnight + 6, interval: 3, ease: 2.5, reps: 2, lapses: 0 });
  const queue = buildQueue(words, now);
  assert.deepEqual(queue.slice(0, 2).map((c) => c.word.lemma), ['tur1', 'tur2']);
  // Två ord påbörjades i dag, så 18 nya ryms, de äldsta (sist i listan) först.
  assert.equal(queue.length, 2 + NEW_PER_DAY - 2);
  assert.equal(queue[2].word.lemma, 'nytt29');
  assert.ok(queue.slice(2).every((c) => c.isNew && c.ease === 2.5 && c.reps === 0));
});

test('småord sparas aldrig och kommer inte med i kön (U6)', () => {
  for (const word of ['att', 'Det', 'och', 'i', 'på', 'är', 'att,']) assert.ok(isStopWord(word, word, 'sv'), word);
  for (const word of ['the', 'The', 'of', 'was']) assert.ok(isStopWord(word, word, 'en'), word);
  assert.ok(isStopWord('Dem', 'de', 'sv'));
  for (const [word, lemma] of [['kunskap', 'kunskap'], ['varor', 'vara'], ['min', 'min']]) {
    assert.ok(!isStopWord(word, lemma, 'sv'), word);
  }
  assert.ok(!isStopWord('den', 'den', 'en'));
  const now = 1_800_000_000;
  const midnight = startOfDay(now);
  const words = [
    { word: 'att', lemma: 'att', language: 'sv', due: null },
    { word: 'kunskap', lemma: 'kunskap', language: 'sv', due: null },
    { word: 'the', lemma: 'the', language: 'en', due: now - 10, introduced: midnight + 5, interval: 1, ease: 2.5, reps: 1, lapses: 0 },
  ];
  assert.deepEqual(buildQueue(words, now).map((c) => c.word.lemma), ['kunskap']);
});

test('småordslistorna är desamma som i UserWords.swift', () => {
  const path = fileURLToPath(new URL('../../App/Dictionary/UserWords.swift', import.meta.url));
  let source;
  try {
    source = readFileSync(path, 'utf8');
  } catch {
    return;
  }
  for (const [name, language] of [['swedish', 'sv'], ['english', 'en']]) {
    const match = source.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`));
    assert.ok(match, `${name} saknas i ReviewStopWords`);
    const swift = [...match[1].matchAll(/"([^"]*)"/g)].map((m) => m[1]).sort();
    assert.deepEqual([...STOP_WORDS[language]].sort(), swift, `småorden (${language}) skiljer sig från UserWords.swift`);
  }
});

// Swift-koden som review.js är en kopia av. Blanktecken räknas inte.
const SWIFT_SCHEDULE = `
    static let newPerDay = 20
    static let minimumEase = 1.3

    static func next(_ grade: ReviewGrade, interval: Double, ease: Double, reps: Int)
        -> (interval: Double, ease: Double, reps: Int, lapse: Bool) {
        let good: Double = reps == 0 ? 1 : (reps == 1 ? max(3, interval * ease) : max(interval * ease, interval + 1))
        switch grade {
        case .again:
            return (10.0 / 1440.0, max(minimumEase, ease - 0.2), 0, reps > 0)
        case .hard:
            if reps == 0 {
                return (0.25, max(minimumEase, ease - 0.15), 0, false)
            }
            return (max(1, interval * 1.2), max(minimumEase, ease - 0.15), reps + 1, false)
        case .good:
            return (good, ease, reps + 1, false)
        case .easy:
            let days: Double = reps == 0 ? 4 : max(good * 1.3, interval + 2)
            return (days, ease + 0.15, reps + 1, false)
        }
    }
`;
// U6: etiketten under en dag (minuter eller timmar).
const SWIFT_LABEL = `
        if days < 1 {
            let minutes = max(1, Int((days * 1440).rounded()))
            return minutes < 60 ? "\\(minutes) min" : "\\(Int((days * 24).rounded())) tim"
        }
`;
const SWIFT_QUEUE_TAIL = `
        let newAllowed = max(0, ReviewSchedule.newPerDay - introducedToday)
        let cards = due.sorted { $0.0 < $1.0 }.map { $0.1 } + Array(fresh.reversed().prefix(newAllowed))
        return Array(cards.prefix(limit))
`;

test('UserWords.swift har samma schema som review.js', () => {
  const path = fileURLToPath(new URL('../../App/Dictionary/UserWords.swift', import.meta.url));
  let source;
  try {
    source = readFileSync(path, 'utf8');
  } catch {
    // iOS-koden finns inte i den här utcheckningen.
    return;
  }
  const squeeze = (text) => text.replace(/\s+/g, '');
  assert.ok(squeeze(source).includes(squeeze(SWIFT_SCHEDULE)),
    'ReviewSchedule i UserWords.swift har ändrats: ändra review.js och kopian i det här testet');
  assert.ok(squeeze(source).includes(squeeze(SWIFT_QUEUE_TAIL)),
    'reviewQueue i UserWords.swift har ändrats: ändra buildQueue i review.js och kopian i det här testet');
  assert.ok(squeeze(source).includes(squeeze(SWIFT_LABEL)),
    'ReviewSchedule.label i UserWords.swift har ändrats: ändra intervalLabel i review.js och kopian i det här testet');
});
