Evenly for Windows / Evenly для Windows

Evenly levels the volume of everything you play. Open it and it works.
Evenly выравнивает громкость всего, что вы слушаете. Открыли приложение, и оно работает.

Install / Установка
Use the Evenly installer (Evenly-<version>-windows-setup.exe): it installs the app and the system-wide effect (administrator permission once).
SmartScreen may warn (the app is not signed yet): "More info" -> "Run anyway".
Пользуйтесь установщиком Evenly (Evenly-<версия>-windows-setup.exe): он ставит приложение и системный эффект (один раз нужен администратор).
SmartScreen может предупредить (подписи пока нет): «Подробнее» -> «Выполнить в любом случае».

Remove / Удаление: Settings -> Apps -> Evenly -> Uninstall (the effect is removed too).
Параметры -> Приложения -> Evenly -> Удалить (эффект снимается вместе с приложением).

Without the installer (this folder only) / Без установщика (только эта папка):
the tray has no effect commands; run these in PowerShell as administrator from this folder.
в трее нет команд эффекта; выполните в PowerShell от имени администратора из этой папки.
  Turn on / включить: powershell -NoProfile -ExecutionPolicy Bypass -File .\evenly-apo.ps1 -Action install -Dll .\evenly_apo.dll
  Remove / убрать:    powershell -NoProfile -ExecutionPolicy Bypass -File .\evenly-apo.ps1 -Action uninstall
