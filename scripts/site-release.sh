#!/bin/sh
# Повышает версию сайта: site/VERSION, номер в подвале обеих страниц (генератор scripts/i18n-gen.py), запись в site/CHANGELOG.md.
# usage: scripts/site-release.sh patch|minor|major "что изменилось"
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 patch|minor|major \"что изменилось\"" >&2; exit 2; }
old=$(cat site/VERSION)
IFS=. read -r a b c <<V
$old
V
case "$1" in
  major) a=$((a+1)); b=0; c=0 ;;
  minor) b=$((b+1)); c=0 ;;
  patch) c=$((c+1)) ;;
  *) echo "первый аргумент: patch|minor|major" >&2; exit 2 ;;
esac
new="$a.$b.$c"
echo "$new" > site/VERSION
python3 -I scripts/i18n-gen.py >/dev/null   # подставляет версию в обе страницы из site/VERSION
tmp=$(mktemp)
{ sed -n 1,4p site/CHANGELOG.md; printf '\n## %s — %s\n- %s\n' "$new" "$(date +%F)" "$2"; sed -n '5,$p' site/CHANGELOG.md; } > "$tmp"
mv "$tmp" site/CHANGELOG.md
echo "$old -> $new"
