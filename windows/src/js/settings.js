// Inställningar: synken med iPaden (fas 6). Hur projektet skapas står i docs/SYNK.md.

import { secretGet } from './backend.js';
import { settings } from './store.js';
import { isSignedIn, reportText, signIn, signOut, syncNow, syncState } from './sync.js';
import { el, replace } from './ui.js';

function formatTime(seconds) {
  if (!seconds) return 'aldrig';
  return new Date(seconds * 1000).toLocaleString('sv-SE', { dateStyle: 'medium', timeStyle: 'short' });
}

export async function renderSettings(container) {
  const signedIn = await isSignedIn();
  const key = (await secretGet('sync-publishable-key')) ?? '';
  const message = el('p', { class: 'settings-message', role: 'status', dataset: { testid: 'sync-message' } });
  const field = (label, input, note = null) => el('label', { class: 'settings-field' },
    el('span', { class: 'settings-label' }, label), input, note ? el('span', { class: 'settings-note' }, note) : null);
  const url = el('input', { type: 'url', class: 'text-input', value: settings.syncUrl ?? '', placeholder: 'https://xxxx.supabase.co',
    dataset: { testid: 'sync-url' }, spellcheck: 'false' });
  const publishable = el('input', { type: 'text', class: 'text-input', value: key, placeholder: 'sb_publishable_...',
    dataset: { testid: 'sync-key' }, spellcheck: 'false' });
  const email = el('input', { type: 'email', class: 'text-input', value: settings.syncEmail ?? '', dataset: { testid: 'sync-email' } });
  const password = el('input', { type: 'password', class: 'text-input', value: '', dataset: { testid: 'sync-password' },
    autocomplete: 'current-password' });

  const run = async (button, action) => {
    button.disabled = true;
    message.textContent = '';
    message.classList.remove('error');
    try {
      await action();
    } catch (error) {
      message.textContent = String(error?.message ?? error);
      message.classList.add('error');
      button.disabled = false;
      return false;
    }
    button.disabled = false;
    return true;
  };

  const signInButton = el('button', { class: 'button primary', dataset: { testid: 'sync-sign-in' }, onclick: async () => {
    const ok = await run(signInButton, () => signIn({ url: url.value, key: publishable.value, email: email.value, password: password.value }));
    password.value = '';
    if (!ok) return;
    await renderSettings(container);
    syncNow().catch(() => {});
  } }, 'Logga in');
  const signOutButton = el('button', { class: 'button', dataset: { testid: 'sync-sign-out' }, onclick: async () => {
    await signOut();
    await renderSettings(container);
  } }, 'Logga ut');
  const syncButton = el('button', { class: 'button primary', dataset: { testid: 'sync-now' }, disabled: syncState.running,
    onclick: async () => {
      if (await run(syncButton, () => syncNow())) renderStatus();
    } }, syncState.running ? 'Synkar ...' : 'Synka nu');

  const status = el('div', { class: 'list-group', dataset: { testid: 'sync-status' } });
  const renderStatus = () => {
    const rows = [
      ['Inloggad', signedIn ? `ja, som ${settings.syncEmail || 'okänd e-post'}` : 'nej'],
      ['Senast synkad', formatTime(settings.syncLast)],
      ['Senaste synken', syncState.running ? 'pågår' : (reportText(settings.syncReport) || 'ingen än')],
    ];
    if (settings.syncError) rows.push(['Fel', settings.syncError]);
    replace(status, rows.map(([name, value]) => el('div', { class: 'list-row settings-status-row' },
      el('span', { class: 'list-secondary' }, name), el('span', { class: name === 'Fel' ? 'list-text error' : 'list-text' }, value))));
  };
  renderStatus();

  replace(container, el('div', { class: 'settings' },
    el('section', { class: 'list-section' },
      el('h3', {}, 'Synk med iPaden'),
      el('div', { class: 'list-group settings-form' },
        el('p', { class: 'list-secondary' }, 'Läspositioner och sparade ord synkas med iPaden via ditt eget Supabase-projekt. '
          + 'Hur projektet skapas står i docs/SYNK.md i repot. Markeringar och bokmärken synkas inte till datorn än.'),
        field('Projektets adress', url),
        field('Publik nyckel', publishable, 'Börjar med sb_publishable_ (eller den äldre anon-nyckeln). Använd aldrig secret-nyckeln.'),
        field('E-post', email),
        field('Lösenord', password, 'Lösenordet sparas inte. Inloggningen sparas i Windows Autentiseringshanteraren.'),
        el('div', { class: 'row-buttons settings-buttons' }, signInButton, signedIn ? signOutButton : null,
          signedIn ? syncButton : null),
        message)),
    el('section', { class: 'list-section' },
      el('h3', {}, 'Status'),
      status,
      el('p', { class: 'list-footer' }, 'Läsa synkar när appen startar, när du stänger en bok (högst en gång i minuten) och med Synka nu. '
        + 'En nyare position från iPaden gäller nästa gång boken öppnas, en öppen bok hoppar inte.'))));

  // Statusen följer synken medan vyn visas. En äldre lyssnare för samma ruta tas bort först.
  window.removeEventListener('lasa-sync', container.syncListener);
  const onSync = () => {
    if (!status.isConnected) {
      window.removeEventListener('lasa-sync', onSync);
      return;
    }
    syncButton.disabled = syncState.running;
    syncButton.textContent = syncState.running ? 'Synkar ...' : 'Synka nu';
    renderStatus();
  };
  container.syncListener = onSync;
  window.addEventListener('lasa-sync', onSync);
}
