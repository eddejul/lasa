// Synken med iPaden (F1): en fil per enhet i en mapp i iCloud Drive, som datorn når via iCloud för Windows.
//
// Formatet och sammanslagningen ligger i syncfile.js, samma som App/Sync/SyncFile.swift och SyncEngine.swift på
// iPaden (docs/SYNK.md). Windows-appen synkar läspositioner (PDF och EPUB) och sparade ord med repetitionen.
// Markeringar och bokmärken från iPaden följer med oförändrade i datorns egen fil men visas inte här än.
//
// Mappen ligger i inställningarna (syncFolder). Filerna läses och skrivs av Rust-delen (sync_* i main.rs), som
// bara når undermappen "Sensus synk" i den valda mappen. Den egna filen skrivs atomiskt och läses tillbaka.

import { syncCheck, syncList, syncRead, syncSetAside, syncWrite } from './backend.js';
import { applySyncedPosition, applySyncedWord, contentId, listBooks, setSetting, settings, wordsForSync } from './store.js';
import {
  ERROR_TEXT, changedRows, changes, decode, emptySnapshot, encode, merge, newest, normalizeWord, rounded, wordKey,
} from './syncfile.js';

export { isoTime, newer, parseTime } from './syncfile.js';

const MIN_INTERVAL = 60; // sekunder mellan automatiska synkar
const HEARTBEAT = 6 * 3600; // den egna filen skrivs om minst så här ofta, så att iPaden ser när datorn synkade

class SyncFailure extends Error {}

/** Den här datorns id i synken, ett UUID som sparas en gång. */
async function device() {
  let id = settings.syncDevice;
  if (typeof id !== 'string' || !id) {
    id = crypto.randomUUID();
    await setSetting('syncDevice', id);
  }
  return { id, name: settings.syncDeviceName || 'Datorn', platform: 'windows' };
}

export const ownFileName = (id) => `${id}.json`;

export function isConfigured() {
  return typeof settings.syncFolder === 'string' && settings.syncFolder.trim() !== '';
}

/** Sparar mappen och provar att skriva och läsa i den. Kastar ett fel med en svensk förklaring. */
export async function chooseFolder(folder) {
  const value = String(folder ?? '').trim().replace(/[\\/]+$/, '');
  if (!value) throw new SyncFailure('Fyll i mappen i iCloud Drive, till exempel C:\\Users\\namn\\iCloudDrive\\Sensus.');
  await syncCheck(value);
  await setSetting('syncFolder', value);
  await setSetting('syncError', null);
}

/** Slutar synka. Ingenting i mappen eller i appen tas bort. */
export async function forgetFolder() {
  await setSetting('syncFolder', null);
  await setSetting('syncError', null);
}

// Läsposition

/** Var boken är, som synken skriver den: PDF sidan från 0, EPUB kapitlet bland bokens dokument och andelen av
 *  kapitlet. Textfiler synkas inte (iPaden delar dem i kapitel på sitt eget sätt). */
function syncedPlace(book) {
  const position = book.position ?? {};
  if (book.format === 'pdf') return Number.isInteger(position.page) ? { section: position.page, progression: 0 } : null;
  if (book.format === 'epub') {
    if (!Number.isInteger(position.section)) return null;
    return { section: position.section, progression: Math.min(Math.max(Number(position.progression) || 0, 0), 1) };
  }
  return null;
}

/** Datorns egen bild: läspositionerna och de sparade orden. */
async function localSnapshot(me, books) {
  const snapshot = emptySnapshot(me, Date.now() / 1000);
  for (const book of books) {
    if (book.format !== 'pdf' && book.format !== 'epub') continue;
    const updated = book.positionUpdated ?? null;
    const place = syncedPlace(book);
    if (updated === null || !place) continue;
    // Synken känner igen böckerna på innehållet: book_id är SHA-256, inte bokens eget id (G3).
    const position = { bookId: contentId(book).toLowerCase(), title: book.title ?? '', kind: book.format === 'pdf' ? 'pdf' : 'reflow',
      section: place.section, progression: rounded(place.progression), updated };
    snapshot.positions.set(position.bookId, newest(snapshot.positions.get(position.bookId), position));
  }
  for (const raw of await wordsForSync()) {
    const word = normalizeWord(raw);
    snapshot.words.set(wordKey(word), word);
  }
  return snapshot;
}

/** Läser alla enheters filer. Filer som inte går att läsa hoppas över med skälet. */
async function readAll(folder) {
  const entries = [];
  for (const { name } of await syncList(folder)) {
    let content;
    try {
      content = await syncRead(folder, name);
    } catch (error) {
      entries.push({ name, error: 'read', reason: String(error?.message ?? error) });
      continue;
    }
    const result = decode(content);
    if (result.error) {
      entries.push({ name, error: result.error, reason: ERROR_TEXT[result.error] });
    } else {
      entries.push({ name, snapshot: result.snapshot,
        reason: result.snapshot.skippedRows ? `${result.snapshot.skippedRows} rader gick inte att läsa` : null });
    }
  }
  return entries;
}

// Synken

export const syncState = { running: false, lastAttempt: 0, peers: [], skipped: [] };

function announce() {
  window.dispatchEvent(new CustomEvent('lasa-sync'));
}

async function run() {
  if (!isConfigured()) throw new SyncFailure('Ingen synkmapp är vald. Välj mappen i iCloud Drive under Inställningar, Synk.');
  const folder = settings.syncFolder;
  const me = await device();
  const ownName = ownFileName(me.id);
  const entries = await readAll(folder);
  // Den lokala bilden tas efter läsningen, så att en ändring medan filerna läses inte skrivs över.
  const books = await listBooks();
  const local = await localSnapshot(me, books);

  let previous = null;
  let setAside = false;
  const remotes = [];
  const skipped = [];
  for (const entry of entries) {
    if (entry.name === ownName) {
      if (entry.snapshot) previous = entry.snapshot;
      else if (entry.error === 'newerFormat') {
        throw new SyncFailure('Datorns synkfil är skriven av en nyare version av Sensus. Uppdatera appen. Filen har inte rörts.');
      } else if (entry.error === 'read') {
        throw new SyncFailure(`Datorns egen synkfil gick inte att läsa (${entry.reason}). Den skrivs inte över. Försök igen om en stund.`);
      } else {
        setAside = true;
        skipped.push(`${entry.name} (den här datorn): ${entry.reason}, sparad undan`);
      }
      continue;
    }
    if (entry.snapshot) {
      remotes.push(entry.snapshot);
      if (entry.reason) skipped.push(`${entry.name}: ${entry.reason}`);
    } else {
      skipped.push(`${entry.name}: ${entry.reason}`);
    }
  }
  for (const line of skipped) console.info('Synken hoppade över', line);

  const now = Date.now() / 1000;
  const merged = merge([local, ...(previous ? [previous] : []), ...remotes], me, now);
  const changed = changes(local, merged);
  const report = { books: books.filter((book) => book.format === 'pdf' || book.format === 'epub').length, pushed: 0, pulled: 0,
    devices: remotes.length,
    skippedFiles: entries.filter((entry) => !entry.snapshot).length };
  for (const position of changed.positions) {
    const targets = books.filter((book) => contentId(book).toLowerCase() === position.bookId
      && (book.format === 'pdf' ? 'pdf' : 'reflow') === position.kind && (book.format === 'pdf' || book.format === 'epub'));
    for (const book of targets) {
      const place = position.kind === 'pdf' ? { page: Math.max(0, position.section) }
        : { section: Math.max(0, position.section), progression: position.progression };
      await applySyncedPosition(book.id, place, position.updated);
    }
    if (targets.length) report.pulled += 1;
  }
  for (const word of changed.words) {
    await applySyncedWord(word);
    report.pulled += 1;
  }
  report.pushed = changedRows(previous, merged);
  if (report.pushed > 0 || !previous || now - previous.written > HEARTBEAT || setAside) {
    if (setAside) await syncSetAside(folder, ownName);
    await syncWrite(folder, ownName, encode(merged));
  }
  syncState.peers = remotes.map((snapshot) => ({ ...snapshot.device, written: snapshot.written }));
  syncState.skipped = skipped;
  return report;
}

/** Synkar nu. Ger rapporten { books, pushed, pulled, devices, skippedFiles }, eller kastar ett fel med en svensk förklaring. */
export async function syncNow() {
  if (syncState.running) return settings.syncReport ?? null;
  syncState.running = true;
  syncState.lastAttempt = Date.now() / 1000;
  announce();
  try {
    const report = await run();
    await setSetting('syncReport', report);
    await setSetting('syncLast', Date.now() / 1000);
    await setSetting('syncError', null);
    return report;
  } catch (error) {
    await setSetting('syncError', String(error?.message ?? error));
    throw error;
  } finally {
    syncState.running = false;
    announce();
  }
}

/** Synkar i bakgrunden om en mapp är vald, högst en gång i minuten (när appen startar och när en bok stängs). */
export async function syncSoon() {
  if (syncState.running || Date.now() / 1000 - syncState.lastAttempt < MIN_INTERVAL) return;
  if (!isConfigured()) return;
  syncNow().catch((error) => console.warn('Synken misslyckades:', error?.message ?? error));
}

export function reportText(report) {
  if (!report) return '';
  const parts = [`${report.books} ${report.books === 1 ? 'bok' : 'böcker'}`,
    `${report.pushed} ändringar sparade i datorns fil`,
    `${report.pulled} hämtade från ${report.devices === 1 ? 'en annan enhet' : `${report.devices ?? 0} andra enheter`}`];
  if (report.skippedFiles) parts.push(report.skippedFiles === 1 ? 'en fil hoppades över' : `${report.skippedFiles} filer hoppades över`);
  return parts.join(', ');
}
