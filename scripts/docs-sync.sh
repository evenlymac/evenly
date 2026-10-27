#!/bin/bash
# Правило «поведение изменили, значит сайт сверили»: если в диапазоне коммитов (BASE..HEAD) тронуты файлы поведения, то либо менялся site/,
# либо в сообщении одного из коммитов есть строка «Site: …» (например «Site: не затрагивает, правка внутри ядра»). usage: docs-sync.sh BASE [HEAD]
cd "$(dirname "$0")/.."
base=${1:?usage: docs-sync.sh BASE [HEAD]}; head=${2:-HEAD}
git cat-file -e "$base" 2>/dev/null || { echo "docs-sync: нет базового коммита, пропускаю"; exit 0; }
files=$(git diff --name-only "$base" "$head")
beh=$(echo "$files" | grep -E '^(i18n/|Sources/|Resources/.*\.strings|core/src/|windows/(tray|apo)/src/|windows/install(er)?/|windows/package/|linux/(pcm/src/|evenly-linux\.sh)|Package\.swift)' | grep -v "^Tests/" )
[ -n "$beh" ] || { echo "ок: поведение не менялось"; exit 0; }
echo "$files" | grep -q '^site/' && { echo "ок: менялся site/"; exit 0; }
git log --format=%B "$base..$head" | grep -Eq '^Site: ' && { echo "ок: есть строка Site: в сообщении коммита"; exit 0; }
echo "СИНХРОНИЗАЦИЯ САЙТА: изменено поведение, а сайт не тронут и нет строки «Site:» в коммите."
echo "Файлы поведения:"; echo "$beh" | sed 's/^/  /'
echo "Сверь site/index.html с изменением (что программа делает, меню, версии, ограничения): поправь сайт (scripts/site-release.sh) или допиши в сообщение коммита: «Site: не затрагивает, <причина>»."
exit 1
