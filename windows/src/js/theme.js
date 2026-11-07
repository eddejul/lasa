// Temat: vitt, sepia, mörkt eller Följ systemet (ljust eller mörkt efter Windows inställning).
// Valet sparas i databasen (inställningen theme) och i webbvyns localStorage, som boot.js läser innan
// sidan ritas första gången.

export const THEMES = [
  { id: 'white', title: 'Vitt' },
  { id: 'sepia', title: 'Sepia' },
  { id: 'dark', title: 'Mörkt' },
  { id: 'system', title: 'Följ systemet' },
];

const darkQuery = globalThis.matchMedia ? globalThis.matchMedia('(prefers-color-scheme: dark)') : null;
let choice = 'white';
let listener = null;

/** Temat som faktiskt visas: white, sepia eller dark. */
export function resolvedTheme(theme = choice) {
  if (theme === 'system') return darkQuery?.matches ? 'dark' : 'white';
  return ['white', 'sepia', 'dark'].includes(theme) ? theme : 'white';
}

/** Visar temat. onChange(theme) anropas när Windows byter mellan ljust och mörkt och Följ systemet är valt. */
export function applyTheme(theme, onChange = listener) {
  choice = THEMES.some((t) => t.id === theme) ? theme : 'white';
  listener = onChange;
  document.documentElement.dataset.theme = resolvedTheme();
  try {
    localStorage.setItem('lasa-theme', choice);
  } catch {
    // utan localStorage blir det bara en kort blinkning vid start
  }
}

/** Läsaren vill veta när det visade temat ändras av sig självt (Följ systemet). */
export function setThemeListener(onChange) {
  listener = onChange;
}

darkQuery?.addEventListener?.('change', () => {
  if (choice !== 'system') return;
  document.documentElement.dataset.theme = resolvedTheme();
  listener?.(resolvedTheme());
});
