#!/bin/zsh
# Собирает на Air подписанный Evenly.app и упаковывает dist/Evenly-<версия>.zip и .dmg (локально, без публикации).
set -e
cd "$(dirname "$0")/.."
scripts/air-sync.sh
VER=$(ssh macbookair@MacBookAir.local '/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ~/projects/evenly-sync/build/Evenly.app/Contents/Info.plist')
ssh macbookair@MacBookAir.local "zsh -lic 'cd ~/projects/evenly-sync && rm -rf dist && mkdir -p dist/dmg && cp -R build/Evenly.app dist/dmg/ && ln -s /Applications dist/dmg/Applications && ditto -c -k --keepParent build/Evenly.app dist/Evenly-$VER.zip && hdiutil create -volname Evenly -srcfolder dist/dmg -ov -format UDZO dist/Evenly-$VER.dmg >/dev/null && rm -rf dist/dmg && ls -l dist'"
mkdir -p dist
scp -q macbookair@MacBookAir.local:projects/evenly-sync/dist/Evenly-$VER.\* dist/
ls -l dist
