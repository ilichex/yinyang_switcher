import Carbon
import SwitcherCore

/// Русская и английская раскладки, включённые в системе.
final class InputSources {
    private(set) var ru: TISInputSource?
    private(set) var en: TISInputSource?
    private(set) var map: LayoutMap = .macRussian
    /// Поддерживается только та пара источников ввода, для которой построена карта.
    var currentLang: Lang? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let identifier = Self.identifier(current) else { return nil }
        if identifier == en.flatMap(Self.identifier) { return .en }
        if identifier == ru.flatMap(Self.identifier) { return .ru }
        return nil
    }
    private var selectionRevision: UInt64 = 0

    init() {
        reload()
        updateCurrent()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateCurrent() }
    }

    func reload() {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        ru = list.first { Self.primaryLanguage($0) == "ru" }
        en = list.first { Self.primaryLanguage($0) == "en" }
        if let en, let ru, let systemMap = LayoutMap.fromSystem(en: en, ru: ru) {
            map = systemMap
        }
    }

    var isReady: Bool { ru != nil && en != nil }

    func select(_ lang: Lang) {
        guard let source = lang == .ru ? ru : en else { return }
        selectionRevision &+= 1
        let revision = selectionRevision
        let previous = (TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()).flatMap(Self.identifier)
        TISSelectInputSource(source)
        // Изредка macOS не применяет переключение сразу — тогда следующие буквы шли бы
        // в старой раскладке. Проверяем и повторяем.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.selectionRevision == revision,
                  let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  Self.identifier(current) != Self.identifier(source),
                  Self.identifier(current) == previous else { return }
            TISSelectInputSource(source)
        }
    }

    private func updateCurrent() {
        // Любая подтверждённая смена раскладки делает старый повтор ненужным.
        selectionRevision &+= 1
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first
    }
}
