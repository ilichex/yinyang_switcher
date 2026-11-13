import AppKit
import SwitcherCore

private struct EmptyDictionary: SpellChecking {
    func isValid(_ word: String, lang: Lang) -> Bool { false }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let detector = Detector(map: .macRussian, scorer: Scorer(spell: EmptyDictionary()))
let session = TypingSession(detector: detector)
let monitor = KeyboardMonitor(session: session)

// Горячая клавиша в новой программе должна помнить цель даже без обычного набора.
monitor.updateTarget(100)
session.type("ghbdtn")
let revision = monitor.inputRevision
monitor.updateTarget(100)
check(session.text == "ghbdtn", "Повторная команда в той же программе потеряла память")
check(monitor.inputRevision == revision, "Та же программа отменила ожидающую команду")
monitor.updateTarget(200)
check(session.text.isEmpty, "Смена программы оставила чужой текст в памяти")
check(monitor.inputRevision != revision, "Смена программы не отменила ожидающую команду")
session.replacedSelection("ghbdtn", with: "привет", changes: [], lang: .ru)
monitor.updateTarget(200)
check(session.undoLastFix()?.edit.insert == "ghbdtn", "В новой программе не работает повторная отмена")
print("PASS: смена приложения и повторная отмена")

// Локальное текстовое поле: никакие события в систему не отправляются.
let view = NSTextView(frame: .zero)
let examples = ["ghbdtn", "🙂 ghbdtn", "👨‍👩‍👧‍👦 ghbdtn", "e\u{301} ghbdtn"]
for original in examples {
    view.string = "не трогать | " + original
    view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    let edit = TextEdit(removed: original, insert: "привет")
    for _ in 0..<edit.deleteCount { view.deleteBackward(nil) }
    view.insertText(edit.insert, replacementRange: view.selectedRange())
    check(view.string == "не трогать | привет", "AppKit удалил лишний символ: \(original)")
}
print("PASS: удаление Unicode в AppKit (4 сценария)")

// Именованный буфер изолирован от NSPasteboard.general пользователя.
let pasteboard = NSPasteboard(name: .init("YinYangTests-" + UUID().uuidString))
let customType = NSPasteboard.PasteboardType("org.yinyang.test-data")
pasteboard.setString("исходный текст", forType: .string)
pasteboard.setData(Data([0, 1, 255]), forType: customType)
let saved = Clipboard.save(pasteboard)
pasteboard.clearContents()
pasteboard.setString("временное значение", forType: .string)
Clipboard.restore(saved, to: pasteboard)
check(pasteboard.string(forType: .string) == "исходный текст", "Не восстановлен текст буфера")
check(pasteboard.data(forType: customType) == Data([0, 1, 255]), "Потерян дополнительный формат буфера")
pasteboard.releaseGlobally()
print("PASS: восстановление всех форматов тестового буфера")
