// Рисует иконку Evenly в набор .iconset: плоский тёмный скруглённый квадрат и буква E из трёх
// одинаковых цветных планок (ровные уровни). Без теней и свечения. Совпадает с MenuBarIcon.
// Запуск: swift scripts/make-icon.swift build/Evenly.iconset
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func color(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
    /// Планка: слева скруглена, справа скруглена или срезана под прямой угол.
func bar(_ r: NSRect, radius k: CGFloat, roundRight: Bool) -> NSBezierPath {
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
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let m = s * 0.098
    let rect = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    color(0x17192E).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()
    // E: нижняя планка полной длины, средняя короче на полвысоты, верхняя на высоту (скруглённый конец)
    let t = rect.width * 0.66 / 15 * 3.2, gap = t * 0.853, len = t * 3.45
    let totalH = 3 * t + 2 * gap
    let ox = rect.midX - len / 2, oy = rect.midY - totalH / 2
    let lens = [len, len - t / 2, len - t]  // снизу вверх
    let arms: [Int] = [0x2FD6A4, 0xFFC233, 0xFF5C66]
    color(0xF2F3F8).setFill()
    NSRect(x: ox, y: oy + t * 0.18, width: t, height: totalH - t * 0.36).fill()
    for i in 0..<3 {
        color(arms[i]).setFill()
        bar(NSRect(x: ox, y: oy + CGFloat(i) * (t + gap), width: lens[i], height: t), radius: t * 0.18, roundRight: true).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
