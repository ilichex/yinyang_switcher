import CoreGraphics
import SwitcherCore

/// Печатает за пользователя: стирает Backspace'ом и набирает новый текст.
/// Все события помечены, чтобы перехватчик клавиатуры не принял их за ввод человека.
enum TextInjector {
    static let marker: Int64 = 0x5959_5357 // "YYSW"

    private static let source = CGEventSource(stateID: .privateState)
    private static let backspaceKey: CGKeyCode = 51

    static func apply(_ edit: TextEdit) {
        for _ in 0..<edit.deleteCount {
            press(backspaceKey)
        }
        type(edit.insert)
    }

    static func type(_ text: String) {
        // По символу на событие: длинные строки в одном событии понимают не все программы.
        for c in text {
            let utf16 = Array(String(c).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(event)
            }
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
