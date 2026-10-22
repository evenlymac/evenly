#!/bin/zsh
# Собирает build/Evenly.app (arm64) и подписывает сертификатом "Evenly Dev" (самоподписанный),
# чтобы разрешение на запись системного звука не слетало при пересборке.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP=build/Evenly.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/arm64-apple-macosx/release/Evenly "$APP/Contents/MacOS/Evenly"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.evenly.Evenly</string>
<key>CFBundleName</key><string>Evenly</string>
<key>CFBundleExecutable</key><string>Evenly</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Evenly нормализует громкость системного звука.</string>
</dict></plist>
PL
IDENT="Evenly Dev"
if security find-identity -p codesigning | grep -q "$IDENT"; then
  codesign --force --sign "$IDENT" "$APP"
else
  echo "Сертификат '$IDENT' не найден, подпись ad-hoc (разрешение может слетать)"
  codesign --force --sign - "$APP"
fi
echo "OK: $APP"
