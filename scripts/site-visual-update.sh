#!/bin/bash
# Обновить эталонные снимки сайта (site/visual-baseline/) снимками раннера: эталоны всегда снимает тот же Safari на macOS-раннере.
# usage: scripts/site-visual-update.sh [SHA]   (по умолчанию HEAD; прогон ci для этого коммита должен был дойти до job site-visual)
# После этого просмотри снимки (site/visual-baseline/*.png), закоммить и запушь через scripts/ci-push.sh.
set -eu
cd "$(dirname "$0")/.."
sha=${1:-$(git rev-parse HEAD)}
run=$(~/bin/gh run list --repo evenlymac/evenly --workflow ci --commit "$sha" --json databaseId --jq '.[0].databaseId')
[ -n "$run" ] || { echo "нет прогона ci для $sha" >&2; exit 1; }
tmp=$(mktemp -d); ~/bin/gh run download "$run" --repo evenlymac/evenly -n site-visual -D "$tmp"
mkdir -p site/visual-baseline; rm -f site/visual-baseline/*.png
cp "$tmp"/[a-z][a-z]-*.png site/visual-baseline/; rm -rf "$tmp"
echo "эталоны обновлены из прогона $run: $(ls site/visual-baseline | wc -l | tr -d ' ') снимков"
