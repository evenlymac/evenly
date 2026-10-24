//! Evenly для Windows: приложение в трее.
//! Поведение как у macOS-версии: «приложение открыто = Evenly работает», выключателя нет;
//! значок E из трёх планок, одна копия, автозапуск (HKCU Run), en/ru по языку системы,
//! мягкая подсказка, если системный эффект (APO) не установлен.
//! Сам звук обрабатывает APO (evenly_apo.dll в audiodg.exe), приложение его устанавливает и снимает.
#![windows_subsystem = "windows"]

use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Globalization::GetUserDefaultUILanguage;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::*;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

const RUN_KEY: PCWSTR = w!(r"Software\Microsoft\Windows\CurrentVersion\Run");
const RUN_NAME: PCWSTR = w!("Evenly");
const STATE_FILE: &str = r"C:\ProgramData\Evenly\backup\state.json";
const WM_TRAY: u32 = WM_APP + 1;
const ID_LOGIN: usize = 1;
const ID_INSTALL: usize = 2;
const ID_UNINSTALL: usize = 3;
const ID_QUIT: usize = 4;
const TIMER_REFRESH: usize = 1;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Lang {
    En,
    Ru,
}

fn lang() -> Lang {
    // LANG_RUSSIAN = 0x19
    if unsafe { GetUserDefaultUILanguage() } & 0x3ff == 0x19 {
        Lang::Ru
    } else {
        Lang::En
    }
}

struct Text {
    login: &'static str,
    install: &'static str,
    uninstall: &'static str,
    quit: &'static str,
    hint_title: &'static str,
    hint_body: &'static str,
    ask_login_title: &'static str,
    ask_login_body: &'static str,
    tip: &'static str,
    tip_off: &'static str,
}

fn text(l: Lang) -> Text {
    match l {
        Lang::En => Text {
            login: "Launch Evenly at Login",
            install: "Turn On System-Wide Effect…",
            uninstall: "Remove System-Wide Effect…",
            quit: "Quit Evenly",
            hint_title: "Evenly isn't processing this device's audio",
            hint_body: "The system audio effect is not installed, so Evenly can't level the volume. Open the Evenly menu in the tray and choose “Turn On System-Wide Effect…” (administrator permission is needed once).",
            ask_login_title: "Launch Evenly at login?",
            ask_login_body: "Evenly levels your volume only while it is running. If it doesn't open at login, it stays off after every restart or sign-in until you start it yourself. You can change this at any time in the Evenly menu. Evenly will ask again the next time it starts without launch at login.",
            tip: "Evenly",
            tip_off: "Evenly: system-wide effect is not installed",
        },
        Lang::Ru => Text {
            login: "Запускать Evenly при входе",
            install: "Включить системный эффект…",
            uninstall: "Убрать системный эффект…",
            quit: "Выйти из Evenly",
            hint_title: "Evenly не обрабатывает звук этого устройства",
            hint_body: "Системный звуковой эффект не установлен, поэтому Evenly не может выравнивать громкость. Откройте меню Evenly в трее и выберите «Включить системный эффект…» (один раз понадобится разрешение администратора).",
            ask_login_title: "Запускать Evenly при входе?",
            ask_login_body: "Evenly выравнивает громкость только пока запущен. Если он не открывается при входе, то после каждой перезагрузки или входа остаётся выключенным, пока вы не запустите его сами. Это можно изменить в любой момент в меню Evenly. Evenly спросит снова при следующем запуске без автозапуска.",
            tip: "Evenly",
            tip_off: "Evenly: системный эффект не установлен",
        },
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn exe_path() -> PathBuf {
    std::env::current_exe().unwrap_or_default()
}

// ---------- автозапуск (HKCU Run) ----------

fn login_enabled() -> bool {
    let mut size = 0u32;
    let r = unsafe {
        RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME, RRF_RT_REG_SZ, None, None, Some(&mut size))
    };
    r == ERROR_SUCCESS
}

fn set_login(on: bool) -> bool {
    unsafe {
        if on {
            let v: Vec<u16> = std::iter::once(b'"' as u16)
                .chain(exe_path().as_os_str().encode_wide())
                .chain(std::iter::once(b'"' as u16))
                .chain(std::iter::once(0))
                .collect();
            let bytes = std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * 2);
            RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME, REG_SZ.0, Some(bytes.as_ptr() as *const _), bytes.len() as u32)
                == ERROR_SUCCESS
        } else {
            let r = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME);
            r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND
        }
    }
}

// ---------- системный эффект (APO) ----------

fn apo_installed() -> bool {
    std::path::Path::new(STATE_FILE).exists()
}

/// Запускает установщик с правами администратора (UAC один раз).
fn run_installer(action: &str) {
    let dir = exe_path().parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let script = dir.join("evenly-apo.ps1");
    let dll = dir.join("evenly_apo.dll");
    let mut args = format!("-NoProfile -ExecutionPolicy Bypass -File \"{}\" -Action {}", script.display(), action);
    if action == "install" {
        args += &format!(" -Dll \"{}\"", dll.display());
    }
    let verb = wide("runas");
    let file = wide("powershell.exe");
    let params = wide(&args);
    unsafe {
        ShellExecuteW(None, PCWSTR(verb.as_ptr()), PCWSTR(file.as_ptr()), PCWSTR(params.as_ptr()), None, SW_SHOWNORMAL);
    }
}

// ---------- значок: буква E из трёх планок ----------

/// Рисуем в памяти 32x32 BGRA: нижняя планка полной длины, средняя короче на полвысоты, верхняя на высоту,
/// общая вертикальная стенка (как MenuBarIcon в macOS-версии). `on=false` рисует бледнее.
fn icon_pixels(size: usize, on: bool) -> Vec<u32> {
    let s = size as f32;
    let t = s * 3.2 / 18.0;
    let gap = t * 0.853;
    let len = t * 3.45;
    let total_h = 3.0 * t + 2.0 * gap;
    let ox = (s - len) / 2.0;
    let oy = (s - total_h) / 2.0;
    let alpha: u32 = if on { 255 } else { 100 };
    let lens = [len, len - t / 2.0, len - t];
    let mut px = vec![0u32; size * size];
    let inside = |x: f32, y: f32| -> bool {
        // вертикальная стенка
        if x >= ox && x < ox + t && y >= oy + 0.6 * s / 18.0 && y < oy + total_h - 0.6 * s / 18.0 {
            return true;
        }
        for i in 0..3 {
            // y сверху вниз: нижняя планка (i=0) внизу
            let top = oy + total_h - (i as f32) * (t + gap) - t;
            if y >= top && y < top + t && x >= ox && x < ox + lens[i] {
                return true;
            }
        }
        false
    };
    for yy in 0..size {
        for xx in 0..size {
            // 4x4 субсэмплинг для сглаживания
            let mut hit = 0;
            for sy in 0..4 {
                for sx in 0..4 {
                    if inside(xx as f32 + (sx as f32 + 0.5) / 4.0, yy as f32 + (sy as f32 + 0.5) / 4.0) {
                        hit += 1;
                    }
                }
            }
            if hit > 0 {
                let a = alpha * hit / 16;
                // белый на прозрачном (трей Windows чаще тёмный); премультиплицированный BGRA
                px[yy * size + xx] = (a << 24) | (a << 16) | (a << 8) | a;
            }
        }
    }
    px
}

fn make_icon(on: bool) -> HICON {
    let size = unsafe { GetSystemMetrics(SM_CXSMICON) }.max(16) as usize;
    let px = icon_pixels(size, on);
    unsafe {
        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: size as i32,
                biHeight: -(size as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let color = CreateDIBSection(None, &bmi, DIB_RGB_COLORS, &mut bits, None, 0).expect("dib");
        std::ptr::copy_nonoverlapping(px.as_ptr(), bits as *mut u32, px.len());
        let mask = CreateBitmap(size as i32, size as i32, 1, 1, None);
        let info = ICONINFO { fIcon: TRUE, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color };
        let icon = CreateIconIndirect(&info).expect("icon");
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon
    }
}

// ---------- окно и трей ----------

struct App {
    lang: Lang,
    installed: bool,
    icon_on: HICON,
    icon_off: HICON,
}

static mut APP: Option<App> = None;

fn app() -> &'static mut App {
    #[allow(static_mut_refs)]
    unsafe {
        APP.as_mut().unwrap()
    }
}

fn copy_wide<const N: usize>(dst: &mut [u16; N], s: &str) {
    let v: Vec<u16> = s.encode_utf16().take(N - 1).collect();
    dst[..v.len()].copy_from_slice(&v);
    dst[v.len()] = 0;
}

fn nid(hwnd: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        ..Default::default()
    }
}

fn tray_update(hwnd: HWND, add: bool) {
    let a = app();
    let t = text(a.lang);
    let mut d = nid(hwnd);
    d.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    d.uCallbackMessage = WM_TRAY;
    d.hIcon = if a.installed { a.icon_on } else { a.icon_off };
    copy_wide(&mut d.szTip, if a.installed { t.tip } else { t.tip_off });
    unsafe {
        if add {
            let _ = Shell_NotifyIconW(NIM_ADD, &d);
            d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
            let _ = Shell_NotifyIconW(NIM_SETVERSION, &d);
        } else {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
        }
    }
}

fn show_hint(hwnd: HWND) {
    let t = text(app().lang);
    let mut d = nid(hwnd);
    d.uFlags = NIF_INFO;
    d.dwInfoFlags = NIIF_WARNING;
    copy_wide(&mut d.szInfoTitle, t.hint_title);
    copy_wide(&mut d.szInfo, t.hint_body);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
    }
}

fn show_menu(hwnd: HWND) {
    let a = app();
    let t = text(a.lang);
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let login = wide(t.login);
        let flags = MF_STRING | if login_enabled() { MF_CHECKED } else { MF_UNCHECKED };
        let _ = AppendMenuW(menu, flags, ID_LOGIN, PCWSTR(login.as_ptr()));
        let sys = wide(if a.installed { t.uninstall } else { t.install });
        let _ = AppendMenuW(menu, MF_STRING, if a.installed { ID_UNINSTALL } else { ID_INSTALL }, PCWSTR(sys.as_ptr()));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let quit = wide(t.quit);
        let _ = AppendMenuW(menu, MF_STRING, ID_QUIT, PCWSTR(quit.as_ptr()));
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let _ = SetForegroundWindow(hwnd);
        let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, Some(0), hwnd, None);
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY => {
            let ev = (lp.0 as u32) & 0xffff;
            if ev == WM_RBUTTONUP || ev == WM_LBUTTONUP || ev == WM_CONTEXTMENU {
                show_menu(hwnd);
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            match wp.0 & 0xffff {
                ID_LOGIN => {
                    let _ = set_login(!login_enabled());
                }
                ID_INSTALL => run_installer("install"),
                ID_UNINSTALL => run_installer("uninstall"),
                ID_QUIT => {
                    let _ = DestroyWindow(hwnd);
                }
                _ => {}
            }
            LRESULT(0)
        }
        WM_TIMER => {
            // установщик работает отдельно (UAC): раз в 3 с перечитываем состояние
            let now = apo_installed();
            let a = app();
            if now != a.installed {
                a.installed = now;
                tray_update(hwnd, false);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            let d = nid(hwnd);
            let _ = Shell_NotifyIconW(NIM_DELETE, &d);
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Одна копия: именованный mutex в сеансе пользователя.
fn single_instance() -> bool {
    unsafe {
        let _ = CreateMutexW(None, true, w!("Local\\EvenlyTray"));
        GetLastError() != ERROR_ALREADY_EXISTS
    }
}

fn selftest() -> i32 {
    let mut fails = 0;
    let mut check = |name: &str, ok: bool| {
        println!("{} {}", if ok { "ok  " } else { "FAIL" }, name);
        if !ok {
            fails += 1;
        }
    };
    let l = lang();
    println!("lang={:?}", l);
    check("text en/ru не пустые", !text(Lang::En).hint_title.is_empty() && !text(Lang::Ru).hint_title.is_empty());
    let was = login_enabled();
    check("автозапуск: включить", set_login(true) && login_enabled());
    check("автозапуск: выключить", set_login(false) && !login_enabled());
    let _ = set_login(was);
    let px = icon_pixels(32, true);
    let lit = px.iter().filter(|p| **p != 0).count();
    println!("icon lit pixels = {}", lit);
    check("значок: нарисованы планки", lit > 100 && lit < 600);
    check("значок: создаётся HICON", !make_icon(true).is_invalid());
    check("одна копия: первая проходит", single_instance());
    check("одна копия: вторая отклоняется", !single_instance());
    println!("apo_installed={}", apo_installed());
    if fails == 0 { 0 } else { 1 }
}

fn main() {
    if std::env::args().any(|a| a == "--selftest") {
        // под windows_subsystem=windows консоли нет: пишем в файл рядом
        let code = {
            use std::io::Write;
            let _ = writeln!(std::io::stdout());
            selftest()
        };
        std::process::exit(code);
    }
    if !single_instance() {
        return;
    }
    unsafe {
        let hinst = GetModuleHandleW(None).unwrap();
        let class = w!("EvenlyTrayWindow");
        let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: hinst.into(), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0), class, w!("Evenly"), WS_OVERLAPPED, 0, 0, 0, 0, None, None, Some(hinst.into()), None,
        )
        .expect("window");
        APP = Some(App {
            lang: lang(),
            installed: apo_installed(),
            icon_on: make_icon(true),
            icon_off: make_icon(false),
        });
        tray_update(hwnd, true);
        SetTimer(Some(hwnd), TIMER_REFRESH, 3000, None);
        if !app().installed {
            show_hint(hwnd);
        }
        if !login_enabled() {
            let t = text(app().lang);
            let (title, body) = (wide(t.ask_login_title), wide(t.ask_login_body));
            let r = MessageBoxW(None, PCWSTR(body.as_ptr()), PCWSTR(title.as_ptr()), MB_YESNO | MB_ICONQUESTION | MB_TOPMOST);
            if r == IDYES {
                let _ = set_login(true);
            }
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
