#!/bin/zsh
# Синхронизирует на Air и собирает подписанный build/Evenly.app (без запуска).
set -e
cd "$(dirname "$0")/.."
rsync -a --exclude .build --exclude build ./ goldengate@MacBookAir.local:projects/evenly-sync/
ssh goldengate@MacBookAir.local 'zsh -lic "security unlock-keychain -p ev ~/Library/Keychains/evenly-dev.keychain-db; cd ~/projects/evenly-sync && scripts/build-app.sh 2>&1 | tail -15"'
