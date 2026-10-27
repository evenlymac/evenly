// GENERATED from i18n/strings.json by scripts/i18n-gen.py: do not edit by hand
struct Text {
    login: &'static str,
    quit: &'static str,
    ask_login_title: &'static str,
    toggle: &'static str,
    update: &'static str,
    tip_paused: &'static str,
    upd_title: &'static str,
    upd_body: &'static str,
    hint_title: &'static str,
    hint_body: &'static str,
    ask_login_body: &'static str,
    tip: &'static str,
    tip_off: &'static str,
}

fn text(l: Lang) -> Text {
    match l {
        Lang::En => Text {
            login: "Launch Evenly at Login",
            quit: "Quit Evenly",
            ask_login_title: "Launch Evenly at login?",
            toggle: "Level Volume",
            update: "Update System-Wide Effect…",
            tip_paused: "Evenly: paused (audio passes unchanged)",
            upd_title: "Evenly: update available",
            upd_body: "A newer system audio effect came with this version of Evenly. Open the Evenly menu in the tray and choose “Update System-Wide Effect…”. Playback keeps going; administrator permission is needed once.",
            hint_title: "Evenly isn't processing this device's audio",
            hint_body: "The system audio effect is not installed, so Evenly can't level the volume. Run the Evenly installer again (administrator permission is needed once).",
            ask_login_body: "Evenly levels your volume only while it is running. If it doesn't open at login, it stays off after every restart or sign-in until you start it yourself. You can change this at any time in the Evenly menu. Evenly will ask again the next time it starts without launch at login.",
            tip: "Evenly",
            tip_off: "Evenly: system-wide effect is not installed",
        },
        Lang::Ru => Text {
            login: "Запускать Evenly при входе",
            quit: "Закрыть Evenly",
            ask_login_title: "Запускать Evenly при входе в систему?",
            toggle: "Выравнивать громкость",
            update: "Обновить системный эффект…",
            tip_paused: "Evenly: приостановлен (звук идёт без изменений)",
            upd_title: "Evenly: доступно обновление",
            upd_body: "Вместе с этой версией Evenly пришёл более новый системный звуковой эффект. Откройте меню Evenly в трее и выберите «Обновить системный эффект…». Воспроизведение не прерывается; один раз понадобится разрешение администратора.",
            hint_title: "Evenly не обрабатывает звук этого устройства",
            hint_body: "Системный звуковой эффект не установлен, поэтому Evenly не может выравнивать громкость. Запустите установщик Evenly ещё раз (один раз понадобится разрешение администратора).",
            ask_login_body: "Evenly выравнивает громкость только пока запущен. Если он не открывается при входе, то после каждой перезагрузки или входа остаётся выключенным, пока вы не запустите его сами. Это можно изменить в любой момент в меню Evenly. Evenly спросит снова при следующем запуске без автозапуска.",
            tip: "Evenly",
            tip_off: "Evenly: системный эффект не установлен",
        },
    }
}
