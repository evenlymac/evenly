// Рисует иконку Evenly в набор .iconset: плоский тёмный скруглённый квадрат и буква E из трёх
// одинаковых цветных планок (ровные уровни). Без теней и свечения. Совпадает с MenuBarIcon.
// Запуск: swift scripts/make-icon.swift build/Evenly.iconset
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func color(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let m = s * 0.098
    let rect = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    color(0x17192E).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()
    // E: пропорции как в MenuBarIcon (сетка 18×18)
    let u = rect.width * 0.66 / 15
    let t = 3.2 * u, armLen = 11 * u
    let ox = rect.midX - armLen / 2, oy = rect.midY - 15 * u / 2
    let gap = (15 * u - 3 * t) / 2
    color(0xF2F3F8).setFill()
    NSBezierPath(rect: NSRect(x: ox, y: oy + t / 2, width: t, height: 15 * u - t)).fill()
    let arms: [Int] = [0x2FD6A4, 0xFFC233, 0xFF5C66]  // снизу вверх
    for (i, c) in arms.enumerated() {
        color(c).setFill()
        NSBezierPath(roundedRect: NSRect(x: ox, y: oy + CGFloat(i) * (t + gap), width: armLen, height: t), xRadius: t * 0.18, yRadius: t * 0.18).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
