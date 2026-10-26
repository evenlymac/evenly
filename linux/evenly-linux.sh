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
T() { if [ "$RU" = 1 ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }   # T "по-русски" "in English"
case "${1:-}" in
  start)
    real="${2:-$(pactl get-default-sink)}"
    [ -n "$real" ] || { T "нет выхода по умолчанию" "no default output device" >&2; exit 1; }
    [ -f "$PIDF" ] && kill -0 "$(cut -d' ' -f1 "$PIDF")" 2>/dev/null && { T "уже запущен" "already running" >&2; exit 0; }
    pactl list short sinks | grep -q $'\tevenly\t' || pactl load-module module-null-sink sink_name=evenly sink_properties=device.description=Evenly rate=$RATE channels=$CH format=float32le >/dev/null
    ( parec -d evenly.monitor --format=float32le --rate=$RATE --channels=$CH --latency-msec=20 \
        | "$BIN" --rate $RATE --channels $CH --off-file "$OFFF" \
        | pacat -d "$real" --format=float32le --rate=$RATE --channels=$CH --latency-msec=40 ) &
    echo "$! $real" > "$PIDF"
    T "Evenly запущен: выберите выход «Evenly» → $real" "Evenly started: choose the output \"Evenly\" → $real"
    ;;
  stop)
    [ -f "$PIDF" ] && kill "$(cut -d' ' -f1 "$PIDF")" 2>/dev/null; rm -f "$PIDF"
    pkill -f "parec -d evenly.monitor" 2>/dev/null
    for m in $(pactl list short modules | awk '/module-null-sink/ && /sink_name=evenly/ {print $1}'); do pactl unload-module "$m"; done
    T "Evenly остановлен" "Evenly stopped"
    ;;
  off) touch "$OFFF"; T "Evenly: обработка выключена (звук идёт без изменений)" "Evenly: processing is off (audio passes unchanged)" ;;
  on) rm -f "$OFFF"; T "Evenly: обработка включена" "Evenly: processing is on" ;;
  status) if [ -f "$OFFF" ]; then T "выключена" "off"; else T "включена" "on"; fi ;;
  *) echo "usage: $0 start [sink] | stop | on | off | status" >&2; exit 2 ;;
esac
