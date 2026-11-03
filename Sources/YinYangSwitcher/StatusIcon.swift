import AppKit

/// Инь-ян в строке меню. Крутится один оборот, когда раскладка исправлена.
final class StatusIcon {
    private let button: NSStatusBarButton
    private let frames: [NSImage]
    private let offImage = YinYang.offImage(size: 18)
    private var timer: Timer?
    private var frame = 0

    private static let frameCount = 36
    private static let duration: TimeInterval = 0.6

    init(button: NSStatusBarButton) {
        self.button = button
        frames = (0..<Self.frameCount).map { i in
            YinYang.image(size: 18, angle: -2 * .pi * CGFloat(i) / CGFloat(Self.frameCount))
        }
        button.image = frames[0]
        updateTip()
    }

    /// Сочетание «включить/выключить» для подсказки, например «⌥⌘».
    var shortcutTitle: String? {
        didSet { updateTip() }
    }

    private func updateTip() {
        let state = dimmed ? "YinYang выключен" : "YinYang исправляет раскладку"
        let action = dimmed ? "включить" : "выключить"
        button.toolTip = shortcutTitle.map { "\(state) · \($0) — \(action)" } ?? state
    }

    /// Выключен: блёклый инь-ян, перечёркнутый, — видно с первого взгляда.
    var dimmed = false {
        didSet {
            timer?.invalidate()
            button.image = dimmed ? offImage : frames[0]
            updateTip()
        }
    }

    func spin() {
        guard !dimmed else { return }
        timer?.invalidate()
        frame = 0
        let step = Self.duration / Double(Self.frameCount)
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            frame += 1
            // Плавное замедление к концу оборота.
            let t = Double(frame) / Double(Self.frameCount)
            let eased = 1 - pow(1 - t, 2)
            let index = min(Int(eased * Double(Self.frameCount)), Self.frameCount - 1)
            button.image = frames[frame >= Self.frameCount ? 0 : index]
            if frame >= Self.frameCount { timer.invalidate() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}

enum YinYang {
    /// Монохромный шаблон: macOS сама перекрасит его под светлую/тёмную строку меню.
    static func image(size: CGFloat, angle: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: angle)
            draw(in: ctx, radius: size / 2 - 1.5, dark: .black, light: nil, outline: 1.3)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Выключенное состояние: инь-ян вполсилы и косая черта поверх, с просветом вокруг неё.
    static func offImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.setAlpha(0.4)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.translateBy(x: rect.midX, y: rect.midY)
            draw(in: ctx, radius: size / 2 - 1.5, dark: .black, light: nil, outline: 1.3)
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            let from = CGPoint(x: rect.minX + 2.5, y: rect.maxY - 2.5)
            let to = CGPoint(x: rect.maxX - 2.5, y: rect.minY + 2.5)
            ctx.setLineCap(.round)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(4.4)
            ctx.strokeLineSegments(between: [from, to])
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(.black)
            ctx.setLineWidth(1.9)
            ctx.strokeLineSegments(between: [from, to])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Рисует инь-ян с центром в начале координат. `light == nil` — светлая половина прозрачная.
    static func draw(in ctx: CGContext, radius r: CGFloat, dark: CGColor, light: CGColor?, outline: CGFloat) {
        let circle = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        if let light {
            ctx.setFillColor(light)
            ctx.fillEllipse(in: circle)
        }

        // Тёмная половина: левый полукруг + нижняя «головка» справа − верхняя слева.
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
        // Светлая точка в тёмной головке.
        let darkHead = CGRect(x: -dot, y: -r / 2 - dot, width: 2 * dot, height: 2 * dot)
        if let light {
            ctx.setFillColor(light)
            ctx.fillEllipse(in: darkHead)
        } else {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: darkHead)
            ctx.setBlendMode(.normal)
        }
        // Тёмная точка в светлой головке.
        ctx.setFillColor(dark)
        ctx.fillEllipse(in: CGRect(x: -dot, y: r / 2 - dot, width: 2 * dot, height: 2 * dot))

        if outline > 0 {
            ctx.setStrokeColor(dark)
            ctx.setLineWidth(outline)
            ctx.strokeEllipse(in: circle.insetBy(dx: outline / 2 - 0.5, dy: outline / 2 - 0.5))
        }
    }
}
