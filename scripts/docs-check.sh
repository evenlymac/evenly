#!/bin/bash
# Сверка сайта с кодом: ссылки на скачивание живые и версии в тексте совпадают со ссылками, минимальная macOS как в Package.swift,
# функции и обещания из site/facts.tsv. Проверяются обе страницы: ru (site/index.html) и en (site/en/index.html).
# Код выхода 0 = сайт соответствует. Запуск: scripts/docs-check.sh [--offline]
cd "$(dirname "$0")/.."
offline=${1:-}   # аргумент скрипта: внутри check_page $1 уже язык страницы
fail=0
bad() { echo "РАСХОЖДЕНИЕ [$LANG_]: $*"; fail=1; }
check_page() {
LANG_=$1; S=$2
txt=$(sed 's/<[^>]*>/ /g' "$S")
# 1. версии в тексте и ссылках скачивания
for p in "macOS:dmg" "Windows:windows-setup.exe" "Linux:linux-x86_64.tar.gz"; do
  os=${p%%:*}; kind=${p#*:}
  link=$(grep -o "releases/download/v[0-9.]*/Evenly-[0-9.]*-*[a-z0-9._-]*" "$S" | grep -- "$kind" | head -1)
  [ -n "$link" ] || { bad "на сайте нет ссылки на $os (${kind})"; continue; }
  tag=$(echo "$link" | sed -E 's#.*/v([0-9.]+)/.*#\1#'); file=$(echo "$link" | sed -E 's#.*/Evenly-([0-9.]+)[-.].*#\1#')
  [ "$tag" = "$file" ] || bad "$os: тег v$tag и файл $file в ссылке разные"
  if [ "$offline" != "--offline" ]; then
    code=$(curl -sIL -o /dev/null -w '%{http_code}' "https://github.com/evenlymac/evenly/$link")
    [ "$code" = 200 ] || bad "$os: ссылка не открывается (HTTP $code): $link"
  fi
done
# 1а. в видимом тексте нет номеров версий (они устаревают; версия живёт в ссылках и подвале «Сайт vX»)
echo "$txt" | sed -E 's/(Сайт|Site) v[0-9.]*//' | grep -Eo '(^|[^0-9.])[0-9]+\.[0-9]+\.[0-9]+|Evenly [0-9]+\.[0-9]+' | head -3 | grep -q . && bad "в тексте сайта номер версии вида X.Y.Z или «Evenly X.Y» (по решению пользователя версии в тексте не пишем)"
# 2. минимальная macOS
min=$(grep -o '\.macOS("[0-9.]*")' Package.swift | grep -o '[0-9][0-9.]*')
[ -n "$min" ] && { echo "$txt" | grep -q "macOS $min" || echo "$txt" | grep -q "$min и новее" || echo "$txt" | grep -q "$min or later" || bad "минимальная macOS по Package.swift $min, на сайте иначе"; }
# 2а. названия пунктов меню, упомянутые на странице, совпадают с i18n/strings.json (id в списке ниже)
for id in toggle; do
  want=$(python3 -I -c "import json,sys;print(next(e[sys.argv[2]] for e in json.load(open('i18n/strings.json'))['strings'] if e['id']==sys.argv[1]))" "$id" "$LANG_")
  echo "$txt" | grep -qF "$want" || bad "на странице нет названия пункта меню «$want» (id $id из i18n/strings.json)"
done
# 3. функции и обещания (site/facts.tsv)
while IFS=$'\t' read -r kind glob rx site_ru site_en; do
  case "$kind" in must|never) ;; *) continue ;; esac
  if [ "$LANG_" = en ]; then site=$site_en; else site=$site_ru; fi
  [ -n "$site" ] || { bad "в site/facts.tsv у «${rx}» нет колонки для языка $LANG_"; continue; }
  # shellcheck disable=SC2086
  hit=$(grep -lE "$rx" $glob 2>/dev/null | head -1)
  if [ "$kind" = must ]; then
    [ -z "$hit" ] || echo "$txt" | grep -qiE "$site" || bad "в коде есть «${rx}» (${hit}), а сайт не упоминает «${site}»"
  else
    if echo "$txt" | grep -qiE "$site"; then [ -z "$hit" ] || bad "сайт обещает «${site}», а в коде ${hit} найдено «${rx}»"; fi
  fi
done < site/facts.tsv
}
check_page ru site/index.html
check_page en site/en/index.html
[ $fail = 0 ] && echo "ок: сайт (ru и en) соответствует коду"
exit $fail
