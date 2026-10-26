# Evenly

Выравнивает громкость всего звука на компьютере: тихое слышно, громкое не бьёт по ушам.
Скачать: **https://evenlymac.github.io** (установщики под macOS, Windows и Linux).

| Платформа | Как работает | Папка |
|---|---|---|
| macOS (Apple silicon, 14.2+) | меню-бар приложение, захват через Core Audio taps | `Sources/` |
| Windows 10/11 | системный звуковой эффект (APO) и значок в трее | `windows/` |
| Linux (PulseAudio или PipeWire) | виртуальный выход «Evenly» и фильтр `evenly-pcm` | `linux/` |

Ядро выравнивания общее: на macOS это `Sources/EvenlyDSP`, на Windows и Linux его порт на Rust в `core/`
(результат совпадает с версией на Swift бит в бит, проверка по «золотым» векторам в `core/golden`).

На всех платформах есть выключатель обработки без остановки звука: пункт «Выравнивать громкость» в меню
(macOS, Windows) и `evenly-linux.sh on|off` (Linux). Значок в меню бледнеет, когда обработка выключена.

## Сборка и тесты
- macOS: `scripts/build-app.sh`, тесты `swift test` (нужен Xcode).
- Ядро и Linux: `cd core && cargo test`, `cd linux/pcm && cargo test`.
- Windows: сборка на Windows или `cargo xwin build --release --target x86_64-pc-windows-msvc` в `windows/apo` и `windows/tray`;
  установщик `windows/install/evenly-apo.ps1` (`install`, `update`, `uninstall`, нужны права администратора).
- CI: `.github/workflows` (Windows и Linux собираются и проверяются на раннерах GitHub).

Лицензия пока не выбрана.
