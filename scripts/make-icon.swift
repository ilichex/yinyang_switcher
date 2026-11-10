// Рисует иконку приложения (инь-ян) и собирает Resources/AppIcon.icns.
// Запуск: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Фон: скруглённый квадрат с глубоким градиентом.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.36, green: 0.30, blue: 0.86, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.09, blue: 0.27, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Инь-ян.
    let r = tile.width * 0.33
    ctx.saveGState()
    // Без наклона: точки инь-яна строго на вертикали, как в строке меню и logo.svg.
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let dark = NSColor(red: 0.07, green: 0.06, blue: 0.14, alpha: 1).cgColor
    let light = NSColor(white: 0.97, alpha: 1).cgColor
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: r))
    path.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    path.addArc(center: CGPoint(x: 0, y: -r / 2), radius: r / 2, startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: false)
    path.addArc(center: CGPoint(x: 0, y: r / 2), radius: r / 2, startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: true)
    path.closeSubpath()
    ctx.setFillColor(dark)
    ctx.addPath(path)
    ctx.fillPath()
    let dot = r / 6.5
    ctx.setFillColor(light)
    ctx.fillEllipse(in: CGRect(x: -dot, y: -r / 2 - dot, width: 2 * dot, height: 2 * dot))
    ctx.setFillColor(dark)
    ctx.fillEllipse(in: CGRect(x: -dot, y: r / 2 - dot, width: 2 * dot, height: 2 * dot))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns готов" : "iconutil завершился с ошибкой")
