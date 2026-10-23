import SwiftUI
import ServiceManagement
import os

final class AppState: ObservableObject {
    private let engine = AudioEngine()
    private var probe: Probe?
    @Published var launchAtLogin: Bool
    @Published var error: String?

    init() {
        // Одна копия: если Evenly уже запущен, второй экземпляр сразу выходит (режим замера не считается).
        if Probe.requested == nil, let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
                exit(0)
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let req = Probe.requested {
            probe = Probe()
            probe?.run(path: req.path, seconds: req.seconds)
        } else {
            // Приложение открыто = Evenly работает: выключателя нет.
            engine.onError = { [weak self] in self?.error = $0 }
            engine.enable()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerLaunchAtLogin() }
        }
    }

    /// При каждом запуске, если автозапуск выключен, показываем окно с предложением включить его.
    private func offerLaunchAtLogin() {
        Logger(subsystem: "app.evenly", category: "login").info("login status=\(SMAppService.mainApp.status.rawValue)")
        guard SMAppService.mainApp.status != .enabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Запускать Evenly при входе в систему?"
        alert.informativeText = "Тогда громкость будет выравниваться сразу после включения Mac, без ручного запуска. Отключить можно в меню Evenly или в Настройках → Основные → Объекты входа."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Включить автозапуск")
        alert.addButton(withTitle: "Не сейчас")
        if alert.runModal() == .alertFirstButtonReturn { setLaunchAtLogin(true) }
    }

    /// Автозапуск можно отключить снаружи (Настройки → Основные → Объекты входа): перечитываем состояние
    /// при каждом открытии меню и раз в минуту, чтобы переключатель не врал.
    func refreshLaunchAtLogin() {
        let on = SMAppService.mainApp.status == .enabled
        if on != launchAtLogin { launchAtLogin = on }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "\(error)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutdown() { engine.disable() }
}

struct MenuView: View {
    @ObservedObject var state: AppState
    var body: some View {
        Toggle("Запускать при входе", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
            .onAppear { state.refreshLaunchAtLogin() }
        if let e = state.error { Text(e).font(.caption) }
        Divider()
        Button("Выйти") { state.shutdown(); NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Значок меню-бара: шаблонное изображение 18×18 pt (максимум по HIG для значка в строке меню высотой 24 pt),
/// пять скруглённых столбиков на всю высоту; при выключении те же столбики бледнее.
enum MenuBarIcon {
    /// Десять столбиков: слева громкость скачет, справа выровнена. Шаблон 38×18 pt.
    static let relative: [CGFloat] = [1.0, 0.16, 0.82, 0.30, 0.62, 0.40, 0.52, 0.45, 0.47, 0.46]

    static func image(on: Bool) -> NSImage {
        let size = NSSize(width: 38, height: 18)
        let barW: CGFloat = 2.3, gap: CGFloat = 1.5
        let total = barW * CGFloat(relative.count) + gap * CGFloat(relative.count - 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(on ? 1 : 0.4).setFill()
            var x = (rect.width - total) / 2
            for r in relative {
                let h = max(3, r * rect.height)
                NSBezierPath(roundedRect: NSRect(x: x, y: (rect.height - h) / 2, width: barW, height: h),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

@main
struct EvenlyApp: App {
    @StateObject private var state = AppState()
    private let loginCheck = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(nsImage: MenuBarIcon.image(on: true))
                .onReceive(loginCheck) { _ in state.refreshLaunchAtLogin() }
        }
    }
}
