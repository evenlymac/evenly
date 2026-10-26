#!/usr/bin/env bash
# Evenly для Linux (PulseAudio или PipeWire с pipewire-pulse).
# Создаёт виртуальный выход "Evenly": выберите его выходом в системе; звук с него идёт через evenly-pcm на настоящий выход.
#   evenly-linux.sh start [sink]   запуск (sink: настоящий выход, по умолчанию текущий)
#   evenly-linux.sh stop           остановка и удаление виртуального выхода
#   evenly-linux.sh off | on       выключить/включить обработку на лету (звук не прерывается); status показывает состояние
set -u
BIN="${EVENLY_PCM:-$(dirname "$0")/evenly-pcm}"
RATE=48000; CH=2
PIDF="${XDG_RUNTIME_DIR:-/tmp}/evenly-linux.pid"
OFFF="${XDG_RUNTIME_DIR:-/tmp}/evenly-linux.off"   # есть файл: обработка выключена
# Сообщения на двух языках (как в приложениях для macOS и Windows): язык по LC_ALL / LC_MESSAGES / LANG, иначе английский.
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in ru*) RU=1 ;; *) RU=0 ;; esac
# >>> i18n: GENERATED from i18n/strings.json by scripts/i18n-gen.py: do not edit by hand
M() {   # M имя [подстановка {0}]: сообщение на языке системы
  local s
  case "$1" in
    no_default_sink) if [ "$RU" = 1 ]; then s="нет выхода по умолчанию"; else s="no default output device"; fi ;;
    already_running) if [ "$RU" = 1 ]; then s="уже запущен"; else s="already running"; fi ;;
    started) if [ "$RU" = 1 ]; then s="Evenly запущен: выберите выход «Evenly» → {0}"; else s="Evenly started: choose the output \"Evenly\" → {0}"; fi ;;
    stopped) if [ "$RU" = 1 ]; then s="Evenly остановлен"; else s="Evenly stopped"; fi ;;
    off_done) if [ "$RU" = 1 ]; then s="Evenly: обработка выключена (звук идёт без изменений)"; else s="Evenly: processing is off (audio passes unchanged)"; fi ;;
    on_done) if [ "$RU" = 1 ]; then s="Evenly: обработка включена"; else s="Evenly: processing is on"; fi ;;
    status_off) if [ "$RU" = 1 ]; then s="выключена"; else s="off"; fi ;;
    status_on) if [ "$RU" = 1 ]; then s="включена"; else s="on"; fi ;;
  esac
  printf '%s\n' "${s//\{0\}/${2:-}}"
}
# <<< i18n
case "${1:-}" in
  start)
    real="${2:-$(pactl get-default-sink)}"
    [ -n "$real" ] || { M no_default_sink >&2; exit 1; }
    [ -f "$PIDF" ] && kill -0 "$(cut -d' ' -f1 "$PIDF")" 2>/dev/null && { M already_running >&2; exit 0; }
    pactl list short sinks | grep -q $'\tevenly\t' || pactl load-module module-null-sink sink_name=evenly sink_properties=device.description=Evenly rate=$RATE channels=$CH format=float32le >/dev/null
    ( parec -d evenly.monitor --format=float32le --rate=$RATE --channels=$CH --latency-msec=20 \
        | "$BIN" --rate $RATE --channels $CH --off-file "$OFFF" \
        | pacat -d "$real" --format=float32le --rate=$RATE --channels=$CH --latency-msec=40 ) &
    echo "$! $real" > "$PIDF"
    M started "$real"
    ;;
  stop)
    [ -f "$PIDF" ] && kill "$(cut -d' ' -f1 "$PIDF")" 2>/dev/null; rm -f "$PIDF"
    pkill -f "parec -d evenly.monitor" 2>/dev/null
    for m in $(pactl list short modules | awk '/module-null-sink/ && /sink_name=evenly/ {print $1}'); do pactl unload-module "$m"; done
    M stopped
    ;;
  off) touch "$OFFF"; M off_done ;;
  on) rm -f "$OFFF"; M on_done ;;
  status) if [ -f "$OFFF" ]; then M status_off; else M status_on; fi ;;
  *) echo "usage: $0 start [sink] | stop | on | off | status" >&2; exit 2 ;;
esac
