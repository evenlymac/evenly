#!/bin/bash
# Сверка сайта с кодом: ссылки на скачивание живые и версии в тексте совпадают со ссылками, минимальная macOS как в Package.swift,
# функции и обещания из site/facts.tsv. Код выхода 0 = сайт соответствует. Запуск: scripts/docs-check.sh [--offline]
cd "$(dirname "$0")/.."
S=site/index.html; fail=0
bad() { echo "РАСХОЖДЕНИЕ: $*"; fail=1; }
txt=$(sed 's/<[^>]*>/ /g' "$S")
# 1. версии в тексте и ссылках скачивания
for p in "macOS:dmg" "Windows:windows-setup.exe" "Linux:linux-x86_64.tar.gz"; do
  os=${p%%:*}; kind=${p#*:}
  link=$(grep -o "releases/download/v[0-9.]*/Evenly-[0-9.]*-*[a-z0-9._-]*" "$S" | grep -- "$kind" | head -1)
  [ -n "$link" ] || { bad "на сайте нет ссылки на $os (${kind})"; continue; }
  tag=$(echo "$link" | sed -E 's#.*/v([0-9.]+)/.*#\1#'); file=$(echo "$link" | sed -E 's#.*/Evenly-([0-9.]+)[-.].*#\1#')
  [ "$tag" = "$file" ] || bad "$os: тег v$tag и файл $file в ссылке разные"
  if [ "${1:-}" != "--offline" ]; then
    code=$(curl -sIL -o /dev/null -w '%{http_code}' "https://github.com/evenlymac/evenly/$link")
    [ "$code" = 200 ] || bad "$os: ссылка не открывается (HTTP $code): $link"
  fi
done
# 1а. в видимом тексте нет номеров версий (они устаревают; версия живёт в ссылках и подвале «Сайт vX»)
echo "$txt" | sed 's/Сайт v[0-9.]*//' | grep -Eo '(^|[^0-9.])[0-9]+\.[0-9]+\.[0-9]+' | head -3 | grep -q . && bad "в тексте сайта номер версии вида X.Y.Z (по решению пользователя версии в тексте не пишем)"
# 2. минимальная macOS
min=$(grep -o '\.macOS("[0-9.]*")' Package.swift | grep -o '[0-9][0-9.]*')
[ -n "$min" ] && { echo "$txt" | grep -q "macOS $min" || echo "$txt" | grep -q "$min и новее" || bad "минимальная macOS по Package.swift $min, на сайте иначе"; }
# 3. функции и обещания (site/facts.tsv)
while IFS=$'\t' read -r kind glob rx site; do
  case "$kind" in must|never) ;; *) continue ;; esac
  # shellcheck disable=SC2086
  hit=$(grep -lE "$rx" $glob 2>/dev/null | head -1)
  if [ "$kind" = must ]; then
    [ -z "$hit" ] || echo "$txt" | grep -qiE "$site" || bad "в коде есть «${rx}» (${hit}), а сайт не упоминает «${site}»"
  else
    if echo "$txt" | grep -qiE "$site"; then [ -z "$hit" ] || bad "сайт обещает «${site}», а в коде ${hit} найдено «${rx}»"; fi
  fi
done < site/facts.tsv
[ $fail = 0 ] && echo "ок: сайт соответствует коду"
exit $fail
