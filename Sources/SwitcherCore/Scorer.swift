import AppKit

public protocol SpellChecking {
    func isValid(_ word: String, lang: Lang) -> Bool
}

/// Встроенная в macOS проверка орфографии: словари ru и en уже есть в системе,
/// своих словарей на мегабайты не нужно. Ответ ~0.1 мс, результаты кэшируются.
public final class SystemSpellChecker: SpellChecking {
    private var cache: [String: Bool] = [:]
    // NSSpellChecker не потокобезопасен.
    private let lock = NSLock()

    public init() {}

    public func isValid(_ word: String, lang: Lang) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = lang.rawValue + ":" + word
        if let hit = cache[key] { return hit }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: lang.rawValue, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        let ok = range.location == NSNotFound
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = ok
        return ok
    }
}

/// Насколько уверенно строка — слово данного языка.
/// 3 — словарь кода, 2 — частое слово, 1 — есть в системном словаре, 0 — не слово.
public struct Scorer {
    public static let codeWord = 3.0
    public static let commonWord = 2.0
    public static let knownWord = 1.0

    let spell: SpellChecking

    public init(spell: SpellChecking) {
        self.spell = spell
    }

    public func score(_ word: String, _ lang: Lang) -> Double {
        let w = word.lowercased()
        guard !w.isEmpty, LayoutMap.detectLang(w) == lang else { return 0 }
        if lang == .en, Lexicon.code.contains(w) { return Self.codeWord }
        if Lexicon.common(lang).contains(w) { return Self.commonWord }
        // Короткие слова системный словарь принимает почти любые («b», «vs»), поэтому
        // 1–2 буквы считаются словом только из списка частых.
        if w.count <= 2 { return 0 }
        return spell.isValid(w, lang: lang) ? Self.knownWord : 0
    }
}
