// pdf.js med appens inställningar: arbetaren, teckentabeller, standardtypsnitt och avkodare ligger
// bland appens egna filer (src/vendor/pdfjs), så att inget hämtas från internet.

import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';

const base = new URL('../vendor/pdfjs/', import.meta.url).href;
pdfjs.GlobalWorkerOptions.workerSrc = base + 'pdf.worker.min.mjs';

export { pdfjs };

/** Öppnar en PDF. bytes kopieras, eftersom pdf.js lämnar över bufferten till arbetaren. */
export function openPdf(bytes) {
  return pdfjs.getDocument({
    data: bytes.slice(),
    cMapUrl: base + 'cmaps/',
    cMapPacked: true,
    standardFontDataUrl: base + 'standard_fonts/',
    wasmUrl: base + 'wasm/',
    iccUrl: base + 'iccs/',
    isEvalSupported: false,
    enableXfa: false,
  }).promise;
}

/** Stänger en PDF och dess arbetare. I pdf.js 6 görs det via laddningen, dokumentet har ingen destroy. */
export function closePdf(pdf) {
  return pdf?.loadingTask?.destroy();
}
