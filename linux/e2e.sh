#!/usr/bin/env bash
# Сквозная проверка без железа: PulseAudio с виртуальными выходами. Тихий тон -> sink evenly -> evenly-pcm -> sink real; пишем real.monitor.
# usage: e2e.sh path/to/evenly-pcm
set -u
export EVENLY_PCM="$1"
D="$(cd "$(dirname "$0")" && pwd)"
pulseaudio --start --exit-idle-time=-1 --log-target=stderr 2>/dev/null || pulseaudio -D --exit-idle-time=-1
sleep 2
pactl load-module module-null-sink sink_name=real rate=48000 channels=2 format=float32le >/dev/null
pactl set-default-sink real
"$D/evenly-linux.sh" start real || exit 1
sleep 2
pactl list short sinks
python3 - <<'PY'
import struct, math
n = 48000 * 24
with open("/tmp/in.f32", "wb") as f:
    f.write(b"".join(struct.pack("<ff", s, s) for s in (0.01 * math.sin(2 * math.pi * 440 * i / 48000) for i in range(n))))
PY
parec -d real.monitor --format=float32le --rate=48000 --channels=2 --raw > /tmp/out.f32 &
REC=$!
sleep 1
paplay -d evenly --raw --format=float32le --rate=48000 --channels=2 /tmp/in.f32
sleep 2
kill $REC 2>/dev/null
"$D/evenly-linux.sh" stop
pactl list short sinks
python3 - <<'PY'
import struct
d = open("/tmp/out.f32", "rb").read()
v = struct.unpack("<%df" % (len(d) // 4), d[: len(d) // 4 * 4])
tail = v[-48000 * 2 * 3 : -48000 * 2 * 1]
peak = max(abs(x) for x in tail) if tail else 0
print("recorded samples:", len(v), "tail peak:", peak, "(input peak 0.01)")
ok = peak > 0.03
print("E2E", "PASS" if ok else "FAIL")
raise SystemExit(0 if ok else 1)
PY
