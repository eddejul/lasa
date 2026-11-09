// Inställningar: synken med iPaden via en mapp i iCloud Drive (F1, docs/SYNK.md), AI-nyckeln och Gör sökbar.

import { secretGet, secretSet, syncSuggest } from './backend.js';
import { DEFAULT_MODEL, GEMINI_SECRET, testKey } from './gemini.js';
import { DEFAULT_PYTHON, DEFAULT_TESSERACT, checkOcr, missingLines, saveOcrTools } from './ocr.js';
import { setSetting, settings } from './store.js';
import { chooseFolder, forgetFolder, isConfigured, reportText, syncNow, syncState } from './sync.js';
import { el, replace } from './ui.js';

function formatTime(seconds) {
  if (!seconds) return 'aldrig';
  return new Date(seconds * 1000).toLocaleString('sv-SE', { dateStyle: 'medium', timeStyle: 'short' });
}

export async function renderSettings(container) {
  const configured = isConfigured();
  const message = el('p', { class: 'settings-message', role: 'status', dataset: { testid: 'sync-message' } });
  const field = (label, input, note = null) => el('label', { class: 'settings-field' },
    el('span', { class: 'settings-label' }, label), input, note ? el('span', { class: 'settings-note' }, note) : null);
  const folder = el('input', { type: 'text', class: 'text-input', value: settings.syncFolder ?? '',
    placeholder: 'C:\\Users\\namn\\iCloudDrive\\Sensus', dataset: { testid: 'sync-folder' }, spellcheck: 'false' });

  const run = async (button, action) => {
    button.disabled = true;
    message.textContent = '';
    message.classList.remove('error', 'success');
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

  // Hitta iCloud Drive: mappen med en synkmapp först, annars iCloud Drive själv.
  const findButton = el('button', { class: 'button', dataset: { testid: 'sync-find' }, onclick: async () => {
    const found = await syncSuggest();
    if (found.length) {
      folder.value = found[0];
      message.classList.remove('error');
      message.textContent = found.length > 1 && !found[0].toLowerCase().endsWith('iclouddrive')
        ? 'Mappen med Sensus synk hittades. Tryck Spara och prova.'
        : 'iCloud Drive hittades. Lägg till mappen du valde på iPaden (till exempel \\Sensus) och tryck Spara och prova.';
    } else {
      message.textContent = 'iCloud Drive hittades inte. Installera iCloud för Windows och slå på iCloud Drive, eller skriv in mappen.';
      message.classList.add('error');
    }
  } }, 'Hitta iCloud Drive');
  const saveButton = el('button', { class: 'button primary', dataset: { testid: 'sync-save' }, onclick: async () => {
    const ok = await run(saveButton, () => chooseFolder(folder.value));
    if (!ok) return;
    await renderSettings(container);
    const done = container.querySelector('[data-testid="sync-message"]');
    if (done) {
      done.textContent = 'Mappen fungerar. Sensus kunde skriva och läsa där.';
      done.classList.add('success');
    }
    syncNow().catch(() => {});
  } }, 'Spara och prova');
  const forgetButton = el('button', { class: 'button', dataset: { testid: 'sync-forget' }, onclick: async () => {
    await forgetFolder();
    await renderSettings(container);
  } }, 'Sluta synka');
  const syncButton = el('button', { class: 'button primary', dataset: { testid: 'sync-now' }, disabled: syncState.running,
    onclick: async () => {
      if (await run(syncButton, () => syncNow())) renderStatus();
    } }, syncState.running ? 'Synkar ...' : 'Synka nu');

  const status = el('div', { class: 'list-group', dataset: { testid: 'sync-status' } });
  const renderStatus = () => {
    const rows = [
      ['Mappen', configured ? settings.syncFolder : 'ingen vald'],
      ['Senast synkad', formatTime(settings.syncLast)],
      ['Senaste synken', syncState.running ? 'pågår' : (reportText(settings.syncReport) || 'ingen än')],
    ];
    for (const peer of syncState.peers) {
      rows.push([peer.platform === 'ios' ? 'iPad eller iPhone' : 'Annan dator',
        `${peer.name || 'utan namn'}, senast ${formatTime(peer.written)}`]);
    }
    for (const line of syncState.skipped) rows.push(['Hoppades över', line]);
    if (settings.syncError) rows.push(['Fel', settings.syncError]);
    replace(status, rows.map(([name, value]) => el('div', { class: 'list-row settings-status-row' },
      el('span', { class: 'list-secondary' }, name), el('span', { class: name === 'Fel' ? 'list-text error' : 'list-text' }, value))));
  };
  renderStatus();

  // Förklaring med AI (W11): nyckeln i Autentiseringshanteraren, modellen som inställning.
  const geminiKey = (await secretGet(GEMINI_SECRET)) ?? '';
  const aiKey = el('input', { type: 'password', class: 'text-input', value: geminiKey, placeholder: 'AIza...', spellcheck: 'false',
    autocomplete: 'off', dataset: { testid: 'ai-key' } });
  const aiModelField = el('input', { type: 'text', class: 'text-input', value: settings.aiModel ?? '', placeholder: DEFAULT_MODEL,
    spellcheck: 'false', dataset: { testid: 'ai-model' } });
  const aiMessage = el('p', { class: 'settings-message', role: 'status', dataset: { testid: 'ai-message' } });
  const saveAI = async () => {
    await secretSet(GEMINI_SECRET, aiKey.value.trim() || null);
    await setSetting('aiModel', aiModelField.value.trim() || null);
  };
  const aiSave = el('button', { class: 'button primary', dataset: { testid: 'ai-save' }, onclick: async () => {
    aiMessage.classList.remove('error');
    await saveAI();
    aiMessage.textContent = aiKey.value.trim() ? 'Sparat. Knappen Förklara i meningen finns nu i ordrutan.' : 'Nyckeln är borttagen.';
  } }, 'Spara');
  const aiTest = el('button', { class: 'button', dataset: { testid: 'ai-test' }, onclick: async () => {
    aiMessage.classList.remove('error');
    const key = aiKey.value.trim();
    if (!key) {
      aiMessage.textContent = 'Skriv in en nyckel först.';
      return;
    }
    await saveAI();
    aiMessage.textContent = 'Frågar Gemini ...';
    try {
      await testKey(key);
      aiMessage.textContent = `Nyckeln fungerar med ${settings.aiModel || DEFAULT_MODEL}.`;
    } catch (error) {
      aiMessage.textContent = String(error?.message ?? error);
      aiMessage.classList.add('error');
    }
  } }, 'Prova nyckeln');

  // Gör sökbar (P1): sökvägarna till Python, Tesseract och mappen med språkmodellerna.
  const ocrPython = el('input', { type: 'text', class: 'text-input', value: settings.ocrPython ?? '', placeholder: DEFAULT_PYTHON,
    spellcheck: 'false', dataset: { testid: 'ocr-python' } });
  const ocrTesseract = el('input', { type: 'text', class: 'text-input', value: settings.ocrTesseract ?? '',
    placeholder: DEFAULT_TESSERACT, spellcheck: 'false', dataset: { testid: 'ocr-tesseract' } });
  const ocrTessdata = el('input', { type: 'text', class: 'text-input', value: settings.ocrTessdata ?? '',
    placeholder: 'Tesseracts egen mapp (tessdata bredvid tesseract.exe)', spellcheck: 'false', dataset: { testid: 'ocr-tessdata' } });
  const ocrMessage = el('div', { class: 'settings-message', role: 'status', dataset: { testid: 'ocr-message' } });
  const ocrCheck = el('button', { class: 'button primary', dataset: { testid: 'ocr-check' }, onclick: async () => {
    ocrCheck.disabled = true;
    ocrMessage.classList.remove('error');
    ocrMessage.textContent = 'Kontrollerar ...';
    try {
      await saveOcrTools({ python: ocrPython.value, tesseract: ocrTesseract.value, tessdata: ocrTessdata.value });
      const result = await checkOcr();
      if (result.ok) {
        ocrMessage.textContent = `Allt finns: Python ${result.python}, Tesseract ${result.tesseract}, svenska i ${result.tessdata}. `
          + 'Knappen Gör sökbar finns under varje PDF i biblioteket.';
      } else {
        replace(ocrMessage, missingLines(result).map((line) => el('p', {}, line)));
        ocrMessage.classList.add('error');
      }
    } catch (error) {
      ocrMessage.textContent = String(error?.message ?? error);
      ocrMessage.classList.add('error');
    }
    ocrCheck.disabled = false;
  } }, 'Spara och kontrollera');

  replace(container, el('div', { class: 'settings' },
    el('section', { class: 'list-section' },
      el('h3', {}, 'Gör sökbar (OCR)'),
      el('div', { class: 'list-group settings-form' },
        el('p', { class: 'list-secondary' }, 'Gör sökbar läser skannade PDF:er med Tesseract på datorn och lägger texten osynligt '
          + 'på sidorna, i spaltordning, i en ny fil bredvid originalet. Det behövs Python 3 med PyMuPDF, numpy och Pillow, '
          + 'Tesseract OCR och den svenska modellen swe.traineddata.'),
        field('Python', ocrPython, `Tomt betyder ${DEFAULT_PYTHON} (det som finns i PATH). Annars hela sökvägen till python.exe.`),
        field('Tesseract', ocrTesseract, 'Tomt betyder Tesseract i Program Files, eller i PATH.'),
        field('Mapp med språkmodeller', ocrTessdata, 'Mappen där swe.traineddata ligger. Tomt betyder Tesseracts egen tessdata-mapp.'),
        el('div', { class: 'row-buttons settings-buttons' }, ocrCheck),
        ocrMessage)),
    el('section', { class: 'list-section' },
      el('h3', {}, 'Förklaring med AI'),
      el('div', { class: 'list-group settings-form' },
        field('API-nyckel', aiKey, 'En gratis nyckel skapas i Google AI Studio (aistudio.google.com, Get API key). '
          + 'Nyckeln sparas bara i Windows Autentiseringshanteraren.'),
        field('Modell', aiModelField, `Tomt betyder ${DEFAULT_MODEL}, som på iPaden.`),
        el('div', { class: 'row-buttons settings-buttons' }, aiSave, aiTest),
        aiMessage),
      el('p', { class: 'list-footer' }, 'Knappen Förklara i meningen i ordrutan använder Google Gemini. Meningen och ordet '
        + 'skickas till Google, och på gratisnivån får Google använda det för att förbättra sina tjänster. Utan nyckel syns '
        + 'ingen AI-knapp.')),
    el('section', { class: 'list-section' },
      el('h3', {}, 'Synk med iPaden'),
      el('div', { class: 'list-group settings-form' },
        el('p', { class: 'list-secondary' }, 'Läspositioner och sparade ord synkas med iPaden via en mapp i iCloud Drive, '
          + 'med en liten fil per enhet. Inget konto och ingen nyckel. Installera iCloud för Windows, slå på iCloud Drive och '
          + 'välj samma mapp som på iPaden (Inställningar, Synk). Markeringar och bokmärken från iPaden följer med i '
          + 'filen men visas inte på datorn än.'),
        field('Mappen i iCloud Drive', folder, 'Sensus skriver bara i undermappen Sensus synk. Inget tas bort för att en '
          + 'fil saknas eller inte går att läsa.'),
        el('div', { class: 'row-buttons settings-buttons' }, findButton, saveButton, configured ? syncButton : null,
          configured ? forgetButton : null),
        message)),
    el('section', { class: 'list-section' },
      el('h3', {}, 'Status'),
      status,
      el('p', { class: 'list-footer' }, 'Sensus synkar när appen startar, när du stänger en bok (högst en gång i minuten) och med Synka nu. '
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
