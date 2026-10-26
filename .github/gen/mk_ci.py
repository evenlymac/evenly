#!/usr/bin/env python3
# Собирает .github/workflows/ci.yml из шагов прежних workflow (одноразово). Запуск: python3 -I .github/gen/mk_ci.py
import re, pathlib
W = pathlib.Path(".github/workflows")

def job_parts(fname):
    L = (W / fname).read_text(encoding="utf-8").split("\n")
    i = next(k for k, l in enumerate(L) if l == "jobs:")
    hdr_start = i + 2                      # после "  имя:"
    steps_i = next(k for k, l in enumerate(L) if l == "    steps:")
    hdr = [l for l in L[hdr_start:steps_i] if not l.startswith("    if:")]
    end = next((k for k, l in enumerate(L) if "push results to ci-results" in l), len(L))
    steps = L[steps_i + 1:end]
    while steps and steps[-1] == "": steps.pop()
    return hdr, steps

def gate(steps, gate_lines):
    # заменяем последний «exit 0» шага на проверки результата
    idx = max(k for k, l in enumerate(steps) if l.strip() == "exit 0")
    ind = " " * 10
    return steps[:idx] + [ind + g for g in gate_lines] + steps[idx + 1:]

def job(name, fname, cond, gate_lines, artifact, extra_needs=""):
    hdr, steps = job_parts(fname)
    steps = [s.replace("set +e", "set +e  # шаги идут до конца ради логов; итог решает проверка в конце") for s in steps]
    steps = gate(steps, gate_lines)
    out = [f"  {name}:", "    needs: changes", f"    if: needs.changes.outputs.{cond} == 'true'"] + hdr + ["    steps:"] + steps
    out += ["      - name: logs as artifact", "        if: always()", "        uses: actions/upload-artifact@v4",
            "        with:", f"          name: {artifact}-logs", "          path: logs", "          retention-days: 14",
            "          if-no-files-found: ignore"]
    return out

linux_gate = [
 'fail=0',
 'for f in clippy fmt shellcheck; do tail -1 logs/$f.txt | grep -q "exit=0" || { echo "FAIL: $f"; fail=1; }; done',
 'grep -q "test result: FAILED" logs/core-test.txt logs/pcm-test.txt && { echo "FAIL: cargo test"; fail=1; }',
 'grep -q "test result: ok" logs/core-test.txt || { echo "FAIL: core tests did not run"; fail=1; }',
 'grep -q "E2E PASS" logs/e2e.txt || { echo "FAIL: e2e"; fail=1; }',
 'ls logs/*.tar.gz >/dev/null 2>&1 || { echo "FAIL: package"; fail=1; }',
 'exit $fail',
]
win_gate = [
 'fail=0',
 'grep -q "test result: FAILED" logs/core-test.txt && { echo "FAIL: core test"; fail=1; }',
 'grep -q "test result: ok" logs/core-test.txt || { echo "FAIL: core tests did not run"; fail=1; }',
 'tail -1 logs/harness-run.txt | grep -q "exit=0" || { echo "FAIL: harness"; fail=1; }',
 'tail -1 logs/tray-selftest.txt | grep -q "exit=0" || { echo "FAIL: tray selftest"; fail=1; }',
 'ls logs/*.zip >/dev/null 2>&1 || { echo "FAIL: package"; fail=1; }',
 'exit $fail',
]
inst_gate = [
 'fail=0',
 'grep -q "^exit=[1-9]" logs/test.txt && { echo "FAIL: installer step exit code"; grep -n "^exit=" logs/test.txt; fail=1; }',
 'ls logs/*-windows-setup.exe >/dev/null 2>&1 || { echo "FAIL: setup not built"; fail=1; }',
 'tail -3 logs/test.txt | tr -d "\\r" | grep -vq "^False$" && { echo "FAIL: leftovers after uninstall"; tail -3 logs/test.txt; fail=1; }',
 'exit $fail',
]

head = '''name: ci
# Регрессионные проверки при каждом push в main: гоняем только то, что изменение могло затронуть.
# Падение = красный прогон; итог собирает job «gate» (по нему блокируется релиз). Сводка: scripts/ci-watch.sh на сервере.
on:
  push:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: "17 2 * * *"   # ночной полный прогон
permissions:
  contents: read
env:
  CARGO_TERM_COLOR: never
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      mac: ${{ steps.f.outputs.mac }}
      core: ${{ steps.f.outputs.core }}
      linux: ${{ steps.f.outputs.linux }}
      win: ${{ steps.f.outputs.win }}
      installer: ${{ steps.f.outputs.installer }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: f
        run: |
          base="${{ github.event.before }}"
          if [ "${{ github.event_name }}" != "push" ] || [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ] || ! git cat-file -e "$base" 2>/dev/null; then
            files="ALL"
          else
            files="$(git diff --name-only "$base" "${{ github.sha }}")"
          fi
          echo "изменено: $files"
          has() { [ "$files" = "ALL" ] || echo "$files" | grep -Eq "$1"; }
          mac=false; core=false; linux=false; win=false; installer=false
          has '^(Sources/|Tests/|Resources/|Package\\.swift|scripts/(build-app|package)\\.sh|\\.github/workflows/ci\\.yml)' && mac=true
          has '^(core/|Sources/EvenlyDSP/|\\.github/workflows/ci\\.yml)' && core=true
          has '^(linux/|core/|\\.github/workflows/ci\\.yml)' && linux=true
          has '^(windows/|core/|\\.github/workflows/ci\\.yml)' && win=true
          has '^(windows/|\\.github/workflows/ci\\.yml)' && installer=true
          echo "mac=$mac core=$core linux=$linux win=$win installer=$installer"
          { echo "mac=$mac"; echo "core=$core"; echo "linux=$linux"; echo "win=$win"; echo "installer=$installer"; } >> "$GITHUB_OUTPUT"
'''

core_job = '''  core:
    needs: changes
    if: needs.changes.outputs.core == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: тесты общего ядра и совпадение с эталоном Swift (golden)
        run: cd core && EVENLY_GOLDEN_DIR="$GITHUB_WORKSPACE/core/golden" cargo test 2>&1
'''

mac_job = '''  macos:
    needs: changes
    if: needs.changes.outputs.mac == 'true'
    runs-on: macos-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: swift test (DSP и локализация), сборка и упаковка
        run: |
          set +e
          mkdir -p logs
          swift --version 2>&1 | tee logs/swift.txt
          swift test 2>&1 | tail -80 | tee logs/swift-test.txt
          zsh scripts/build-app.sh 2>&1 | tail -40 | tee logs/build-app.txt
          codesign -dv build/Evenly.app 2>&1 | tee logs/codesign.txt
          VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Evenly.app/Contents/Info.plist)
          mkdir -p dist/dmg
          cp -R build/Evenly.app dist/dmg/ && ln -s /Applications dist/dmg/Applications
          ditto -c -k --keepParent build/Evenly.app "dist/Evenly-$VER.zip"
          hdiutil create -volname Evenly -srcfolder dist/dmg -ov -format UDZO "dist/Evenly-$VER.dmg" > /dev/null
          ls -l dist | tee logs/package.txt
          lipo -archs build/Evenly.app/Contents/MacOS/Evenly | tee logs/arch.txt
          fail=0
          grep -q "with 0 failures" logs/swift-test.txt || { echo "FAIL: swift test"; fail=1; }
          grep -Eq "with [1-9][0-9]* failure" logs/swift-test.txt && { echo "FAIL: swift test failures"; fail=1; }
          grep -q "^OK: build/Evenly.app" logs/build-app.txt || { echo "FAIL: build-app"; fail=1; }
          grep -q "arm64" logs/arch.txt || { echo "FAIL: not arm64"; fail=1; }
          ls dist/Evenly-*.dmg >/dev/null 2>&1 || { echo "FAIL: dmg"; fail=1; }
          exit $fail
      - name: logs as artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: macos-logs
          path: logs
          retention-days: 14
          if-no-files-found: ignore
'''

gate_job = '''  gate:
    # Итог регрессии: красный, если упал любой запущенный job (пропущенные не в счёт). По нему блокируется релиз.
    if: always()
    needs: [changes, core, macos, linux, windows, installer]
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo '${{ toJSON(needs) }}' | tr -d '\\n' | grep -Eq '"result": *"(failure|cancelled)"' && { echo "CI красный"; exit 1; }
          echo "CI зелёный"
'''

out = head + core_job + mac_job
out += "\n".join(job("linux", "linux.yml", "linux", linux_gate, "linux")) + "\n"
out += "\n".join(job("windows", "windows.yml", "win", win_gate, "windows")) + "\n"
out += "\n".join(job("installer", "windows-installer.yml", "installer", inst_gate, "installer")) + "\n"
out += gate_job
(W / "ci.yml").write_text(out, encoding="utf-8")
print("ci.yml:", len(out.splitlines()), "строк")
