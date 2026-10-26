#!/usr/bin/env python3
"""Визуальные проверки сайта Evenly в Safari (safaridriver) на macOS-раннере.
  python3 scripts/site-visual.py OUT_DIR [--update-baseline]
Для каждой страницы (ru, en) x окна (phone 390, desktop 1280) x темы (light, dark) делает снимки кусками по высоте окна и автопроверки:
нет горизонтальной прокрутки, логотип и графики отрисованы, переключатель языка ведёт на другую страницу, выбор языка по navigator.language.
Снимки сравниваются с site/visual-baseline/ (эталоны снимает тот же раннер: scripts/site-visual-update.sh). Код выхода 1 при расхождении или провале проверки."""
import http.server, os, shutil, socketserver, subprocess, sys, threading, pathlib, json
from PIL import Image, ImageChops
from selenium import webdriver
from selenium.webdriver.safari.options import Options

R = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1]).resolve(); OUT.mkdir(parents=True, exist_ok=True)
BASE = R / "site/visual-baseline"
PAGES = {"ru": "/index.html", "en": "/en/index.html"}
SIZES = {"phone": (390, 844), "desktop": (1280, 900)}
PIXEL_THRESHOLD = 24      # разница канала, ниже которой пиксель считаем одинаковым (сглаживание шрифтов)
MAX_DIFF_SHARE = 0.004    # доля отличающихся пикселей, выше которой снимок красный
fails = []

def fail(m): print("ПРОВАЛ:", m, flush=True); fails.append(m)

def set_theme(dark):
    scr = f'tell application "System Events" to tell appearance preferences to set dark mode to {"true" if dark else "false"}'
    r = subprocess.run(["osascript", "-e", scr], capture_output=True, text=True)
    if r.returncode != 0: fail(f"не удалось переключить тему macOS ({r.stderr.strip()})")
    import time; time.sleep(2)

class Q(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=str(R / "site"), **k)
    def log_message(s, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), Q); PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

def shots(d, name, h):
    total = d.execute_script("return Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)")
    n = 0; y = 0
    while y < total and n < 12:
        d.execute_script(f"window.scrollTo(0,{y})")
        import time; time.sleep(0.4)
        d.save_screenshot(str(OUT / f"{name}-{n}.png")); n += 1; y += h
    return n

def checks(d, lang, size, theme):
    tag = f"{lang}/{size}/{theme}"
    ov = d.execute_script("return document.documentElement.scrollWidth - window.innerWidth")
    if ov > 1: fail(f"{tag}: горизонтальная прокрутка ({ov}px)")
    logo = d.execute_script("return getComputedStyle(document.querySelector('.logo-big')).backgroundImage")
    if "data:image" not in logo: fail(f"{tag}: логотип не отрисован")
    bad = d.execute_script("return [...document.querySelectorAll('svg')].filter(s=>{const r=s.getBoundingClientRect();return r.width<10||r.height<5}).length")
    if bad: fail(f"{tag}: графиков нулевого размера: {bad}")
    sw = d.execute_script("const a=[...document.querySelectorAll('.langs a')];return JSON.stringify({n:a.length,on:a.filter(x=>x.classList.contains('on')).map(x=>x.lang),other:a.filter(x=>!x.classList.contains('on')).map(x=>x.href)})")
    sw = json.loads(sw)
    if sw["n"] != 2 or sw["on"] != [lang] or len(sw["other"]) != 1 or sw["other"][0].rstrip("/").endswith(d.current_url.rstrip("/")) and "/en" not in sw["other"][0] + d.current_url:
        fail(f"{tag}: переключатель En/Ru: {sw}")
    if d.execute_script("return document.documentElement.lang") != lang: fail(f"{tag}: lang страницы не {lang}")
    # выбор языка по navigator.language: логику встроенного скрипта гоняем с подменой navigator, localStorage и location
    js = """const s=document.querySelector('head script').textContent;const out={};
      for (const [nl,stored] of [['ru-RU',null],['en-US',null],['en-US','x']]) {
        let to=null; try { new Function('navigator','localStorage','location',s)({language:nl},{getItem:()=>stored},{replace:u=>{to=u}}); } catch(e){ to='ERR'+e }
        out[nl+'|'+stored]=to }
      return JSON.stringify(out)"""
    got = json.loads(d.execute_script(js))
    want_ru = {"ru-RU|null": None, "en-US|null": "en/", "en-US|x": None}
    want_en = {"ru-RU|null": "../", "en-US|null": None, "en-US|x": None}
    if got != (want_ru if lang == "ru" else want_en): fail(f"{tag}: выбор языка по браузеру: {got}")

def compare(name):
    ok = True
    if not BASE.exists(): print("эталонов ещё нет (site/visual-baseline/): сравнение пропущено, снимки в артефакте; scripts/site-visual-update.sh"); return True
    for f in sorted(OUT.glob(f"{name}-*.png")):
        b = BASE / f.name
        if not b.exists(): fail(f"{f.name}: нет эталона (scripts/site-visual-update.sh)"); ok = False; continue
        a, c = Image.open(f).convert("RGB"), Image.open(b).convert("RGB")
        if a.size != c.size: fail(f"{f.name}: размер {a.size} вместо {c.size}"); ok = False; continue
        diff = ImageChops.difference(a, c).convert("L").point(lambda v: 255 if v > PIXEL_THRESHOLD else 0)
        share = sum(1 for v in diff.getdata() if v) / (a.size[0] * a.size[1])
        if share > MAX_DIFF_SHARE:
            fail(f"{f.name}: отличается {share:.2%} пикселей (порог {MAX_DIFF_SHARE:.2%})"); ok = False
            ImageChops.difference(a, c).save(OUT / f"DIFF-{f.name}")
    return ok

def main():
    update = "--update-baseline" in sys.argv
    for theme in ("light", "dark"):
        set_theme(theme == "dark")
        d = webdriver.Safari(options=Options())
        try:
            d.get(f"http://127.0.0.1:{PORT}/en/index.html")   # en-страница у англоязычного раннера не перенаправляет: запоминаем выбор, чтобы ru-страница не ушла на /en/
            d.execute_script("localStorage.setItem('evenly-lang','test')")
            for size, (w, h) in SIZES.items():
                for lang, path in PAGES.items():
                    d.set_window_size(w, h + 120)
                    d.get(f"http://127.0.0.1:{PORT}{path}")
                    inner = d.execute_script("return [window.innerWidth, window.innerHeight]")
                    print(f"{lang}/{size}/{theme}: окно {inner}", flush=True)
                    checks(d, lang, size, theme)
                    name = f"{lang}-{size}-{theme}"
                    shots(d, name, inner[1])
                    if not update: compare(name)
        finally:
            d.quit()
    set_theme(False)
    if update:
        BASE.mkdir(parents=True, exist_ok=True)
        for f in OUT.glob("*.png"):
            if not f.name.startswith("DIFF-"): shutil.copy(f, BASE / f.name)
    print("итог:", "ПРОВАЛЕНО %d" % len(fails) if fails else "ок")
    sys.exit(1 if fails else 0)
main()
