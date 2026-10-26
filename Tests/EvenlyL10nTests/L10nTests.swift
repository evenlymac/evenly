import Foundation
import XCTest

/// Проверка локализации (en/ru): всё, что видит пользователь в коде, должно быть переведено.
/// Ловит ошибку 0.2.4: пункт меню «Level Volume» добавили в код, а в ru.lproj перевода не было.
final class L10nTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ lang: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
        guard let d = NSDictionary(contentsOf: url) as? [String: String] else {
            throw XCTSkip("не разобрать \(url.path)")
        }
        return d
    }

    /// Литералы, которые показываются пользователю: NSLocalizedString("…"), Button/Toggle/Text/Label/Section/Menu("…").
    private func uiStrings() throws -> Set<String> {
        let dir = root.appendingPathComponent("Sources/Evenly")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let re = try NSRegularExpression(
            pattern: #"(?:NSLocalizedString|Button|Toggle|Text|Label|Section|Menu)\(\s*"((?:[^"\\]|\\.)*)""#)
        var out = Set<String>()
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s) else { continue }
                out.insert(String(s[r]).replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return out
    }

    func testEveryUIStringIsTranslated() throws {
        let en = try table("en"), ru = try table("ru")
        let used = try uiStrings()
        XCTAssertFalse(used.isEmpty, "не нашли ни одной строки интерфейса: сломан разбор кода")
        for s in used.sorted() {
            XCTAssertNotNil(en[s], "нет в en.lproj: \(s)")
            guard let t = ru[s] else { XCTFail("нет в ru.lproj: \(s)"); continue }
            XCTAssertTrue(t.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil, "ru не переведено: \(s)")
        }
    }

    func testNoStaleOrMismatchedKeys() throws {
        let en = try table("en"), ru = try table("ru")
        XCTAssertEqual(Set(en.keys), Set(ru.keys), "наборы ключей en и ru разные")
        let used = try uiStrings()
        for k in en.keys where !used.contains(k) { XCTFail("ключ не используется в коде: \(k)") }
    }

    func testPlaceholdersMatch() throws {
        let en = try table("en"), ru = try table("ru")
        let re = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@dfsl]+"#)
        func ph(_ s: String) -> [String] {
            re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }.sorted()
        }
        for (k, v) in ru { XCTAssertEqual(ph(k), ph(v), "разные подстановки в ru: \(k)") }
        for (k, v) in en { XCTAssertEqual(ph(k), ph(v), "разные подстановки в en: \(k)") }
    }

    func testBundleLocalizationsDeclared() throws {
        let s = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(s.contains("<string>en</string><string>ru</string>"), "в Info.plist не объявлены en и ru")
        XCTAssertTrue(s.contains("ru.lproj"), "сборка не копирует ru.lproj")
    }
}
