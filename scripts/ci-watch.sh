#!/bin/bash
# ci-watch.sh SHA — ждёт прогон ci.yml для коммита и разбирает результат без участия человека:
#  зелёный: снимает блокировку релиза; красный: сбой инфраструктуры перезапускает один раз, иначе создаёт автозадачу
#  evenly-ci-<sha7> (чинить самому), ставит блокировку релиза и вводит задачу в сессию claude (когда она свободна).
# Состояние: ~/.claude/evenly-ci/ (status.json, release.blocked, watch.log). Запускается из scripts/ci-push.sh.
sha=${1:?usage: ci-watch.sh SHA}; s7=${sha:0:7}
GH=$HOME/bin/gh; R=evenlymac/evenly; D=$HOME/.claude/evenly-ci; T=$HOME/.claude/pending-tasks; TM=$HOME/.local/bin/tmux
mkdir -p "$D"
log() { echo "$(date '+%F %T') $s7 $*" >> "$D/watch.log"; }
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
echo "{\"sha\":\"$sha\",\"result\":\"red\",\"url\":\"$url\"}" > "$D/status.json"
echo "$sha $url" > "$D/release.blocked"
name="evenly-ci-$s7"; f="$T/$name.md"
if [ ! -e "$f" ]; then
  jobs=$($GH run view "$id" -R $R --json jobs --jq '.jobs[]|select(.conclusion=="failure")|.name' 2>/dev/null | tr '\n' ' ')
  { cat <<HDR
---
status: open
load: io
data: public
cpu_min: 15
block: нет
when: сейчас, в фоне
auto: on
priority: high
created: $(date +%F)
where: server
---
Задача: регрессия Evenly упала на коммите $s7. Разберись и почини сам; релиз заблокирован (~/.claude/evenly-ci/release.blocked), пока CI не позеленеет.
Прогон: $url
Упавшие job: $jobs
Проект: ~/projects/evenly (ветка main). Журнал упавших шагов:

\`\`\`
$(echo "$failed" | tail -60)
\`\`\`

## Как действовать (решение пользователя 2026-10-27)
1. Сначала сам: прочитай полный лог (\`~/bin/gh run view $id -R $R --log-failed\`), воспроизведи локально, где можно (\`swift test\`, \`cargo test\`, на Air через scripts/air-sync.sh), реши, что сломалось: код, тест или стенд (раннер без звука, сеть, apt).
2. Нужна правка и новая версия: внеси её сам (версия патч: scripts/build-app.sh, windows/tray/Cargo.toml, linux/pcm/Cargo.toml), закоммить и запушь только через \`scripts/ci-push.sh\` (он включит слежение за новым прогоном). Не больше 3 попыток; считай их строками «Попытка N:» в этом файле.
3. Позеленело (блокировка снимется сама): допиши «Итог», раздел «Ретроспектива» с уроком (превращай в проверку, а не в память) и строку «Внесено:», status: review.
4. Пользователю показывай только то, что требует решения: меняется поведение продукта, текст или перевод требует выбора, нужны секреты, подпись, оплата, доступ, сбой стенда не лечится перезапуском, 3 попытки не помогли. Тогда строка «От вас: …» одной командой, status: waiting. Релиз сам не публикуй, если не просили; если баг уже в опубликованном релизе, напиши это в «От вас:».
HDR
  } > "$f"
  log "создана автозадача $name"
fi
# ввести задачу в сессию claude, когда она свободна (чтобы не слипнуться с набором пользователя)
[ -x "$TM" ] || exit 0
msg="Автозадача: возьми задачу ~/.claude/pending-tasks/$name.md. Если расход лимитов 90% и выше (~/.claude/usage.json), поставь новый разовый запуск через час и остановись. Иначе прочитай задачу, выполни и обнови файл. Закончил: status: review и коротко отчитайся здесь, последней строкой «Улучшено в системе: …». Канал связи не трогай. При блокере: строка «От вас:» в файле, status: waiting."
for _ in $(seq 1 40); do
  $TM has-session -t claude 2>/dev/null || { log "нет tmux-сессии claude: задача ждёт в pending-tasks"; exit 0; }
  act=$($TM display-message -p -t claude '#{window_activity}' 2>/dev/null); now=$(date +%s)
  if [ -n "$act" ] && [ $((now - act)) -gt 60 ]; then
    $TM send-keys -t claude -l "$msg"; sleep 1; $TM send-keys -t claude Enter; log "задача введена в сессию claude"; exit 0
  fi
  sleep 60
done
log "сессия занята 40 минут: задача ждёт в pending-tasks (приветствие покажет)"
