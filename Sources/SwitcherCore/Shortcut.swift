import Foundation

/// Сочетание клавиш «включить/выключить»: либо одни модификаторы — нажать вместе и отпустить
/// (⌥⌘), либо модификаторы с клавишей (⌃⌥Y).
public struct Shortcut: Equatable {
    /// Биты модификаторов, как в CGEventFlags.
    public var modifiers: UInt64
    /// nil — аккорд из одних модификаторов.
    public var keyCode: Int?

    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let option: UInt64 = 0x80000
    public static let command: UInt64 = 0x100000
    public static let allModifiers = shift | control | option | command

    public static let defaultToggle = Shortcut(modifiers: option | command)

    public init(modifiers: UInt64, keyCode: Int? = nil) {
        self.modifiers = modifiers & Self.allModifiers
        self.keyCode = keyCode
    }

    /// «⌃⌥⇧⌘» в привычном для macOS порядке.
    public var modifierSymbols: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
}

/// Узнаёт аккорд из модификаторов: все нужные зажаты вместе, ничего лишнего, ни одной
/// другой клавиши или клика, и отпущены быстро. Так ⌥⌘ не срабатывает внутри ⌥⌘Esc,
/// ⌥⌘-перетаскивания или когда модификаторы просто долго держат.
public struct ChordDetector {
    public var target: UInt64
    public static let maxHold: TimeInterval = 1.0

    private var peak: UInt64 = 0
    private var peakAt: TimeInterval = 0
    private var spoiled = false

    public init(target: UInt64) {
        self.target = target
    }

    /// Модификаторы изменились. true — аккорд нажат и отпущен.
    public mutating func flags(_ current: UInt64, at time: TimeInterval) -> Bool {
        let current = current & Shortcut.allModifiers
        if current & ~peak != 0 {
            peak |= current
            peakAt = time
        }
        guard current == 0 else { return false }
        defer { peak = 0; spoiled = false }
        return target != 0 && !spoiled && peak == target && time - peakAt < Self.maxHold
    }

    /// Нажата обычная клавиша или кнопка мыши — это было другое сочетание.
    public mutating func interrupt() {
        if peak != 0 { spoiled = true }
    }
}

/// Запоминает сочетание, которое нажал пользователь: модификаторы с клавишей — сразу по
/// нажатию клавиши, аккорд — когда отпущены все модификаторы (от двух и больше).
public struct ShortcutRecorder {
    private var peak: UInt64 = 0

    public init() {}

    public mutating func flags(_ current: UInt64) -> Shortcut? {
        let current = current & Shortcut.allModifiers
        peak |= current
        guard current == 0 else { return nil }
        defer { peak = 0 }
        return peak.nonzeroBitCount >= 2 ? Shortcut(modifiers: peak) : nil
    }

    public mutating func key(_ code: Int, modifiers: UInt64) -> Shortcut {
        peak = 0
        return Shortcut(modifiers: modifiers, keyCode: code)
    }
}
