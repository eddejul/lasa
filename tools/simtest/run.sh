#!/bin/bash
# Simulatortestet: bygger appen för en iPad-simulator, lägger in testböckerna och kör appens självtest
# (-LasaSelfTest) för var och en. Loggar, appens egna bilder och skärmbilder hamnar i build/simtest.
# Körs av jobbet Simulatortest i .github/workflows/ios-build.yml.
set -euo pipefail

OUT=build/simtest
BOOKS=build/testbooks
BUNDLE=se.edvin.lasa
mkdir -p "$OUT" "$BOOKS"

python3 tools/simtest/make_books.py "$BOOKS"
xcodegen generate

UDID=$(xcrun simctl list devices available -j | python3 tools/simtest/pick_device.py)
echo "Simulator: $UDID"

# build-for-testing bygger appen och de automatiska testerna (LasaTests) på en gång.
if ! xcodebuild build-for-testing \
    -project Lasa.xcodeproj \
    -scheme Lasa \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO > "$OUT/xcodebuild.log" 2>&1; then
  echo "Bygget för simulatorn misslyckades:"
  grep -n -E "error:|fatal error" "$OUT/xcodebuild.log" | head -n 80 || tail -n 60 "$OUT/xcodebuild.log"
  exit 1
fi
echo "Bygget för simulatorn gick igenom."

APP=build/dd/Build/Products/Debug-iphonesimulator/Lasa.app
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Documents/Böcker"
cp "$BOOKS"/* "$DATA/Documents/Böcker/"
# G3: en bok i en undermapp, som ska synas i biblioteket.
mkdir -p "$DATA/Documents/Böcker/Kurs"
printf '# Anteckningar\n\nEn kort text i en undermapp, för att se att biblioteket visar den.\n' \
  > "$DATA/Documents/Böcker/Kurs/Anteckningar.md"
# G3: läspositioner sparade under filnamnet, som före bokregistret. Vid första starten ska de flyttas
# till bokens id (självtestet loggar det i test-epub.log och appens logg).
mkdir -p "$DATA/Library/Preferences"
python3 - "$DATA/Library/Preferences/$BUNDLE.plist" << 'PLIST'
import plistlib, sys
plistlib.dump({"location.test.txt": "0|0.0", "positionDate.test.txt": 1700000000.0,
               "positionDate.Anteckningar.md": 1700000000.0}, open(sys.argv[1], "wb"))
PLIST

status=0
for BOOK in test.epub test.md test.txt test.rtf test.pdf foto.pdf foto-text.pdf; do
  [ -f "$BOOKS/$BOOK" ] || { echo "== $BOOK saknas, hoppar över"; continue; }
  STEM="${BOOK//./-}"
  echo "== $BOOK"
  rm -f "$DATA/Documents/selftest/$STEM.klar"
  xcrun simctl launch "$UDID" "$BUNDLE" -LasaSelfTest "$BOOK"
  waited=0
  shot=0
  while [ ! -f "$DATA/Documents/selftest/$STEM.klar" ] && [ $waited -lt 240 ]; do
    sleep 6
    waited=$((waited + 6))
    if [ $shot -lt 6 ]; then
      shot=$((shot + 1))
      xcrun simctl io "$UDID" screenshot "$OUT/$STEM-skarm-$shot.png" > /dev/null 2>&1 || true
    fi
  done
  if [ -f "$DATA/Documents/selftest/$STEM.klar" ]; then
    echo "Klart efter cirka $waited sekunder."
  else
    echo "Självtestet för $BOOK blev inte klart inom 240 sekunder."
    status=1
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE" || true
  sleep 2
done

# Fas 6 utan bok: repetition, inställningar, AI-svaret och synken (F1) via en vanlig mapp i stället för
# iCloud Drive. Mappen får en fil från en påhittad Windows-dator i samma format som windows/src/js/sync.js
# skriver, och tre filer som ska hoppas över: en trasig (halvt hämtad), en tom och en från en nyare version.
echo "== fas6"
EPUB_ID=$(shasum -a 256 "$BOOKS/test.epub" | cut -d' ' -f1)
SYNC="$DATA/Documents/Synkprov/Sensus synk"
rm -rf "$DATA/Documents/Synkprov"
mkdir -p "$SYNC"
cat > "$SYNC/windows-prov.json" << SEED
{
  "format": 1, "app": "Sensus",
  "device": {"id": "windows-prov", "name": "Datorn", "platform": "windows"},
  "written_at": "2030-01-01T10:00:01.000Z",
  "positions": [{"book_id": "$EPUB_ID", "title": "test", "kind": "reflow", "section": 4, "progression": 0.25,
                 "updated_at": "2030-01-01T10:00:00.123Z"}],
  "highlights": [{"id": "6f1c2d3e-0000-4000-8000-00000000abcd", "book_id": "$EPUB_ID", "section": 1, "start": 5,
                  "length": 12, "text": "från Windows", "color": "pink", "note": "", "deleted": false,
                  "created_at": "2030-01-01T10:00:00.000Z", "updated_at": "2030-01-01T10:00:00.500Z"},
                 {"id": "7a000000-0000-4000-8000-0000000000ff", "book_id": "0000000000000000000000000000000000000000000000000000000000000000",
                  "section": 0, "start": 0, "length": 4, "text": "bok som inte finns här", "color": "blue", "note": "",
                  "deleted": false, "created_at": "2030-01-01T10:00:00.000Z", "updated_at": "2030-01-01T10:00:00.000Z"},
                 {"id": "", "book_id": "trasig rad"}],
  "bookmarks": [],
  "saved_words": [{"lemma": "fjärrord", "language": "sv", "word": "fjärrord", "sentence": "Ett ord från datorn.",
                   "book": "Windows", "page": 0, "lookups": 1, "deleted": false, "due": null, "interval": null,
                   "ease": null, "reps": null, "lapses": null, "review_updated_at": null,
                   "created_at": "2030-01-01T10:00:00.000Z", "updated_at": "2030-01-01T10:00:00.000Z"}],
  "framtida_falt": {"ignoreras": true}
}
SEED
printf '{"format": 1, "device": {"id": "trasig", "name": "Halvt hä' > "$SYNC/trasig.json"
: > "$SYNC/tom.json"
printf '{"format": 99, "device": {"id": "framtid", "name": "Ny version"}, "positions": []}' > "$SYNC/framtid.json"
rm -f "$DATA/Documents/selftest/fas6.klar"
xcrun simctl launch "$UDID" "$BUNDLE" -LasaSelfTest fas6
waited=0
while [ ! -f "$DATA/Documents/selftest/fas6.klar" ] && [ $waited -lt 360 ]; do
  sleep 5
  waited=$((waited + 5))
done
if [ -f "$DATA/Documents/selftest/fas6.klar" ]; then
  echo "Klart efter cirka $waited sekunder."
else
  echo "Självtestet för fas 6 blev inte klart inom 360 sekunder."
  status=1
fi
xcrun simctl terminate "$UDID" "$BUNDLE" || true
mkdir -p "$OUT/synkmappen"
cp "$SYNC"/*.json "$OUT/synkmappen/" 2> /dev/null || true
ls -la "$SYNC" > "$OUT/synkmappen/innehall.txt" 2> /dev/null || true
python3 - "$SYNC" << 'SUMMARY'
import json, os, sys
folder = sys.argv[1]
print("Synkmappen efter självtestet:")
for name in sorted(os.listdir(folder)):
    path = os.path.join(folder, name)
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception as error:
        print(f"  {name}: går inte att läsa ({type(error).__name__}), {os.path.getsize(path)} byte")
        continue
    device = data.get("device", {})
    counts = {key: len(data.get(key, [])) for key in ("positions", "highlights", "bookmarks", "saved_words")}
    print(f"  {name}: format {data.get('format')}, {device.get('platform')} {device.get('name')}, {counts}")
SUMMARY

# A1 och U7 utan riktig nyckel: Förklara stycket och nyckelguiden mot en låtsas-Gemini.
echo "== ai"
python3 tools/simtest/mock_gemini.py 54322 "$OUT/mock-gemini.json" &
GEMINI=$!
# Python kan ta en halv minut att starta på byggservern: vänta tills servern svarar (första
# körningen fastnade 35 sekunder i anslutningen).
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:54322/ && break
  sleep 1
done
rm -f "$DATA/Documents/selftest/ai.klar"
xcrun simctl launch "$UDID" "$BUNDLE" -LasaSelfTest ai -LasaGeminiURL http://127.0.0.1:54322
waited=0
shot=0
while [ ! -f "$DATA/Documents/selftest/ai.klar" ] && [ $waited -lt 180 ]; do
  sleep 4
  waited=$((waited + 4))
  # Markeringsraden och rutan som popover syns bara i simctl:s skärmbilder (glas i iOS 26).
  if [ $waited -ge 20 ] && [ $shot -lt 8 ]; then
    shot=$((shot + 1))
    xcrun simctl io "$UDID" screenshot "$OUT/ai-skarm-$shot.png" > /dev/null 2>&1 || true
  fi
done
if [ -f "$DATA/Documents/selftest/ai.klar" ]; then
  echo "Klart efter cirka $waited sekunder."
else
  echo "Självtestet för AI blev inte klart inom 180 sekunder."
  status=1
fi
xcrun simctl terminate "$UDID" "$BUNDLE" || true
kill $GEMINI 2> /dev/null || true
python3 - "$OUT/mock-gemini.json" << 'SUMMARY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("Låtsas-Gemini fick", len(data["requests"]), "anrop:")
for entry in data["requests"]:
    print("  ", entry["method"], entry["path"], entry["key"], "fråga", entry["prompt_length"], "tecken, schema",
          entry["schema"])
longest = max((entry["prompt_length"] for entry in data["requests"]), default=0)
print("  längsta frågan:", longest, "tecken")
SUMMARY

cp -R "$DATA/Documents/selftest/." "$OUT/" 2> /dev/null || true
# Loggen i Filer (G4) och säkerhetskopiorna (G1).
cp -R "$DATA/Documents/Diagnostik" "$OUT/Diagnostik" 2> /dev/null || true
ls -laR "$DATA/Documents/Säkerhetskopia" > "$OUT/sakerhetskopior.txt" 2> /dev/null || true
for LOG in "$OUT"/*.log; do
  case "$LOG" in
    *xcodebuild.log) ;;
    *) echo "---- $LOG"; cat "$LOG" ;;
  esac
done
xcrun simctl spawn "$UDID" log show --last 20m --style compact \
  --predicate 'process == "Lasa"' > "$OUT/systemlogg.txt" 2> /dev/null || true
cp ~/Library/Logs/DiagnosticReports/*Lasa* "$OUT/" 2> /dev/null || true

# Automatiska tester av ren logik (G13): sökningens jämförelse, repetitionen, synkens tider,
# databasernas trappa och utgångsvarningen.
echo "== Automatiska tester (LasaTests)"
if xcodebuild test-without-building \
    -project Lasa.xcodeproj \
    -scheme Lasa \
    -destination "id=$UDID" \
    -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO > "$OUT/xctest.log" 2>&1; then
  echo "Testerna gick igenom."
else
  echo "Testerna misslyckades."
  status=1
fi
grep -E "Test Case .* (passed|failed)|error:|Executed [0-9]+ test" "$OUT/xctest.log" | tail -n 80 || tail -n 40 "$OUT/xctest.log"
exit $status
