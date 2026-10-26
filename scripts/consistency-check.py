#!/usr/bin/env python3
"""Согласованность Evenly между платформами (job `consistency` в ci.yml). Код выхода 0 = согласовано.
Переводы: единый источник i18n/strings.json, остальное генерируется (scripts/i18n-gen.py --check ловит ручные правки и забытую генерацию).
Здесь же: версии платформ совпадают, в Linux-скрипте нет русских сообщений мимо i18n-блока, в коде трея и установщика нет строк мимо источника."""
import re, subprocess, sys, pathlib

R = pathlib.Path(__file__).resolve().parent.parent
errs = []
def read(p): return (R / p).read_text(encoding="utf-8")
CYR = re.compile(r"[А-Яа-яЁё]")

# 1. переводы: источник корректен, сгенерированные файлы не расходятся
r = subprocess.run([sys.executable, "-I", str(R / "scripts/i18n-gen.py"), "--check"], capture_output=True, text=True)
if r.returncode != 0: errs.append(r.stdout.strip() or r.stderr.strip())

# 2. версии платформ совпадают (релизы синхронные)
ver = {
    "macOS (scripts/build-app.sh)": re.search(r"CFBundleShortVersionString</key><string>([\d.]+)", read("scripts/build-app.sh")).group(1),
    "Windows (windows/tray/Cargo.toml)": re.search(r'^version\s*=\s*"([\d.]+)"', read("windows/tray/Cargo.toml"), re.M).group(1),
    "Linux (linux/pcm/Cargo.toml)": re.search(r'^version\s*=\s*"([\d.]+)"', read("linux/pcm/Cargo.toml"), re.M).group(1),
}
if len(set(ver.values())) != 1: errs.append("версии платформ разные: " + ", ".join(f"{k} = {v}" for k, v in ver.items()))

# 3. пользовательские строки не обходят источник
lin = re.sub(r"# >>> i18n.*?# <<< i18n\n", "", read("linux/evenly-linux.sh"), flags=re.S)
for ln in lin.splitlines():
    if re.search(r"\b(echo|printf)\b", ln) and CYR.search(ln) and not ln.lstrip().startswith("#"):
        errs.append("Linux: русское сообщение мимо i18n/strings.json: " + ln.strip()[:70])
tray = re.sub(r'include!\("strings\.rs"\);', "", read("windows/tray/src/main.rs"))
for ln in tray.splitlines():
    if CYR.search(ln) and not ln.lstrip().startswith("//") and "check(" not in ln and "println!" not in ln:   # названия самопроверок не интерфейс
        errs.append("Windows-трей: русский текст в коде мимо i18n/strings.json: " + ln.strip()[:70])
iss = read("windows/installer/evenly.iss")
for ln in iss.splitlines():
    if CYR.search(ln) and not ln.lstrip().startswith(";"):
        errs.append("установщик: русский текст мимо i18n/strings.json: " + ln.strip()[:70])

if errs:
    print("НЕСОГЛАСОВАННОСТЬ ПЛАТФОРМ:"); [print("  -", e) for e in errs]; sys.exit(1)
print("ок: платформы согласованы (версия", next(iter(ver.values())) + ", переводы из i18n/strings.json, Linux, трей, установщик)")
