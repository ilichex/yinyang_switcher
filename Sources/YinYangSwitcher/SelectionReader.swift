import AppKit
import Carbon

/// Выделенный текст в активной программе.
enum SelectionReader {
    enum AXResult {
        /// Пустая строка — программа ответила, что ничего не выделено.
        case text(String)
        /// Программа не умеет отдавать выделение через Accessibility (часто Electron).
        case unsupported
    }

    static func viaAccessibility() -> AXResult {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        var value: CFTypeRef?
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return .text(text)
    }

    /// Текст перед курсором, `count` символов UTF-16 (или меньше у начала документа).
    /// nil — программа не говорит (Electron, терминалы) или что-то выделено: проверить нечем.
    static func textBeforeCursor(_ count: Int) -> String? {
        let system = AXUIElementCreateSystemWide()
        // Зависшая программа не должна держать клавиатуру: ждём её не дольше 50 мс.
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var rangeValue: CFTypeRef?
        var selection = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection),
              selection.length == 0, selection.location >= 0 else { return nil }
        let start = max(0, selection.location - count)
        var range = CFRange(location: start, length: selection.location - start)
        guard let wanted = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, wanted, &text
        ) == .success else { return nil }
        return text as? String
    }

    /// Копирует через ⌘C и возвращает буфер обмена как был.
    static func viaClipboard(_ completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.save(pasteboard)
        let before = pasteboard.changeCount
        TextInjector.press(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount != before else { return completion(nil) }
            let copied = pasteboard.string(forType: .string)
            Clipboard.restore(saved, to: pasteboard)
            // Без выделения некоторые редакторы (VS Code) копируют всю строку с переводом строки.
            guard let copied, !copied.isEmpty, !copied.hasSuffix("\n") else { return completion(nil) }
            completion(copied)
        }
    }
}

/// Снимок буфера обмена со всеми типами данных, чтобы вернуть его нетронутым.
enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func save(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
