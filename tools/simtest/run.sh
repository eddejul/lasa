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

if ! xcodebuild build \
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

cp -R "$DATA/Documents/selftest/." "$OUT/" 2> /dev/null || true
for LOG in "$OUT"/*.log; do
  case "$LOG" in
    *xcodebuild.log) ;;
    *) echo "---- $LOG"; cat "$LOG" ;;
  esac
done
xcrun simctl spawn "$UDID" log show --last 20m --style compact \
  --predicate 'process == "Lasa"' > "$OUT/systemlogg.txt" 2> /dev/null || true
cp ~/Library/Logs/DiagnosticReports/*Lasa* "$OUT/" 2> /dev/null || true
exit $status
