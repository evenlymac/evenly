// Рисует иконку Evenly (скруглённый квадрат, выровненные столбики) в набор .iconset. Запуск: swift scripts/make-icon.swift build/Evenly.iconset
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.78, blue: 0.62, alpha: 1), NSColor(red: 0.10, green: 0.42, blue: 0.62, alpha: 1)])!.draw(in: bg, angle: -60)
    NSColor.white.setFill()
    let heights: [CGFloat] = [0.26, 0.38, 0.38, 0.38, 0.26]
    let w = s * 0.075, gap = s * 0.055
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    var x = (s - total) / 2
    for h in heights {
        let bh = s * h
        NSBezierPath(roundedRect: NSRect(x: x, y: (s - bh) / 2, width: w, height: bh), xRadius: w / 2, yRadius: w / 2).fill()
        x += w + gap
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
