import Foundation

/// Считает быстрые нажатия одной клавиши: одно, два или три подряд.
///
/// Для модификаторов есть и нажатие, и отпускание: засчитывается только короткое «чистое»
/// нажатие (без других клавиш между ними). Для обычных клавиш (F-клавиши) отпускание
/// не отслеживаем — считаем нажатия.
public struct TapDetector {
    public var count: Int
    /// Дольше — это удержание, а не нажатие.
    public static let tapLength: TimeInterval = 0.3
    /// Больше паузы между нажатиями — серия начинается заново.
    public static let gap: TimeInterval = 0.35

    private var downAt: TimeInterval?
    private var taps = 0
    private var lastTap = -TimeInterval.infinity

    public init(count: Int) {
        self.count = max(1, count)
    }

    /// Модификатор нажат.
    public mutating func press(at time: TimeInterval) {
        if time - lastTap > Self.gap { taps = 0 }
        downAt = time
    }

    /// Модификатор отпущен. true — набралась нужная серия.
    public mutating func release(at time: TimeInterval) -> Bool {
        guard let downAt, time - downAt < Self.tapLength else {
            interrupt()
            return false
        }
        self.downAt = nil
        return tap(at: time)
    }

    /// Обычная клавиша нажата. true — набралась нужная серия.
    public mutating func keyPress(at time: TimeInterval) -> Bool {
        if time - lastTap > Self.gap { taps = 0 }
        return tap(at: time)
    }

    /// Между нажатиями было что-то ещё (другая клавиша, клик) — серия сорвана.
    public mutating func interrupt() {
        downAt = nil
        taps = 0
        lastTap = -.infinity
    }

    private mutating func tap(at time: TimeInterval) -> Bool {
        taps += 1
        lastTap = time
        guard taps >= count else { return false }
        taps = 0
        lastTap = -.infinity
        return true
    }
}
