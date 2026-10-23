#!/usr/bin/env python3
"""Громкость по ITU-R BS.1770-4 и диапазон громкости (LRA) по EBU R128 / Tech 3342.

Использование: loudness.py [--skip сек] [--trim сек_звука] [--csv файл] a.wav [b.wav ...]
Читает WAV float32/int16 (в том числе записи `Evenly --probe`). Без внешних библиотек.
Мгновенная громкость (400 мс) и кратковременная (3 с) считаются с шагом 100 мс.
"""
import array, math, struct, sys

def read_wav(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'RIFF' and d[8:12] == b'WAVE'
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(d):
        cid, sz = d[pos:pos + 4], struct.unpack('<I', d[pos + 4:pos + 8])[0]
        body = d[pos + 8:pos + 8 + sz]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', body[:16])
        elif cid == b'data':
            data = body
        pos += 8 + sz + (sz & 1)
    tag, ch, fs, _, _, bits = fmt
    if tag == 3 and bits == 32:
        a = array.array('f'); a.frombytes(data[:len(data) // 4 * 4])
    elif tag == 1 and bits == 16:
        b = array.array('h'); b.frombytes(data[:len(data) // 2 * 2])
        a = array.array('f', (x / 32768 for x in b))
    else:
        raise SystemExit(f'{path}: формат {tag}/{bits} не поддержан')
    return [a[c::ch] for c in range(ch)], fs

def kweight_coeffs(fs):
    # Коэффициенты из BS.1770-4 для любой частоты: ступень (shelf) и высокочастотный фильтр.
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    K = math.tan(math.pi * f0 / fs); Vh = 10 ** (G / 20); Vb = Vh ** 0.4996667741545416
    a0 = 1 + K / Q + K * K
    s = ([(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0],
         [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
    f0, Q = 38.13547087602444, 0.5003270373238773
    K = math.tan(math.pi * f0 / fs); a0 = 1 + K / Q + K * K
    h = ([1, -2, 1], [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
    return s, h

def biquad(x, b, a):
    b0, b1, b2 = b; a1, a2 = a[1], a[2]
    z1 = z2 = 0.0; y = array.array('d', bytes(8 * len(x)))
    for i, v in enumerate(x):
        o = b0 * v + z1
        z1 = b1 * v - a1 * o + z2
        z2 = b2 * v - a2 * o
        y[i] = o
    return y

def block_energies(chans, fs, win, hop):
    """Энергия (сумма квадратов каналов, среднее по окну) для окон длиной win с шагом hop секунд."""
    s, h = kweight_coeffs(fs)
    sq = None
    for x in chans[:2]:
        y = biquad(biquad(x, *s), *h)
        q = [v * v for v in y]
        sq = q if sq is None else [p + r for p, r in zip(sq, q)]
    # префиксные суммы для быстрого среднего
    pre = [0.0]
    for v in sq:
        pre.append(pre[-1] + v)
    n, W, H = len(sq), int(win * fs), int(hop * fs)
    return [(pre[i + W] - pre[i]) / W for i in range(0, n - W + 1, H)]

def lufs(e):
    return -0.691 + 10 * math.log10(e) if e > 0 else -math.inf

def integrated(e400):
    g = [e for e in e400 if lufs(e) > -70]
    if not g: return -math.inf
    rel = lufs(sum(g) / len(g)) - 10
    g = [e for e in g if lufs(e) > rel]
    return lufs(sum(g) / len(g)) if g else -math.inf

def lra(e3s):
    v = [lufs(e) for e in e3s if lufs(e) > -70]
    if not v: return 0.0, -math.inf, -math.inf
    ref = lufs(sum(10 ** ((x + 0.691) / 10) for x in v) / len(v)) - 20
    v = sorted(x for x in v if x > ref)
    if len(v) < 2: return 0.0, -math.inf, -math.inf
    lo, hi = v[int(0.10 * (len(v) - 1))], v[int(0.95 * (len(v) - 1))]
    return hi - lo, lo, hi

def analyze(path, skip=0.0, csv=None, trim=False, dur=None):
    chans, fs = read_wav(path)
    if trim:  # убрать тишину в начале записи и обрезать до dur секунд звука
        i = next((k for k in range(len(chans[0])) if max(abs(c[k]) for c in chans) > 0.003), 0)
        chans = [c[i:i + int(dur * fs) if dur else None] for c in chans]
    if skip:
        chans = [c[int(skip * fs):] for c in chans]
    peak = max(max(abs(v) for v in c) for c in chans)
    clipped = sum(1 for c in chans for v in c if abs(v) >= 0.999)
    m = block_energies(chans, fs, 0.4, 0.1)
    s = block_energies(chans, fs, 3.0, 0.1)
    r, lo, hi = lra(s)
    ml = [lufs(e) for e in m if lufs(e) > -70]
    if csv:
        with open(csv, 'w') as f:
            f.write('t,momentary,shortterm\n')
            for i, e in enumerate(m):
                f.write(f'{0.2 + i * 0.1:.1f},{lufs(e):.2f},{lufs(s[i - 28]) if 28 <= i < 28 + len(s) else ""}\n')
    return dict(dur=len(chans[0]) / fs, I=integrated(m), LRA=r, lo=lo, hi=hi,
                mrange=(max(ml) - min(ml)) if ml else 0.0, peak=peak, clipped=clipped)

if __name__ == '__main__':
    args, skip, csv, trim = sys.argv[1:], 0.0, None, None
    while args and args[0].startswith('--'):
        if args[0] == '--skip': skip = float(args[1])
        elif args[0] == '--csv': csv = args[1]
        elif args[0] == '--trim': trim = float(args[1])
        args = args[2:]
    print(f'{"файл":<22}{"сек":>5}{"I LUFS":>8}{"LRA LU":>8}{"p10":>7}{"p95":>7}{"мгн.размах":>11}{"пик":>6}{"срез":>6}')
    for p in args:
        r = analyze(p, skip, csv, trim is not None, trim)
        print(f'{p.split("/")[-1]:<22}{r["dur"]:>5.0f}{r["I"]:>8.1f}{r["LRA"]:>8.1f}{r["lo"]:>7.1f}{r["hi"]:>7.1f}'
              f'{r["mrange"]:>11.1f}{r["peak"]:>6.2f}{r["clipped"]:>6d}')
