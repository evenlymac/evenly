// Рисует иконку Evenly в набор .iconset: тёмный скруглённый квадрат, десять цветных столбиков
// (слева громкость скачет, справа выровнена; цвет идёт от тёплого к холодному).
// Запуск: swift scripts/make-icon.swift build/Evenly.iconset
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
// Те же пропорции, что в MenuBarIcon.relative
let rel: [CGFloat] = [1.0, 0.16, 0.82, 0.30, 0.62, 0.40, 0.52, 0.45, 0.47, 0.46]
let colors: [NSColor] = [
    NSColor(red: 1.00, green: 0.36, blue: 0.40, alpha: 1), NSColor(red: 1.00, green: 0.50, blue: 0.30, alpha: 1),
    NSColor(red: 1.00, green: 0.68, blue: 0.20, alpha: 1), NSColor(red: 1.00, green: 0.84, blue: 0.25, alpha: 1),
    NSColor(red: 0.74, green: 0.90, blue: 0.30, alpha: 1), NSColor(red: 0.40, green: 0.86, blue: 0.45, alpha: 1),
    NSColor(red: 0.18, green: 0.84, blue: 0.64, alpha: 1), NSColor(red: 0.15, green: 0.76, blue: 0.82, alpha: 1),
    NSColor(red: 0.28, green: 0.60, blue: 0.98, alpha: 1), NSColor(red: 0.45, green: 0.45, blue: 1.00, alpha: 1)]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let m = s * 0.098
    let rect = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    let r = rect.width * 0.225
    let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    // тень под плиткой
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
    sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.012); sh.set()
    NSColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1).setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.34, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.13, alpha: 1)])!.draw(in: bg, angle: -90)
    // блик по верхней кромке плитки
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY + rect.height * 0.12, width: rect.width, height: rect.height * 0.38), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // столбики
    let area = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.17)
    let n = CGFloat(rel.count)
    let w = area.width / (n + (n - 1) * 0.62), gap = w * 0.62
    var x = area.minX
    for (i, k) in rel.enumerated() {
        let h = max(area.height * k, w)
        let bar = NSRect(x: x, y: area.midY - h / 2, width: w, height: h)
        let p = NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = colors[i].withAlphaComponent(0.55)
        glow.shadowBlurRadius = s * 0.03; glow.shadowOffset = .zero; glow.set()
        colors[i].setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [colors[i].highlight(withLevel: 0.35)!, colors[i], colors[i].shadow(withLevel: 0.18)!])!.draw(in: p, angle: -90)
        x += w + gap
    }
    NSColor.white.withAlphaComponent(0.10).setStroke(); bg.lineWidth = max(1, s * 0.004); bg.stroke()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
