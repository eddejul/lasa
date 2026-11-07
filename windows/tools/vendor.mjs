// Kopierar pdf.js (pdfjs-dist, låst version i package.json) till src/vendor/pdfjs.
//
//   npm install && npm run vendor
//   node tools/vendor.mjs <mapp med pdfjs-dist>      (om paketet redan är uppackat någon annanstans)
//
// foliate-js hämtas för hand vid en låst commit, se src/vendor/VENDOR.md.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const source = process.argv[2] ?? path.join(root, 'node_modules', 'pdfjs-dist');
const target = path.join(root, 'src', 'vendor', 'pdfjs');

const pkg = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
const wanted = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).devDependencies['pdfjs-dist'];
if (pkg.version !== wanted) {
  throw new Error(`pdfjs-dist ${pkg.version} hittades, package.json kräver ${wanted}`);
}

fs.rmSync(target, { recursive: true, force: true });
fs.mkdirSync(target, { recursive: true });
const copy = (from, to = from) => fs.cpSync(path.join(source, from), path.join(target, to), { recursive: true });
copy('LICENSE');
// Legacy-bygget har ersättare för de nyaste JavaScript-funktionerna (som Map.getOrInsertComputed),
// så att PDF fungerar även om WebView2 på datorn ligger några versioner efter.
copy('legacy/build/pdf.min.mjs', 'pdf.min.mjs');
copy('legacy/build/pdf.worker.min.mjs', 'pdf.worker.min.mjs');
copy('cmaps');
copy('standard_fonts');
copy('iccs');
copy('wasm');
// Skriptmotorn för PDF-formulär med JavaScript används inte.
for (const name of fs.readdirSync(path.join(target, 'wasm'))) {
  if (name.startsWith('quickjs')) fs.rmSync(path.join(target, 'wasm', name));
}

// Textlagrets regler ur web/pdf_viewer.css (blocket som börjar med ".textLayer {").
const css = fs.readFileSync(path.join(source, 'web', 'pdf_viewer.css'), 'utf8');
const start = css.indexOf('\n.textLayer {');
if (start < 0) throw new Error('Hittade inte .textLayer i pdf_viewer.css');
let depth = 0;
let end = -1;
for (let i = css.indexOf('{', start); i < css.length; i++) {
  if (css[i] === '{') depth += 1;
  else if (css[i] === '}') {
    depth -= 1;
    if (depth === 0) {
      end = i + 1;
      break;
    }
  }
}
const header = `/* Ur pdfjs-dist ${pkg.version}, web/pdf_viewer.css. Apache License 2.0, se LICENSE i samma mapp. */\n`;
fs.writeFileSync(path.join(target, 'textlayer.css'), header + css.slice(start + 1, end) + '\n');
fs.writeFileSync(path.join(target, 'VERSION'), `pdfjs-dist ${pkg.version}\n`);
console.log(`pdf.js ${pkg.version} kopierat till ${path.relative(root, target)}`);
