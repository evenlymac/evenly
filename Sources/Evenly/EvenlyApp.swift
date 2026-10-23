import SwiftUI
import ServiceManagement
import os

final class AppState: ObservableObject {
    private let engine = AudioEngine()
    private var probe: Probe?
    @Published var launchAtLogin: Bool
    @Published var error: String?
    @Published var noAccess = false
    private var accessAlertShown = false

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
            engine.onAccessIssue = { [weak self] in self?.accessIssueChanged($0) }
            engine.enable()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerLaunchAtLogin() }
        }
    }

    /// Нет доступа к системному звуку: значок бледнеет, в меню появляется кнопка, один раз за запуск показываем объяснение.
    private func accessIssueChanged(_ issue: Bool) {
        noAccess = issue
        guard issue, !accessAlertShown else { return }
        accessAlertShown = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Evenly can't hear your Mac's audio", comment: "")
        alert.informativeText = NSLocalizedString("Other apps are playing sound, but none of it reaches Evenly. This usually means access to system audio wasn't granted. Open System Settings → Privacy & Security → Screen & System Audio Recording and turn on Evenly. If your sound is simply off right now, you can ignore this message.", comment: "")
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: NSLocalizedString("Open Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn { Self.openAudioSettings() }
    }

    static func openAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(url) }
    }

    /// При каждом запуске, если автозапуск выключен, показываем окно с предложением включить его.
    private func offerLaunchAtLogin() {
        Logger(subsystem: "app.evenly", category: "login").info("login status=\(SMAppService.mainApp.status.rawValue)")
        guard SMAppService.mainApp.status != .enabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Launch Evenly at login?", comment: "")
        alert.informativeText = NSLocalizedString("Evenly levels your volume only while it is running. If it doesn't open at login, it stays off after every restart or sign-in until you start it yourself. You can change this at any time in the Evenly menu or in System Settings → General → Login Items. Evenly will ask again the next time it starts without launch at login.", comment: "")
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: NSLocalizedString("Launch at Login", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
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
        if state.noAccess {
            Button("Allow Access to System Audio…") { AppState.openAudioSettings() }
            Divider()
        }
        Toggle("Launch Evenly at Login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
            .onAppear { state.refreshLaunchAtLogin() }
        if let e = state.error { Text(e).font(.caption) }
        Divider()
        Button("Quit Evenly") { state.shutdown(); NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Значок меню-бара: шаблонное изображение 18×18 pt (максимум по HIG для значка в строке меню высотой 24 pt),
/// пять скруглённых столбиков на всю высоту; при выключении те же столбики бледнее.
enum MenuBarIcon {
    /// Планка: слева скруглена, справа скруглена или срезана под прямой угол.
    static func bar(_ r: NSRect, radius k: CGFloat, roundRight: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let rr = roundRight ? k : 0
        p.move(to: NSPoint(x: r.minX + k, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rr, y: r.minY))
        if roundRight { p.appendArc(withCenter: NSPoint(x: r.maxX - k, y: r.minY + k), radius: k, startAngle: -90, endAngle: 0) }
        else { p.line(to: NSPoint(x: r.maxX, y: r.minY)) }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - rr))
        if roundRight { p.appendArc(withCenter: NSPoint(x: r.maxX - k, y: r.maxY - k), radius: k, startAngle: 0, endAngle: 90) }
        else { p.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
        p.line(to: NSPoint(x: r.minX + k, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + k, y: r.maxY - k), radius: k, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: r.minX, y: r.minY + k))
        p.appendArc(withCenter: NSPoint(x: r.minX + k, y: r.minY + k), radius: k, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    /// Буква E из трёх планок: нижняя полной длины, средняя короче на полвысоты, верхняя на высоту. Шаблон 18×18 pt.
    static func image(on: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.withAlphaComponent(on ? 1 : 0.4).setFill()
            let t: CGFloat = 3.2, gap = t * 0.853, len = t * 3.45
            let totalH = 3 * t + 2 * gap
            let ox = (18 - len) / 2, oy = (18 - totalH) / 2
            let lens = [len, len - t / 2, len - t]
            NSRect(x: ox, y: oy + 0.6, width: t, height: totalH - 1.2).fill()
            for i in 0..<3 {
                bar(NSRect(x: ox, y: oy + CGFloat(i) * (t + gap), width: lens[i], height: t), radius: 0.7, roundRight: true).fill()
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
            Image(nsImage: MenuBarIcon.image(on: !state.noAccess))
                .onReceive(loginCheck) { _ in state.refreshLaunchAtLogin() }
        }
    }
}
