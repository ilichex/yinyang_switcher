import CoreGraphics
import SwitcherCore

/// Печатает за пользователя: стирает Backspace'ом и набирает новый текст.
/// Все события помечены, чтобы перехватчик клавиатуры не принял их за ввод человека.
enum TextInjector {
    static let marker: Int64 = 0x5959_5357 // "YYSW"

    private static let source = CGEventSource(stateID: .privateState)
    private static let backspaceKey: CGKeyCode = 51

    /// Перед курсором то, что мы собираемся стереть? Сверяем, только если правка задевает
    /// уже законченные слова — их могла поменять автозамена. Программа не отвечает — верим себе.
    /// nil — на экране другое, править нельзя.
    static func checked(_ edit: TextEdit, targetPID: Int64? = nil) -> TextEdit? {
        guard edit.maxLag < edit.deleteCount else { return edit }
        let lag = edit.removed.suffix(edit.maxLag).utf16.count
        guard let screen = SelectionReader.textBeforeCursor(edit.removed.utf16.count + lag, targetPID: targetPID) else { return edit }
        return edit.adjusted(toScreen: screen)
    }

    static func apply(_ edit: TextEdit, proxy: CGEventTapProxy? = nil) {
        for _ in 0..<edit.deleteCount {
            press(backspaceKey, proxy: proxy)
        }
        type(edit.insert, proxy: proxy)
    }

    static func type(_ text: String, proxy: CGEventTapProxy? = nil) {
        // По символу на событие: длинные строки в одном событии понимают не все программы.
        for c in text {
            let utf16 = Array(String(c).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(event, proxy: proxy)
            }
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = [], proxy: CGEventTapProxy? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            post(event, proxy: proxy)
        }
    }

    static func post(_ event: CGEvent, proxy: CGEventTapProxy? = nil) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        if let proxy {
            // Внутри перехватчика продолжаем текущий поток, не возвращаемся в его начало.
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
