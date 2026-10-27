#!/bin/bash
# Пуш в main и запуск слежения за регрессией (CI на раннерах GitHub). usage: scripts/ci-push.sh
# Дальше можно заниматься другим: красный результат превратится в блокировку релиза и разбор ~/.claude/evenly-ci/failure-<sha>.md, который сессия claude чинит сама (scripts/ci-watch.sh).
set -e
cd "$(dirname "$0")/.."
[ "$(git branch --show-current)" = main ] || { echo "ci-push: нужна ветка main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "ci-push: есть незакоммиченные правки, закоммить их" >&2; exit 1; }
git fetch -q https://github.com/evenlymac/evenly.git main 2>/dev/null || { echo "ci-push: не удалось получить origin main (сеть?), docs-sync не проверен" >&2; exit 1; }
scripts/docs-sync.sh FETCH_HEAD HEAD >&2 || { echo "ci-push: docs-sync красный, допиши «Site: …» в сообщение коммита (git commit --amend)" >&2; exit 1; }
git -c credential.helper= -c credential.helper='!/Users/macbookpro/bin/gh auth git-credential' push -q https://github.com/evenlymac/evenly.git main
sha=$(git rev-parse HEAD)
mkdir -p ~/.claude/evenly-ci
nohup "$PWD/scripts/ci-watch.sh" "$sha" >/dev/null 2>&1 &
echo "запушено ${sha:0:7}; слежение за CI запущено (журнал ~/.claude/evenly-ci/watch.log)"
