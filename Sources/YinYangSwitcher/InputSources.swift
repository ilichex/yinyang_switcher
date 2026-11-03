import Carbon
import SwitcherCore

/// Русская и английская раскладки, включённые в системе.
final class InputSources {
    private(set) var ru: TISInputSource?
    private(set) var en: TISInputSource?
    private(set) var map: LayoutMap = .macRussian
    /// Сейчас включена русская или английская раскладка. На любой другой (украинская,
    /// японская, Dvorak с другим языком) программа молчит: её слова мы не понимаем.
    private(set) var currentIsSupported = true

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
        TISSelectInputSource(source)
        // Изредка macOS не применяет переключение сразу — тогда следующие буквы шли бы
        // в старой раскладке. Проверяем и повторяем.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  Self.primaryLanguage(current) != lang.rawValue else { return }
            TISSelectInputSource(source)
        }
    }

    private func updateCurrent() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        currentIsSupported = ["ru", "en"].contains(Self.primaryLanguage(current))
    }

    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first
    }
}
