// pdf.js med appens inställningar: arbetaren, teckentabeller, standardtypsnitt och avkodare ligger
// bland appens egna filer (src/vendor/pdfjs), så att inget hämtas från internet.

import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';

const base = new URL('../vendor/pdfjs/', import.meta.url).href;
pdfjs.GlobalWorkerOptions.workerSrc = base + 'pdf.worker.min.mjs';

export { pdfjs };

/** Öppnar en PDF. pdf.js lämnar över bufferten till arbetaren, så att den inte går att använda efteråt.
 *  keep: kopiera först, för den som behöver byten själv efteråt. Utan kopia ligger en stor bok bara en
 *  gång i minnet. */
export function openPdf(bytes, { keep = false } = {}) {
  return pdfjs.getDocument({
    data: keep ? bytes.slice() : bytes,
    cMapUrl: base + 'cmaps/',
    cMapPacked: true,
    standardFontDataUrl: base + 'standard_fonts/',
    wasmUrl: base + 'wasm/',
    iccUrl: base + 'iccs/',
    isEvalSupported: false,
    enableXfa: false,
  }).promise;
}

// Bitarna som en stor PDF läses i: pdf.js slår ihop närliggande bitar till ett anrop.
const RANGE_CHUNK = 512 * 1024;

/** Öppnar en stor PDF utan att läsa hela filen (W4): pdf.js ber om de bitar den behöver, och read(start,
 *  end) hämtar dem från disken. Bara sidorna som visas, och PDF:ens innehållsförteckning, läses. */
export function openPdfRange(length, read) {
  const transport = new pdfjs.PDFDataRangeTransport(length, null);
  transport.requestDataRange = (begin, end) => {
    read(begin, end).then((chunk) => transport.onDataRange(begin, chunk))
      .catch((error) => console.warn('En bit av PDF:en kunde inte läsas', error));
  };
  return pdfjs.getDocument({
    range: transport,
    length,
    rangeChunkSize: RANGE_CHUNK,
    disableAutoFetch: true,
    disableStream: true,
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
