#!/bin/zsh
# Живая проверка локализации на Air: запускает собранный Evenly.app на русском и английском, читает пункты меню строки меню,
# падает, если в русском меню остались английские пункты или в английском русские. Нужны разрешение Accessibility для ssh и build/Evenly.app (scripts/air-sync.sh).
set -e
cd "$(dirname "$0")/.."
ssh macbookair@MacBookAir.local 'zsh -l' <<'REMOTE'
APP=~/projects/evenly-sync/build/Evenly.app/Contents/MacOS/Evenly
menu() {  # $1 = en|ru
  pkill -x Evenly; sleep 1
  "$APP" -AppleLanguages "($1)" -AppleLocale "$1" >/dev/null 2>&1 &
  sleep 6
  osascript -e 'tell application "System Events" to tell process "Evenly" to click menu bar item 1 of menu bar 2' >/dev/null
  sleep 1
  osascript -e 'tell application "System Events" to tell process "Evenly" to return name of every menu item of menu 1 of menu bar item 1 of menu bar 2'
  osascript -e 'tell application "System Events" to key code 53' >/dev/null
}
ru=$(menu ru); en=$(menu en)
pkill -x Evenly; sleep 1; open ~/projects/evenly-sync/build/Evenly.app
echo "ru: $ru"; echo "en: $en"
bad=0
for item in ${(s:, :)ru}; do [[ $item == "missing value" ]] && continue; [[ $item =~ '[А-Яа-я]' ]] || { echo "НЕ ПЕРЕВЕДЕНО (ru): $item"; bad=1; }; done
for item in ${(s:, :)en}; do [[ $item == "missing value" ]] && continue; [[ $item =~ '[А-Яа-я]' ]] && { echo "РУССКИЙ В en: $item"; bad=1; }; done
[ $bad = 0 ] && echo "OK: меню переведено на оба языка"
exit $bad
REMOTE
