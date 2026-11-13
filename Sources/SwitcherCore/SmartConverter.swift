import Foundation

/// Умная инверсия выделенного текста: понятные слова остаются как есть,
/// меняются только те, что в другой раскладке становятся словами.
/// Если менять нечего — значит, пользователь хочет инвертировать всё целиком.
/// `typed` — то же для уже набранной фразы: настоящие слова не трогаем, а если менять
/// нечего — ничего не делаем (тогда меняется раскладка последнего слова).
public struct SmartConverter {
    public struct Result: Equatable {
        public var text: String
        public var changes: [WordChange]
        /// На какую раскладку переключиться после замены.
        public var lang: Lang?

        /// Чему это учит. Замена целого текста — не мнение о каждом его слове: иначе
        /// одно нажатие на выделенном абзаце записало бы «и», «в», «это» в английские.
        public var votes: [WordChange] {
            text.contains(where: \.isWhitespace) ? [] : changes
        }
    }

    let detector: Detector

    public init(detector: Detector) {
        self.detector = detector
    }

    public func convert(
        _ text: String,
        category: AppCategory = .other,
        learned: (String) -> Verdict? = { _ in nil },
        typed: Bool = false,
        sourceLang: Lang? = nil
    ) -> Result? {
        let tokens = Self.split(text)
        var output = tokens.map(\.text)
        var langs: [Lang?] = Array(repeating: nil, count: tokens.count)
        var pending: [(index: Int, text: String, lang: Lang)] = []
        var changes: [WordChange] = []
        var previous: Lang?

        for (i, token) in tokens.enumerated() where !token.isSeparator {
            // Уже набранный текст: настоящие слова остаются как есть, даже если обучение
            // подсказывает другое, — их только что видели на экране и не исправили.
            let letters = token.text.trimmingCharacters(in: .punctuationCharacters)
            if typed, let lang = LayoutMap.detectLang(letters), detector.scorer.score(letters, lang) > 0 {
                langs[i] = lang
                previous = lang
                continue
            }
            let key = detector.key(for: token.text)
            let context = DetectionContext(previousLang: previous, category: category, learned: learned(key))
            let decision = detector.decide(token.text, context: context)
            switch decision.action {
            case .keep:
                langs[i] = decision.lang
            case .replace(let new):
                output[i] = new
                langs[i] = decision.lang
                if let from = LayoutMap.detectLang(token.text), let to = decision.lang, from != to {
                    changes.append(WordChange(key: key, from: from, to: to))
                }
            case .pending(let new):
                if let lang = decision.switchTo { pending.append((i, new, lang)) }
            }
            if let lang = langs[i] { previous = lang }
        }

        // Короткие слова решаем по соседям: сначала следующее слово, потом предыдущее.
        for p in pending {
            let neighbour = langs[(p.index + 1)...].compactMap { $0 }.first
                ?? langs[..<p.index].compactMap { $0 }.last
            if neighbour == p.lang {
                output[p.index] = p.text
                langs[p.index] = p.lang
                if let from = LayoutMap.detectLang(tokens[p.index].text) {
                    changes.append(WordChange(key: detector.key(for: tokens[p.index].text), from: from, to: p.lang))
                }
            }
        }

        if changes.isEmpty {
            if !typed, let sourceLang, !text.contains(where: \.isLetter) {
                let symbols = tokens.map { token in
                    token.isSeparator ? token.text : detector.map.invertSymbols(token.text, from: sourceLang) ?? token.text
                }.joined()
                if symbols != text { return Result(text: symbols, changes: [], lang: sourceLang.other) }
            }
            // Умно менять нечего — инвертируем всё (для выделенного) или ничего (для набранного).
            guard !typed, let lang = LayoutMap.detectLang(text) ?? tokens.lazy.compactMap({ LayoutMap.detectLang($0.text) }).first else {
                return nil
            }
            var all: [WordChange] = []
            let converted = tokens.map { token -> String in
                guard !token.isSeparator, let from = LayoutMap.detectLang(token.text) else { return token.text }
                all.append(WordChange(key: detector.key(for: token.text), from: from, to: from.other))
                return detector.map.convertWord(token.text, to: from.other)
            }.joined()
            return Result(text: converted, changes: all, lang: lang.other)
        }

        let lastLang = langs.compactMap { $0 }.last
        return Result(text: output.joined(), changes: changes, lang: lastLang)
    }

    struct Token {
        var text: String
        var isSeparator: Bool
    }

    static func split(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for c in text {
            let separator = c.isWhitespace
            if let last = tokens.last, last.isSeparator == separator {
                tokens[tokens.count - 1].text.append(c)
            } else {
                tokens.append(Token(text: String(c), isSeparator: separator))
            }
        }
        return tokens
    }
}
