#!/bin/bash
# Проверка перед релизом: нет блокировки (~/.claude/evenly-ci/release.blocked) и CI на HEAD main зелёный. Код выхода 0 = можно.
cd "$(dirname "$0")/.."; D=$HOME/.claude/evenly-ci; GH=$HOME/bin/gh
if [ -e "$D/release.blocked" ]; then echo "РЕЛИЗ ЗАБЛОКИРОВАН: $(cat "$D/release.blocked") — сначала чини задачу evenly-ci-*"; exit 1; fi
# HEAD main берём с GitHub: ci-push.sh пушит по URL, локальный origin/main при этом не обновляется и отстаёт
sha=$($GH api repos/evenlymac/evenly/commits/main --jq .sha 2>/dev/null); [ -n "$sha" ] || sha=$(git rev-parse HEAD)
r=$($GH run list -R evenlymac/evenly --workflow ci.yml --commit "$sha" -L 1 --json conclusion,status --jq '.[0]|"\(.status) \(.conclusion)"' 2>/dev/null)
case "$r" in
  "completed success") echo "ок: CI зелёный на ${sha:0:7}";;
  "") echo "ci.yml на ${sha:0:7} не запускался (изменения вне проверяемого? запусти workflow вручную: gh workflow run ci.yml)"; exit 1;;
  *) echo "CI на ${sha:0:7}: $r — релиз не выпускаем"; exit 1;;
esac
