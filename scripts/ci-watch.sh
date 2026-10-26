#!/bin/bash
# ci-watch.sh SHA — ждёт прогон ci.yml для коммита и разбирает результат без участия человека:
#  зелёный: снимает блокировку релиза; красный: сбой инфраструктуры перезапускает один раз, иначе пишет разбор
#  ~/.claude/evenly-ci/failure-<sha7>.md (задача в pending-tasks не заводится), ставит блокировку релиза и вводит поручение в сессию claude (когда она свободна).
# Состояние: ~/.claude/evenly-ci/ (status.json, release.blocked, watch.log). Запускается из scripts/ci-push.sh.
sha=${1:?usage: ci-watch.sh SHA}; s7=${sha:0:7}
GH=$HOME/bin/gh; R=evenlymac/evenly; D=$HOME/.claude/evenly-ci; TM=$HOME/.local/bin/tmux
mkdir -p "$D"
log() { echo "$(date '+%F %T') $s7 $*" >> "$D/watch.log"; }
tg() { [ -x "$HOME/.claude/gcore/core/tg-send.sh" ] && "$HOME/.claude/gcore/core/tg-send.sh" "$1" >/dev/null 2>&1; }
id=""; for _ in $(seq 1 30); do id=$($GH run list -R $R --workflow ci.yml --commit "$sha" -L 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null); [ -n "$id" ] && break; sleep 10; done
[ -n "$id" ] || { log "прогон ci.yml не появился за 5 минут"; exit 0; }
url="https://github.com/$R/actions/runs/$id"; log "слежу за $url"
reran=0
while :; do
  $GH run watch "$id" -R $R --interval 20 >/dev/null 2>&1
  concl=$($GH run view "$id" -R $R --json conclusion --jq .conclusion 2>/dev/null)
  [ "$concl" = success ] && break
  failed=$($GH run view "$id" -R $R --log-failed 2>/dev/null | tail -150)
  if [ $reran -eq 0 ] && ! echo "$failed" | grep -Eq 'FAIL:|test result: FAILED|error(\[|:)|assert|panicked'; then
    if echo "$failed" | grep -Eiq 'Unable to connect|Temporary failure|timed out|timeout|ECONNRESET|503|Could not resolve|lost communication|apt-get|The operation was canceled'; then
      log "похоже на сбой инфраструктуры, перезапускаю упавшие job один раз"; reran=1
      $GH run rerun "$id" -R $R --failed >/dev/null 2>&1 && continue
    fi
  fi
  break
done
if [ "$concl" = success ]; then
  head=$($GH api repos/$R/commits/main --jq .sha 2>/dev/null)
  echo "{\"sha\":\"$sha\",\"result\":\"green\",\"url\":\"$url\"}" > "$D/status.json"
  if [ "$head" = "$sha" ] && [ -e "$D/release.blocked" ]; then rm -f "$D/release.blocked"; log "зелёный на HEAD main: блокировка релиза снята"; else log "зелёный"; fi
  exit 0
fi
log "КРАСНЫЙ ($concl): $url"
# красный устарел: на HEAD main уже есть зелёный прогон (починили следующим коммитом): ни блокировки, ни разбора
head=$($GH api repos/$R/commits/main --jq .sha 2>/dev/null)
if [ -n "$head" ] && [ "$head" != "$sha" ]; then
  hc=$($GH run list -R $R --workflow ci.yml --commit "$head" -L 1 --json conclusion --jq '.[0].conclusion // empty' 2>/dev/null)
  [ "$hc" = success ] && { log "красный устарел: HEAD main ${head:0:7} уже зелёный, задачу не создаю"; exit 0; }
fi
echo "{\"sha\":\"$sha\",\"result\":\"red\",\"url\":\"$url\"}" > "$D/status.json"
echo "$sha $url" > "$D/release.blocked"
# Красный CI: отдельную задачу в pending-tasks не заводим (решение пользователя 2026-10-27). Разбор лежит в $D/failure-<sha7>.md,
# сессия claude чинит сама, пользователю пишем только если не получилось и блокировка остаётся.
name="failure-$s7"; f="$D/$name.md"
if [ ! -e "$f" ]; then
  jobs=$($GH run view "$id" -R $R --json jobs --jq '.jobs[]|select(.conclusion=="failure")|.name' 2>/dev/null | tr '\n' ' ')
  { cat <<HDR
Регрессия Evenly упала на коммите $s7. Чини сам, без пользователя; релиз заблокирован (~/.claude/evenly-ci/release.blocked), пока CI не позеленеет.
Прогон: $url
Упавшие job: $jobs
Проект: ~/projects/evenly (ветка main). Журнал упавших шагов:

\`\`\`
$(echo "$failed" | tail -60)
\`\`\`

## Как действовать (решение пользователя 2026-10-27)
1. Сначала сам: прочитай полный лог (\`~/bin/gh run view $id -R $R --log-failed\`), воспроизведи локально, где можно (\`swift test\`, \`cargo test\`, на Air через scripts/air-sync.sh), реши, что сломалось: код, тест или стенд (раннер без звука, сеть, apt).
2. Нужна правка и новая версия: внеси её сам (версия патч: scripts/build-app.sh, windows/tray/Cargo.toml, linux/pcm/Cargo.toml), закоммить и запушь только через \`scripts/ci-push.sh\` (он включит слежение за новым прогоном). Не больше 3 попыток; записывай их строками «Попытка N:» в конец этого файла.
3. Позеленело (блокировка снимется сама): пользователю ничего не пиши, задачу не заводи. Урок, если он есть, превращай в проверку (\`~/.claude/gcore/core/lesson.sh\`).
4. Пользователю пиши только если не вышло: нужны секреты, подпись, оплата, доступ, решение о поведении продукта или текст, сбой стенда не лечится перезапуском, 3 попытки не помогли. Тогда: задача ~/.claude/pending-tasks/evenly-ci-blocker-$s7.md (status: waiting, строка «От вас: …» одной командой) и одно сообщение в Telegram (\`~/.claude/gcore/core/tg-send.sh\`) с краткой причиной. Релиз сам не публикуй, если не просили; если баг уже в опубликованном релизе, напиши это в «От вас:».
HDR
  } > "$f"
  log "создан разбор $name.md (задача в pending-tasks не заводится)"
fi
# ввести задачу в сессию claude, когда она свободна (чтобы не слипнуться с набором пользователя)
[ -x "$TM" ] || exit 0
msg="Автозадача: красный CI Evenly на $s7. Прочитай ~/.claude/evenly-ci/$name.md и почини сам по инструкции в нём. Если расход лимитов 90% и выше (~/.claude/usage.json), поставь новый разовый запуск через час и остановись. Канал связи не трогай. Пользователю пиши только если не вышло (описано в файле); если починил, одна строка здесь, без Telegram."
for _ in $(seq 1 40); do
  [ -e "$D/release.blocked" ] || { log "блокировка уже снята (HEAD зелёный): задачу в сессию не ввожу"; exit 0; }
  $TM has-session -t claude 2>/dev/null || { log "нет tmux-сессии claude: разбор ждёт в $D"; tg "Красный CI Evenly на $s7, релиз заблокирован. Сессия claude не запущена, разбор: ~/.claude/evenly-ci/$name.md. $url"; exit 0; }
  act=$($TM display-message -p -t claude '#{window_activity}' 2>/dev/null); now=$(date +%s)
  if [ -n "$act" ] && [ $((now - act)) -gt 60 ]; then
    $TM send-keys -t claude -l "$msg"; sleep 1; $TM send-keys -t claude Enter; log "поручение введено в сессию claude"; exit 0
  fi
  sleep 60
done
log "сессия занята 40 минут: разбор ждёт в $D"
tg "Красный CI Evenly на $s7, релиз заблокирован. Сессия claude занята больше 40 минут и не взяла разбор: ~/.claude/evenly-ci/$name.md. $url"
