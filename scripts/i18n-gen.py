#!/usr/bin/env python3
"""Генератор переводов Evenly из единого источника i18n/strings.json (en/ru) для всех платформ.
  python3 -I scripts/i18n-gen.py          записать сгенерированные файлы
  python3 -I scripts/i18n-gen.py --check  проверить: источник корректен, а файлы в репозитории не расходятся с ним (job consistency в CI)
Генерируются: Resources/{en,ru}.lproj/{Localizable,InfoPlist}.strings (macOS), windows/tray/src/strings.rs (трей Windows),
windows/installer/messages.iss (установщик), блок i18n в linux/evenly-linux.sh, сайт site/index.html (ru) и site/en/index.html (en)
из шаблона site/index.tpl.html и текстов i18n/site.json ({{str:id}} в тексте = строка программы из strings.json). Руками эти места не правят."""
import json, re, sys, pathlib

R = pathlib.Path(__file__).resolve().parent.parent
CYR = re.compile(r"[А-Яа-яЁё]")
HDR = "GENERATED from i18n/strings.json by scripts/i18n-gen.py: do not edit by hand"
data = json.loads((R / "i18n/strings.json").read_text(encoding="utf-8"))["strings"]
site = json.loads((R / "i18n/site.json").read_text(encoding="utf-8"))["site"]
TPL = (R / "site/index.tpl.html").read_text(encoding="utf-8")
PH = re.compile(r"\{\{([a-z_0-9:]+)\}\}")

def validate():
    errs, ids = [], set()
    for e in data:
        i = e.get("id", "?")
        if i in ids: errs.append(f"повтор id {i}")
        ids.add(i)
        for l in ("en", "ru"):
            if not e.get(l, "").strip(): errs.append(f"{i}: пусто {l}")
        if CYR.search(e.get("en", "")): errs.append(f"{i}: en содержит кириллицу")
        brand_only = not re.sub(r"Evenly|\W", "", e.get("en", ""))
        if not CYR.search(e.get("ru", "")) and not brand_only: errs.append(f"{i}: ru не переведено")
        if sorted(re.findall(r"\{\d\}", e.get("en", ""))) != sorted(re.findall(r"\{\d\}", e.get("ru", ""))): errs.append(f"{i}: подстановки en и ru разные")
        if not any(e.get(t) for t in ("mac", "win", "inst", "linux", "plist")): errs.append(f"{i}: нет цели")
    return errs + validate_site(ids)

SYS = {"lang", "alt_lang", "alt_href", "alt_name", "ver"}
def validate_site(str_ids):
    errs, ids = [], set()
    for e in site:
        i = e.get("id", "?")
        if i in ids: errs.append(f"сайт: повтор id {i}")
        ids.add(i)
        for l in ("en", "ru"):
            if not e.get(l, "").strip(): errs.append(f"сайт {i}: пусто {l}")
            if "<" in e.get(l, ""): errs.append(f"сайт {i}: {l} содержит <")
        if CYR.search(e.get("en", "")): errs.append(f"сайт {i}: en содержит кириллицу")
        if not CYR.search(e.get("ru", "")): errs.append(f"сайт {i}: ru не переведено")
        if sorted(PH.findall(e.get("en", ""))) != sorted(PH.findall(e.get("ru", ""))): errs.append(f"сайт {i}: ссылки {{{{…}}}} в en и ru разные")
        for l in ("en", "ru"):
            for r in PH.findall(e.get(l, "")):
                if not (r.startswith("str:") and r[4:] in str_ids): errs.append(f"сайт {i}: неизвестная ссылка {{{{{r}}}}} (нужна {{{{str:id}}}} из strings.json)")
    used = set(PH.findall(TPL))
    for r in sorted(used - ids - SYS): errs.append(f"шаблон: нет текста для {{{{{r}}}}} в i18n/site.json")
    for r in sorted(ids - used): errs.append(f"i18n/site.json: текст {r} не используется в шаблоне")
    return errs

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def mac(lang):
    body = "".join(f'"{esc(e["en"])}" = "{esc(e[lang])}";\n' for e in data if e.get("mac"))
    return f"/* {HDR} */\n" + body
def plist(lang):
    body = "".join(f'"{esc(e["plist"])}" = "{esc(e[lang])}";\n' for e in data if e.get("plist"))
    return f"/* {HDR} */\n" + body

def rust():
    w = [e for e in data if e.get("win")]
    out = [f"// {HDR}\n", "struct Text {\n"] + [f"    {e['win']}: &'static str,\n" for e in w] + ["}\n\n", "fn text(l: Lang) -> Text {\n    match l {\n"]
    for lang, var in (("en", "En"), ("ru", "Ru")):
        out.append(f"        Lang::{var} => Text {{\n")
        out += [f'            {e["win"]}: "{esc(e[lang])}",\n' for e in w]
        out.append("        },\n")
    out.append("    }\n}\n")
    return "".join(out)

def iss():
    inst = [e for e in data if e.get("inst")]
    out = [f"; {HDR}\n"]
    for e in inst: out.append(f'english.{e["inst"]}={e["en"].replace("{0}", "%1")}\n')
    for e in inst: out.append(f'russian.{e["inst"]}={e["ru"].replace("{0}", "%1")}\n')
    return "".join(out)

def bash_q(s): return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
BEGIN = "# >>> i18n: " + HDR + "\n"; END = "# <<< i18n\n"
def linux_block():
    out = [BEGIN, "M() {   # M имя [подстановка {0}]: сообщение на языке системы\n  local s\n  case \"$1\" in\n"]
    for e in data:
        if e.get("linux"):
            out.append(f'    {e["linux"]}) if [ "$RU" = 1 ]; then s={bash_q(e["ru"])}; else s={bash_q(e["en"])}; fi ;;\n')
    out += ["  esac\n", "  printf '%s\\n' \"${s//\\{0\\}/${2:-}}\"\n", "}\n", END]
    return "".join(out)

def linux_script(cur):
    blk = linux_block()
    if BEGIN in cur: return re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), lambda m: blk, cur, flags=re.S)
    raise SystemExit("в linux/evenly-linux.sh нет блока i18n (маркеры # >>> i18n ... # <<< i18n)")

def render_site(lang):
    alt = "en" if lang == "ru" else "ru"
    strs = {e["id"]: e[lang] for e in data}
    vals = {e["id"]: PH.sub(lambda m: strs[m.group(1)[4:]], e[lang]) for e in site}
    vals.update(lang=lang, alt_lang=alt, alt_href="en/" if lang == "ru" else "../", alt_name={"ru": "Русский", "en": "English"}[alt],
                ver=(R / "site/VERSION").read_text().strip())
    return PH.sub(lambda m: vals[m.group(1)], TPL)

def targets():
    t = {}
    for l in ("en", "ru"):
        t[f"Resources/{l}.lproj/Localizable.strings"] = mac(l)
        t[f"Resources/{l}.lproj/InfoPlist.strings"] = plist(l)
    t["windows/tray/src/strings.rs"] = rust()
    t["windows/installer/messages.iss"] = iss()
    t["site/index.html"] = render_site("ru")
    t["site/en/index.html"] = render_site("en")
    t["linux/evenly-linux.sh"] = linux_script((R / "linux/evenly-linux.sh").read_text(encoding="utf-8"))
    return t

errs = validate()
if errs:
    print("i18n/strings.json:"); [print("  -", e) for e in errs]; sys.exit(1)
drift = []
for p, txt in targets().items():
    f = R / p
    cur = f.read_text(encoding="utf-8") if f.exists() else None
    if cur != txt:
        if "--check" in sys.argv: drift.append(p)
        else: f.parent.mkdir(parents=True, exist_ok=True); f.write_text(txt, encoding="utf-8"); print("обновлён", p)
if drift:
    print("СГЕНЕРИРОВАННЫЕ ФАЙЛЫ РАСХОДЯТСЯ С i18n/strings.json (правили руками или забыли запустить scripts/i18n-gen.py):")
    [print("  -", p) for p in drift]; sys.exit(1)
print("ок: i18n/strings.json корректен, платформы сгенерированы из него" if "--check" in sys.argv else "готово")
