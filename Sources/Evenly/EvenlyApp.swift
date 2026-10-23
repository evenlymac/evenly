import SwiftUI
import ServiceManagement

final class AppState: ObservableObject {
    private let engine = AudioEngine()
    private var probe: Probe?
    @Published var isOn: Bool { didSet { UserDefaults.standard.set(isOn, forKey: "on"); apply() } }
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
        isOn = UserDefaults.standard.object(forKey: "on") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let req = Probe.requested {
            probe = Probe()
            probe?.run(path: req.path, seconds: req.seconds)
        } else {
            apply()
        }
    }

    private func apply() {
        engine.onError = { [weak self] in self?.error = $0 }
        if isOn { engine.enable() } else { engine.disable() }
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
        Toggle("Evenly", isOn: $state.isOn)
        Toggle("Запускать при входе", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
        if let e = state.error { Text(e).font(.caption) }
        Divider()
        Button("Выйти") { state.shutdown(); NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Значок меню-бара: шаблонное изображение 18×18 pt (максимум по HIG для значка в строке меню высотой 24 pt),
/// пять скруглённых столбиков на всю высоту; при выключении те же столбики бледнее.
enum MenuBarIcon {
    static func image(on: Bool) -> NSImage {
        let side: CGFloat = 18
        let heights: [CGFloat] = [8, 14, 18, 14, 8]
        let barW: CGFloat = 2.4, gap: CGFloat = 1.5
        let total = barW * 5 + gap * 4
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.withAlphaComponent(on ? 1 : 0.4).setFill()
            var x = (rect.width - total) / 2
            for h in heights {
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
    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(nsImage: MenuBarIcon.image(on: state.isOn))
        }
    }
}
