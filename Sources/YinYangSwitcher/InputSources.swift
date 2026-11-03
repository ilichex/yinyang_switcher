import Carbon
import SwitcherCore

/// Русская и английская раскладки, включённые в системе.
final class InputSources {
    private(set) var ru: TISInputSource?
    private(set) var en: TISInputSource?
    private(set) var map: LayoutMap = .macRussian

    init() {
        reload()
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
    }

    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first
    }
}
