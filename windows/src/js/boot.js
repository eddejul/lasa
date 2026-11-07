// Körs först av allt, innan sidan ritas: temat sätts direkt, så att fönstret inte blinkar vitt när
// mörkt tema (eller mörkt i Windows med Följ systemet) är valt. Temat finns också i databasen, men den
// hinner inte läsas innan sidan ritas. Vanligt skript (inte modul), eftersom moduler körs senare.
(function () {
  var theme = 'white';
  try {
    theme = window.localStorage.getItem('lasa-theme') || 'white';
  } catch (error) {
    theme = 'white';
  }
  if (theme === 'system') {
    theme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'white';
  }
  if (theme !== 'white' && theme !== 'sepia' && theme !== 'dark') theme = 'white';
  document.documentElement.setAttribute('data-theme', theme);
})();
