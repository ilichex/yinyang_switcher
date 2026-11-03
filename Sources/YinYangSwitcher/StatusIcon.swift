import AppKit

/// Инь-ян в строке меню. Делает один спокойный оборот, когда раскладка исправлена.
final class StatusIcon {
    private let button: NSStatusBarButton
    private let image = YinYang.image(size: 18, angle: 0)
    private let offImage = YinYang.offImage(size: 18)
    private var spinning = false

    private static let duration: CFTimeInterval = 0.8

    init(button: NSStatusBarButton) {
        self.button = button
        button.wantsLayer = true
        button.image = image
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

    /// Выключен: от инь-яна остаётся одна тёмная половина — видно с первого взгляда.
    var dimmed = false {
        didSet {
            button.layer?.removeAnimation(forKey: "spin")
            spinning = false
            button.image = dimmed ? offImage : image
            updateTip()
        }
    }

    /// Один оборот по часовой стрелке. Пока он идёт, новые исправления его не перезапускают:
    /// при быстрых переключениях подряд значок спокойно докручивается, а не дёргается.
    func spin() {
        guard !dimmed, !spinning, let layer = button.layer else { return }
        spinning = true
        // Оборот ведёт Core Animation, а не таймер в главном потоке: печать исправления и
        // смена раскладки занимают главный поток, и покадровая анимация от этого рвалась.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: button.frame.midX, y: button.frame.midY)
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.duration = Self.duration
        rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.spinning = false }
        layer.add(rotation, forKey: "spin")
        CATransaction.commit()
        // Отправить сразу, не дожидаясь конца текущего прохода главного цикла.
        CATransaction.flush()
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

    /// Выключенное состояние: от инь-яна остаётся одна тёмная половина, сдвинутая к центру.
    static func offImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = size / 2 - 1.5
            // Половина занимает по ширине от −r до r/2 — сдвигаем её середину в центр значка.
            ctx.translateBy(x: rect.midX + r / 4, y: rect.midY)
            ctx.setFillColor(.black)
            ctx.addPath(darkHalf(radius: r))
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: darkHeadDot(radius: r))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Тёмная половина: левый полукруг + нижняя «головка» справа − верхняя слева.
    static func darkHalf(radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: r))
        path.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        path.addArc(center: CGPoint(x: 0, y: -r / 2), radius: r / 2, startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: false)
        path.addArc(center: CGPoint(x: 0, y: r / 2), radius: r / 2, startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Светлая точка в тёмной головке.
    static func darkHeadDot(radius r: CGFloat) -> CGRect {
        let dot = r / 6.5
        return CGRect(x: -dot, y: -r / 2 - dot, width: 2 * dot, height: 2 * dot)
    }

    /// Рисует инь-ян с центром в начале координат. `light == nil` — светлая половина прозрачная.
    static func draw(in ctx: CGContext, radius r: CGFloat, dark: CGColor, light: CGColor?, outline: CGFloat) {
        let circle = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        if let light {
            ctx.setFillColor(light)
            ctx.fillEllipse(in: circle)
        }

        ctx.setFillColor(dark)
        ctx.addPath(darkHalf(radius: r))
        ctx.fillPath()

        let dot = r / 6.5
        let darkHead = darkHeadDot(radius: r)
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
