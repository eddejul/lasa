# Bibliotek som följer med appen

Filerna här är kopior och ska inte ändras för hand.

## foliate-js (EPUB och textfiler)

* Källa: https://github.com/johnfactotum/foliate-js
* Låst commit: `78914aef4466eb960965702401634c2cb348e9b1` (1 maj 2026)
* Licens: MIT, se `foliate-js/LICENSE`.
* Med följer `foliate-js/vendor/zip.js` (zip.js av Gildas Lormeau, BSD 3-Clause, se `foliate-js/vendor/LICENSE-zip.js.txt`).
* Bara de filer som läsaren använder är kopierade: view.js, epub.js, epubcfi.js, paginator.js,
  fixed-layout.js, progress.js, overlayer.js, text-walker.js, search.js och vendor/zip.js.

Byta version: ladda ner `https://codeload.github.com/johnfactotum/foliate-js/tar.gz/<commit>`, kopiera
samma filer och skriv in den nya commiten här.

## pdf.js (PDF)

* Källa: npm-paketet `pdfjs-dist`, version enligt `windows/package.json` (6.4.299), legacy-bygget.
* Licens: Apache License 2.0, se `pdfjs/LICENSE`. Typsnitten i `pdfjs/standard_fonts` och avkodarna
  i `pdfjs/wasm` har egna licensfiler i samma mappar.
* Kopieras med `npm install` och `npm run vendor` (skriptet `windows/tools/vendor.mjs`), som också tar
  ut textlagrets CSS ur `web/pdf_viewer.css` till `pdfjs/textlayer.css`.
