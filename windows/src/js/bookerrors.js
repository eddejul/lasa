// Begripliga fel när en bok inte går att läsa: låsta och trasiga PDF:er, trasiga EPUB-filer.

/** Sant om felet betyder att filen aldrig kommer att gå att öppna (då läggs den inte till). */
export function isUnreadable(error) {
  return ['PasswordException', 'InvalidPDFException', 'FormatError', 'UnreadableBook'].includes(error?.name);
}

/** Ett fel för en EPUB eller textfil som inte går att läsa. */
export function unreadable(message) {
  const error = new Error(message);
  error.name = 'UnreadableBook';
  return error;
}

/** Felet på svenska. name är filens eller bokens namn. */
export function bookErrorMessage(error, name) {
  switch (error?.name) {
    case 'PasswordException':
      return `${name} är låst med lösenord, och låsta PDF:er går inte att öppna här. `
        + 'Spara en kopia utan lösenord (till exempel med Skriv ut och Microsoft Print to PDF) och lägg till kopian.';
    case 'InvalidPDFException':
    case 'FormatError':
      return `${name} är trasig eller ingen riktig PDF, så den går inte att öppna. Prova att hämta eller exportera filen igen.`;
    case 'UnreadableBook':
      return `${name}: ${error.message}`;
    default:
      return `${name} kunde inte öppnas (${error?.message ?? error}).`;
  }
}
