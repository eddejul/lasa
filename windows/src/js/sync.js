// Synken med iPaden (fas 6): läspositioner och sparade ord via Edvins eget Supabase-projekt.
//
// Protokollet står i docs/SYNK.md och tabellerna i tools/supabase/schema.sql. Samma beteende som
// App/Sync/SyncEngine.swift och SyncClient.swift på iPaden: tider jämförs i hela millisekunder, den nyaste
// raden vinner, och för ett sparat ord jämförs ordet och repetitionen var för sig. Borttaget skickas som
// en rad med deleted = true. Markeringar och bokmärken (highlights, bookmarks) läses och skrivs aldrig
// här, Windows-appen har inga än.
//
// Projektets adress, e-post och användarens id ligger i inställningarna. Den publika nyckeln och
// förnyelsetoken ligger i Windows Autentiseringshanteraren (secret_get och secret_set i Rust). Lösenordet
// sparas aldrig, och åtkomsttoken finns bara i minnet.

import { inTauri, secretGet, secretSet } from './backend.js';
import {
  applySyncedPosition, applySyncedWord, contentId, listBooks, setSetting, settings, wordsForSync,
} from './store.js';

const KEY_SECRET = 'sync-publishable-key';
const REFRESH_SECRET = 'sync-refresh-token';
const PAGE_SIZE = 1000;
const BATCH_SIZE = 500;
const MIN_INTERVAL = 60; // sekunder mellan automatiska synkar

// Tider

/** Sekunder sedan 1970 som ISO 8601 i UTC med millisekunder, till exempel 2026-11-07T18:35:07.123Z. */
export function isoTime(seconds) {
  return new Date(Math.round(seconds * 1000)).toISOString();
}

/** Läser en tid ur ett svar. Supabase skriver mikrosekunder och +00:00, de kortas till millisekunder. */
export function parseTime(value) {
  if (typeof value !== 'string' || !value) return null;
  const text = value.replace(/(T\d{2}:\d{2}:\d{2})\.(\d+)/, (_, time, digits) => `${time}.${(digits + '000').slice(0, 3)}`);
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms / 1000;
}

const ms = (seconds) => Math.round(seconds * 1000);

/** Sant om a är nyare än b, räknat i hela millisekunder. Allt är nyare än inget. */
export function newer(a, b) {
  if (a === null || a === undefined) return false;
  if (b === null || b === undefined) return true;
  return ms(a) > ms(b);
}

const int = (value) => (Number.isFinite(Number(value)) && value !== null && value !== '' ? Math.trunc(Number(value)) : 0);
const num = (value) => (value === null || value === undefined || value === '' || !Number.isFinite(Number(value)) ? null : Number(value));

// Inloggning och anrop

class SyncFailure extends Error {}

function failure(status, message) {
  const text = String(message ?? '');
  if (status === 400 && text.toLowerCase().includes('invalid login')) return new SyncFailure('Fel e-post eller lösenord.');
  if (status === 401 || status === 403) return new SyncFailure(`Supabase nekade åtkomst (${status}). Logga in igen. ${text.slice(0, 120)}`);
  if (status === 404) return new SyncFailure(`Tabellen saknas i Supabase. Har schema.sql körts? ${text.slice(0, 120)}`);
  return new SyncFailure(`Supabase svarade med fel ${status}. ${text.slice(0, 160)}`);
}

let access = { token: null, expires: 0 };

/** Fel på svenska om adressen inte är ett Supabase-projekt, annars null. Appen får bara kontakta
 *  https://*.supabase.co (Content-Security-Policy i tauri.conf.json), så en annan adress skulle bara ge
 *  "Ingen kontakt". Provservern (dev/server.py) släpper också fram låtsasservern på 127.0.0.1. */
export function syncUrlProblem(text) {
  const value = String(text ?? '').trim();
  if (!value) return 'Fyll i projektets adress, till exempel https://abcdefgh.supabase.co.';
  let url;
  try {
    url = new URL(value);
  } catch {
    return 'Adressen går inte att läsa. Den ska se ut som https://abcdefgh.supabase.co.';
  }
  if (!inTauri && url.protocol === 'http:' && url.hostname === '127.0.0.1') return null;
  if (url.protocol !== 'https:' || !url.hostname.endsWith('.supabase.co') || url.hostname === '.supabase.co') {
    return 'Adressen ska vara projektets adress hos Supabase, till exempel https://abcdefgh.supabase.co '
      + '(Settings, API Keys i Supabase). Synken kan bara kontakta supabase.co.';
  }
  return null;
}

function baseUrl() {
  const text = String(settings.syncUrl ?? '').trim().replace(/\/+$/, '');
  try {
    const url = new URL(text);
    if ((url.protocol === 'https:' || url.protocol === 'http:') && url.host) return text;
  } catch {
    // ogiltig adress
  }
  return null;
}

async function send(url, options) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30000);
  let response;
  try {
    response = await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    throw new SyncFailure(`Ingen kontakt med Supabase. ${error?.message ?? error}`);
  } finally {
    clearTimeout(timer);
  }
  const text = await response.text();
  if (!response.ok) {
    let message = text;
    try {
      const json = JSON.parse(text);
      message = json.msg ?? json.message ?? json.error_description ?? json.error ?? text;
    } catch {
      // svaret var inte JSON
    }
    throw failure(response.status, message);
  }
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new SyncFailure('Svaret från Supabase gick inte att läsa.');
  }
}

async function authRequest(grant, body) {
  const base = baseUrl();
  const key = await secretGet(KEY_SECRET);
  if (!base || !key) throw new SyncFailure('Synken är inte inställd. Fyll i projektets adress och nyckel.');
  return send(`${base}/auth/v1/token?grant_type=${grant}`, {
    method: 'POST',
    headers: { apikey: key, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function storeSession(json) {
  const token = json?.access_token;
  const refresh = json?.refresh_token;
  const user = json?.user?.id;
  if (!token || !refresh || !user) throw new SyncFailure('Svaret från Supabase gick inte att läsa.');
  access = { token, expires: Date.now() / 1000 + (Number(json.expires_in) || 3600) };
  await secretSet(REFRESH_SECRET, refresh);
  await setSetting('syncUser', user);
}

export async function isSignedIn() {
  if (!baseUrl() || !settings.syncUser) return false;
  return Boolean(await secretGet(KEY_SECRET)) && Boolean(await secretGet(REFRESH_SECRET));
}

/** Loggar in med e-post och lösenord. Adressen och nyckeln sparas först. Lösenordet sparas aldrig. */
export async function signIn({ url, key, email, password }) {
  const problem = syncUrlProblem(url);
  if (problem) throw new SyncFailure(problem);
  await setSetting('syncUrl', String(url ?? '').trim().replace(/\/+$/, ''));
  await secretSet(KEY_SECRET, String(key ?? '').trim());
  await setSetting('syncEmail', String(email ?? '').trim());
  const json = await authRequest('password', { email: String(email ?? '').trim(), password });
  await storeSession(json);
}

export async function signOut() {
  access = { token: null, expires: 0 };
  await secretSet(REFRESH_SECRET, null);
  await setSetting('syncUser', null);
}

/** En giltig åtkomsttoken. Förnyas en minut innan den går ut. Förnyelsetoken byts varje gång. */
async function accessToken() {
  if (access.token && Date.now() / 1000 < access.expires - 60) return access.token;
  const refresh = await secretGet(REFRESH_SECRET);
  if (!refresh) throw new SyncFailure('Logga in under Inställningar för att synka.');
  await storeSession(await authRequest('refresh_token', { refresh_token: refresh }));
  return access.token;
}

async function restHeaders() {
  return {
    apikey: await secretGet(KEY_SECRET),
    Authorization: `Bearer ${await accessToken()}`,
    Accept: 'application/json',
  };
}

/** Alla rader i en tabell som den inloggade får se, i omgångar om tusen. */
async function rows(table) {
  const result = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const page = await send(`${baseUrl()}/rest/v1/${table}?select=*&order=updated_at.asc&limit=${PAGE_SIZE}&offset=${offset}`,
      { method: 'GET', headers: await restHeaders() });
    if (!Array.isArray(page)) throw new SyncFailure('Svaret från Supabase gick inte att läsa.');
    result.push(...page);
    if (page.length < PAGE_SIZE) return result;
  }
}

/** Lägger in eller skriver över rader. onConflict är kolumnerna som gör en rad unik. */
async function upsert(list, table, onConflict) {
  for (let start = 0; start < list.length; start += BATCH_SIZE) {
    await send(`${baseUrl()}/rest/v1/${table}?on_conflict=${onConflict}`, {
      method: 'POST',
      headers: { ...(await restHeaders()), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(list.slice(start, start + BATCH_SIZE)),
    });
  }
}

// Läsposition

/** Var boken är, som synken skriver den: PDF sidan från 0, EPUB kapitlet bland bokens dokument och
 *  andelen av kapitlet. Textfiler synkas inte (iPaden delar dem i kapitel på sitt eget sätt). */
function syncedPlace(book) {
  const position = book.position ?? {};
  if (book.format === 'pdf') return Number.isInteger(position.page) ? { section: position.page, progression: 0 } : null;
  if (book.format === 'epub') {
    if (!Number.isInteger(position.section)) return null;
    return { section: position.section, progression: Math.min(Math.max(Number(position.progression) || 0, 0), 1) };
  }
  return null;
}

async function syncPositions(user, report) {
  const remote = await rows('positions');
  const byBook = new Map(remote.map((row) => [row.book_id, row]));
  const push = [];
  for (const book of await listBooks()) {
    if (book.format !== 'pdf' && book.format !== 'epub') continue;
    report.books += 1;
    const kind = book.format === 'pdf' ? 'pdf' : 'reflow';
    const local = book.positionUpdated ?? null;
    // Synken känner igen böckerna på innehållet: book_id är SHA-256, inte bokens eget id (G3).
    const row = byBook.get(contentId(book));
    const remoteDate = parseTime(row?.updated_at);
    if (row && remoteDate !== null && newer(remoteDate, local) && row.kind === kind) {
      const position = kind === 'pdf'
        ? { page: Math.max(0, int(row.section)) }
        : { section: Math.max(0, int(row.section)), progression: Math.min(Math.max(num(row.progression) ?? 0, 0), 1) };
      await applySyncedPosition(book.id, position, remoteDate);
      report.pulled += 1;
    } else if (local !== null && newer(local, remoteDate)) {
      const place = syncedPlace(book);
      if (!place) continue;
      push.push({ user_id: user, book_id: contentId(book), title: book.title, kind, section: place.section,
        progression: place.progression, updated_at: isoTime(local) });
    }
  }
  if (push.length) {
    await upsert(push, 'positions', 'user_id,book_id');
    report.pushed += push.length;
  }
}

// Sparade ord och repetition

const wordKey = (word) => `${word.language}\u0000${word.lemma}`;

function wordFromRow(row) {
  const updated = parseTime(row.updated_at);
  if (typeof row.lemma !== 'string' || typeof row.language !== 'string' || updated === null) return null;
  return {
    lemma: row.lemma,
    language: row.language,
    word: typeof row.word === 'string' ? row.word : row.lemma,
    sentence: typeof row.sentence === 'string' ? row.sentence : '',
    book: typeof row.book === 'string' ? row.book : '',
    page: int(row.page),
    lookups: Math.max(int(row.lookups), 1),
    created: parseTime(row.created_at) ?? updated,
    updated,
    deleted: row.deleted === true,
    due: num(row.due),
    interval: num(row.interval),
    ease: num(row.ease),
    reps: num(row.reps) === null ? null : int(row.reps),
    lapses: num(row.lapses) === null ? null : int(row.lapses),
    reviewUpdated: parseTime(row.review_updated_at),
  };
}

function rowFromWord(word, user) {
  return {
    user_id: user, lemma: word.lemma, language: word.language, word: word.word, sentence: word.sentence,
    book: word.book, page: word.page, lookups: word.lookups, created_at: isoTime(word.created),
    updated_at: isoTime(word.updated), deleted: Boolean(word.deleted),
    due: word.due ?? null, interval: word.interval ?? null, ease: word.ease ?? null, reps: word.reps ?? null,
    lapses: word.lapses ?? null, review_updated_at: word.reviewUpdated == null ? null : isoTime(word.reviewUpdated),
  };
}

const REVIEW_FIELDS = ['due', 'interval', 'ease', 'reps', 'lapses', 'reviewUpdated'];

async function syncWords(user, report) {
  const remote = new Map();
  for (const row of await rows('saved_words')) {
    const word = wordFromRow(row);
    if (word) remote.set(wordKey(word), word);
  }
  const local = new Map((await wordsForSync()).map((word) => [wordKey(word), word]));
  const push = [];
  for (const key of new Set([...remote.keys(), ...local.keys()])) {
    const mine = local.get(key) ?? null;
    const theirs = remote.get(key) ?? null;
    const wordFromRemote = theirs !== null && newer(theirs.updated, mine?.updated);
    const wordFromLocal = mine !== null && !wordFromRemote && newer(mine.updated, theirs?.updated);
    const reviewFromRemote = newer(theirs?.reviewUpdated, mine?.reviewUpdated);
    const reviewFromLocal = !reviewFromRemote && newer(mine?.reviewUpdated, theirs?.reviewUpdated);
    const base = (wordFromRemote ? theirs : mine) ?? theirs;
    if (!base) continue;
    const merged = { ...base };
    const reviewSource = reviewFromRemote ? theirs : (reviewFromLocal ? mine : (wordFromRemote ? theirs : mine));
    if (merged.deleted) {
      for (const field of REVIEW_FIELDS) merged[field] = null;
    } else if (reviewSource) {
      for (const field of REVIEW_FIELDS) merged[field] = reviewSource[field] ?? null;
    }
    if (wordFromRemote || (reviewFromRemote && !merged.deleted)) {
      await applySyncedWord(merged);
      report.pulled += 1;
    }
    if (wordFromLocal || (reviewFromLocal && !merged.deleted) || (theirs === null && mine !== null)) {
      push.push(rowFromWord(merged, user));
    }
  }
  if (push.length) {
    await upsert(push, 'saved_words', 'user_id,lemma,language');
    report.pushed += push.length;
  }
}

// Synken

export const syncState = { running: false, lastAttempt: 0 };

function announce() {
  window.dispatchEvent(new CustomEvent('lasa-sync'));
}

/** Synkar nu. Ger rapporten { books, pushed, pulled }, eller kastar ett fel med en svensk förklaring. */
export async function syncNow() {
  if (syncState.running) return settings.syncReport ?? null;
  syncState.running = true;
  syncState.lastAttempt = Date.now() / 1000;
  announce();
  try {
    if (!(await isSignedIn())) throw new SyncFailure('Logga in under Inställningar för att synka.');
    const user = settings.syncUser;
    const report = { books: 0, pushed: 0, pulled: 0 };
    await syncPositions(user, report);
    await syncWords(user, report);
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

/** Synkar i bakgrunden om man är inloggad, högst en gång i minuten (när appen startar och när en bok
 *  stängs). Utan inställningar händer ingenting. */
export async function syncSoon() {
  if (syncState.running || Date.now() / 1000 - syncState.lastAttempt < MIN_INTERVAL) return;
  if (!(await isSignedIn())) return;
  syncNow().catch((error) => console.warn('Synken misslyckades:', error?.message ?? error));
}

export function reportText(report) {
  if (!report) return '';
  return `${report.books} ${report.books === 1 ? 'bok' : 'böcker'}, ${report.pushed} ändringar skickade, ${report.pulled} hämtade`;
}
