// Anropen till Rust-delen. I appen går de genom Tauri, i en vanlig webbläsare (provkörning med
// windows/dev/server.py) genom HTTP till /api/<kommando> med samma namn och argument.

const tauri = globalThis.__TAURI__?.core ?? null;

export const inTauri = Boolean(tauri);

async function http(command, args) {
  const response = await fetch(`/api/${command}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(args ?? {}),
  });
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

export async function invoke(command, args = {}) {
  return tauri ? tauri.invoke(command, args) : http(command, args);
}

/** Ordboken: rader som listor. */
export const dictionaryDb = {
  all: (sql, params = []) => invoke('dict_query', { sql, params }),
};

/** Användarens databaser (sparade ord och biblioteket). Bara de namngivna frågorna i
 *  src-tauri/statements.json går att ställa, aldrig egen SQL (W12). */
export const userDb = {
  /** Rader som listor, kolumnerna i frågans ordning. */
  read: (name, params = []) => invoke('db_read', { name, params }),
  /** Ger antalet ändrade rader. */
  write: (name, params = []) => invoke('db_write', { name, params }),
};

export async function storeBookFile(id, ext, bytes) {
  if (tauri) {
    return tauri.invoke('library_store', bytes, { headers: { 'x-id': id, 'x-ext': ext } });
  }
  const response = await fetch('/api/library_store', {
    method: 'POST', headers: { 'x-id': id, 'x-ext': ext }, body: bytes,
  });
  if (!response.ok) throw new Error(await response.text());
  return null;
}

export async function readBookFile(id, ext) {
  if (tauri) {
    const data = await tauri.invoke('library_read', { id, ext });
    return data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data);
  }
  const response = await fetch('/api/library_read', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, ext }),
  });
  if (!response.ok) throw new Error(await response.text());
  return new Uint8Array(await response.arrayBuffer());
}

/** Storleken på en bokfil i byte. */
export async function bookFileSize(id, ext) {
  return invoke('library_size', { id, ext });
}

/** En bit av en bokfil, från start till (men inte med) end. */
export async function readBookRange(id, ext, start, end) {
  if (tauri) {
    const data = await tauri.invoke('library_read_range', { id, ext, start, end });
    return new Uint8Array(data);
  }
  const response = await fetch('/api/library_read_range', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, ext, start, end }),
  });
  if (!response.ok) throw new Error(await response.text());
  return new Uint8Array(await response.arrayBuffer());
}

export async function deleteBookFile(id, ext) {
  return invoke('library_delete', { id, ext });
}

/** Synkens hemligheter (sync-publishable-key, sync-refresh-token) i Windows Autentiseringshanteraren. */
export async function secretGet(name) {
  return invoke('secret_get', { name });
}

/** Sparar en hemlighet. null eller tom text tar bort den. */
export async function secretSet(name, value) {
  return invoke('secret_set', { name, value: value || null });
}

/** Böcker som Windows har gett appen (Öppna med i Utforskaren): [{ name }]. Listan töms när den hämtas. */
export async function pendingTake() {
  return invoke('pending_take');
}

/** En av böckerna från pendingTake, som byte. */
export async function pendingRead(index) {
  if (tauri) {
    const data = await tauri.invoke('pending_read', { index });
    return new Uint8Array(data);
  }
  const response = await fetch('/api/pending_read', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ index }),
  });
  if (!response.ok) throw new Error(await response.text());
  return new Uint8Array(await response.arrayBuffer());
}

/** Anropar callback när Windows ger appen fler böcker medan den är öppen. */
export function onOpenFiles(callback) {
  globalThis.__TAURI__?.event?.listen('lasa-open-files', () => callback());
}

/** Öppnar en adress i den vanliga webbläsaren (svenska.se, källorna under Om ordboken). */
export async function openUrl(url) {
  if (tauri) return tauri.invoke('plugin:opener|open_url', { url });
  return http('open_url', { url });
}
