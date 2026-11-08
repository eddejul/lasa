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
for BOOK in test.epub test.md test.txt test.rtf test.pdf; do
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

# Fas 6 utan bok: repetition, inställningar, AI-svaret och synken mot en låtsas-Supabase.
echo "== fas6"
EPUB_ID=$(shasum -a 256 "$BOOKS/test.epub" | cut -d' ' -f1)
cat > build/mock_seed.json << SEED
{
  "positions": [{"book_id": "$EPUB_ID", "title": "test", "kind": "reflow", "section": 4, "progression": 0.25,
                 "updated_at": "2030-01-01T10:00:00.123456+00:00"}],
  "highlights": [{"id": "6f1c2d3e-0000-4000-8000-00000000abcd", "book_id": "$EPUB_ID", "section": 1, "start": 5,
                  "length": 12, "text": "från servern", "color": "pink", "note": "", "deleted": false,
                  "created_at": "2030-01-01T10:00:00+00:00", "updated_at": "2030-01-01T10:00:00.5+00:00"}],
  "bookmarks": [],
  "saved_words": [{"lemma": "fjärrord", "language": "sv", "word": "fjärrord", "sentence": "Ett ord från servern.",
                   "book": "Windows", "page": 0, "lookups": 1, "deleted": false, "due": null, "interval": null,
                   "ease": null, "reps": null, "lapses": null, "review_updated_at": null,
                   "created_at": "2030-01-01T10:00:00+00:00", "updated_at": "2030-01-01T10:00:00+00:00"}]
}
SEED
python3 tools/simtest/mock_supabase.py 54321 build/mock_seed.json "$OUT/mock-supabase.json" &
MOCK=$!
sleep 1
rm -f "$DATA/Documents/selftest/fas6.klar"
xcrun simctl launch "$UDID" "$BUNDLE" -LasaSelfTest fas6 -LasaSyncURL http://127.0.0.1:54321
waited=0
while [ ! -f "$DATA/Documents/selftest/fas6.klar" ] && [ $waited -lt 180 ]; do
  sleep 5
  waited=$((waited + 5))
done
if [ -f "$DATA/Documents/selftest/fas6.klar" ]; then
  echo "Klart efter cirka $waited sekunder."
else
  echo "Självtestet för fas 6 blev inte klart inom 180 sekunder."
  status=1
fi
xcrun simctl terminate "$UDID" "$BUNDLE" || true
kill $MOCK 2> /dev/null || true
python3 - "$OUT/mock-supabase.json" << 'SUMMARY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("Låtsasservern efter synken:")
for table, rows in data["tables"].items():
    print(f"  {table}: {len(rows)} rader")
    for row in rows:
        short = {k: v for k, v in row.items() if k not in ("user_id", "created_at")}
        print("    ", json.dumps(short, ensure_ascii=False)[:220])
print("  anrop:", len(data["requests"]))
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
