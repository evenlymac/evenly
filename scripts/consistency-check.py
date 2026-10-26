#!/usr/bin/env python3
"""Согласованность Evenly между платформами: версии, переводы en/ru, общие термины, установщик, Linux.
Запуск: python3 -I scripts/consistency-check.py  (код выхода 0 = согласовано; job `consistency` в ci.yml)."""
import re, sys, pathlib

R = pathlib.Path(__file__).resolve().parent.parent
errs = []
def bad(m): errs.append(m)
def read(p): return (R / p).read_text(encoding="utf-8")
CYR = re.compile(r"[А-Яа-яЁё]")
STR = r'"((?:[^"\\]|\\.)*)"'
def unesc(s): return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")

# 1. версии платформ совпадают (релизы синхронные)
ver = {}
ver["macOS (scripts/build-app.sh)"] = re.search(r"CFBundleShortVersionString</key><string>([\d.]+)", read("scripts/build-app.sh")).group(1)
ver["Windows (windows/tray/Cargo.toml)"] = re.search(r'^version\s*=\s*"([\d.]+)"', read("windows/tray/Cargo.toml"), re.M).group(1)
ver["Linux (linux/pcm/Cargo.toml)"] = re.search(r'^version\s*=\s*"([\d.]+)"', read("linux/pcm/Cargo.toml"), re.M).group(1)
if len(set(ver.values())) != 1:
    bad("версии платформ разные: " + ", ".join(f"{k} = {v}" for k, v in ver.items()))

# 2. macOS: ключи InfoPlist.strings одинаковы в en и ru (Localizable проверяет swift-тест EvenlyL10nTests)
def strings(path):
    return dict((unesc(a), unesc(b)) for a, b in re.findall(STR + r"\s*=\s*" + STR + ";", read(path)))
for f in ("InfoPlist", "Localizable"):
    en, ru = strings(f"Resources/en.lproj/{f}.strings"), strings(f"Resources/ru.lproj/{f}.strings")
    if set(en) != set(ru): bad(f"macOS {f}.strings: ключи en и ru разные: {sorted(set(en) ^ set(ru))}")
    for k, v in ru.items():
        if k != "CFBundleName" and not CYR.search(v): bad(f"macOS {f}.strings ru не переведено: {k[:50]}")
mac_en, mac_ru = strings("Resources/en.lproj/Localizable.strings"), strings("Resources/ru.lproj/Localizable.strings")

# 3. Windows-трей: поля Text есть в обоих языках, ru на русском, en без кириллицы
src = read("windows/tray/src/main.rs")
def block(lang):
    m = re.search(r"Lang::%s => Text \{(.*?)\n        \}," % lang, src, re.S)
    return dict((k, unesc(v)) for k, v in re.findall(r"(\w+):\s*" + STR + ",", m.group(1))) if m else {}
w_en, w_ru = block("En"), block("Ru")
if not w_en or not w_ru: bad("Windows: не разобрать блоки Text (Lang::En / Lang::Ru) в windows/tray/src/main.rs")
if set(w_en) != set(w_ru): bad(f"Windows: поля Text разные: {sorted(set(w_en) ^ set(w_ru))}")
for k, v in w_en.items():
    if CYR.search(v): bad(f"Windows en содержит кириллицу: {k}")
    if not v.strip(): bad(f"Windows en пусто: {k}")
for k, v in w_ru.items():
    if not v.strip(): bad(f"Windows ru пусто: {k}")
    elif not CYR.search(v) and re.sub(r"Evenly|\W", "", w_en.get(k, "")) != "": bad(f"Windows ru не переведено: {k}")

# 4. общие термины macOS и Windows (site/glossary.tsv)
for line in read("site/glossary.tsv").splitlines():
    if not line.strip() or line.startswith("#"): continue
    key, field = line.split("\t")[:2]
    if key not in mac_en: bad(f"глоссарий: нет ключа macOS «{key}»"); continue
    if field not in w_en: bad(f"глоссарий: нет поля Windows «{field}»"); continue
    if mac_en[key] != w_en[field]: bad(f"термин «{key}» (en): macOS «{mac_en[key]}» ≠ Windows «{w_en[field]}»")
    if mac_ru.get(key) != w_ru.get(field): bad(f"термин «{key}» (ru): macOS «{mac_ru.get(key)}» ≠ Windows «{w_ru.get(field)}»")

# 5. установщик Windows: у каждого сообщения есть english и russian
iss = read("windows/installer/evenly.iss")
en_m = dict(re.findall(r"^english\.(\w+)=(.*)$", iss, re.M)); ru_m = dict(re.findall(r"^russian\.(\w+)=(.*)$", iss, re.M))
if set(en_m) != set(ru_m): bad(f"установщик: сообщения english и russian разные: {sorted(set(en_m) ^ set(ru_m))}")
for k, v in ru_m.items():
    if not CYR.search(v): bad(f"установщик russian.{k} не переведено")
for k, v in en_m.items():
    if CYR.search(v): bad(f"установщик english.{k} содержит кириллицу")

# 6. Linux: сообщения идут через T "по-русски" "in English", голых русских echo нет
lin = read("linux/evenly-linux.sh")
for ru, en in re.findall(r'\bT\s+' + STR + r'\s+' + STR, lin):
    if not CYR.search(ru): bad(f"Linux: первая строка T без русского: {ru[:50]}")
    if CYR.search(en): bad(f"Linux: вторая строка T с кириллицей: {en[:50]}")
for ln in lin.splitlines():
    if re.search(r"\b(echo|printf)\b", ln) and CYR.search(ln) and not ln.lstrip().startswith("#") and "T()" not in ln and "printf '%s" not in ln:
        bad("Linux: русское сообщение мимо T: " + ln.strip()[:70])

if errs:
    print("НЕСОГЛАСОВАННОСТЬ ПЛАТФОРМ:"); [print("  -", e) for e in errs]; sys.exit(1)
print("ок: платформы согласованы (версия", next(iter(ver.values())) + ", переводы, термины, установщик, Linux)")
