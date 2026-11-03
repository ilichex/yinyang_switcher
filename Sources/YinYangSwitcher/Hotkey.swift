import AppKit
import Carbon

/// Клавиша ручного исправления. Все варианты — «чистые» нажатия модификаторов:
/// они ничего не печатают и не мешают обычным сочетаниям.
enum Hotkey: String, CaseIterable {
    case doubleShift, doubleOption, rightOption, rightCommand

    var title: String {
        switch self {
        case .doubleShift: "Двойной ⇧ Shift"
        case .doubleOption: "Двойной ⌥ Option"
        case .rightOption: "Правый ⌥ Option"
        case .rightCommand: "Правый ⌘ Command"
        }
    }

    /// Коротко, для строки меню.
    var shortTitle: String {
        switch self {
        case .doubleShift: "двойной ⇧"
        case .doubleOption: "двойной ⌥"
        case .rightOption: "правый ⌥"
        case .rightCommand: "правый ⌘"
        }
    }

    var keyCodes: Set<Int> {
        switch self {
        case .doubleShift: [kVK_Shift, kVK_RightShift]
        case .doubleOption: [kVK_Option, kVK_RightOption]
        case .rightOption: [kVK_RightOption]
        case .rightCommand: [kVK_RightCommand]
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .doubleShift: .maskShift
        case .doubleOption, .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        }
    }

    /// Двойное нажатие или одно.
    var isDouble: Bool { self == .doubleShift || self == .doubleOption }
}
