import Foundation

public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case code, chat, docs, browser, other

    public var title: String {
        switch self {
        case .code: "Код и терминал"
        case .chat: "Переписка"
        case .docs: "Документы"
        case .browser: "Браузер"
        case .other: "Другое"
        }
    }
}

/// Выученное правило для слова: в какой раскладке его оставлять.
public enum Verdict: Equatable, Sendable {
    case lang(Lang)
    /// Пользователь то меняет, то возвращает — сами не трогаем, только по горячей клавише.
    case unstable
}

public struct DetectionContext {
    /// Язык предыдущего слова в текущем наборе — главный подсказчик.
    public var previousLang: Lang?
    public var category: AppCategory
    public var learned: Verdict?

    public init(previousLang: Lang? = nil, category: AppCategory = .other, learned: Verdict? = nil) {
        self.previousLang = previousLang
        self.category = category
        self.learned = learned
    }
}

public struct Decision: Equatable {
    public enum Action: Equatable {
        case keep
        /// Заменить слово на `text`.
        case replace(String)
        /// Короткое слово: решим после следующего слова. `text` — вариант на случай замены.
        case pending(String)
    }

    public var action: Action
    /// Язык слова после решения — становится контекстом для следующего. nil — непонятно.
    public var lang: Lang?
    /// Раскладка, на которую надо переключиться после замены.
    public var switchTo: Lang?

    static func keep(_ lang: Lang?) -> Decision { Decision(action: .keep, lang: lang, switchTo: nil) }
}

public struct Detector {
    public let map: LayoutMap
    public let scorer: Scorer

    public init(map: LayoutMap, scorer: Scorer) {
        self.map = map
        self.scorer = scorer
    }

    /// Ключ слова, не зависящий от раскладки: те же клавиши в английской раскладке.
    /// По нему хранятся выученные правила.
    public func key(for token: String) -> String {
        map.convert(token, to: .en).lowercased()
    }

    public func decide(_ token: String, context: DetectionContext) -> Decision {
        guard let typed = LayoutMap.detectLang(token), !Self.looksLikeCode(token) else { return .keep(nil) }
        let other = typed.other
        let inverted = map.convert(token, to: other)

        let keepScore = scorer.score(Self.core(token), typed)
        let invertedScore = scorer.score(Self.core(inverted), other)

        switch context.learned {
        case .unstable?: return .keep(typed)
        case .lang(let lang)? where lang == typed: return .keep(typed)
        // Обучение подсказывает, как быть с непонятным словом, но не портит настоящее:
        // «это» не станет «'nj», сколько бы голосов ни набрал этот набор клавиш.
        case .lang? where keepScore > invertedScore: return .keep(typed)
        case .lang?:
            // Знак на конце остаётся знаком: выученное «ntcn,» — это «тест,», а не «тестб».
            if invertedScore == 0, let mark = punctuationCandidate(token, typed: typed), mark.lang == other {
                return Decision(action: .replace(mark.text), lang: other, switchTo: other)
            }
            return Decision(action: .replace(inverted), lang: other, switchTo: other)
        case nil: break
        }

        // Частое слово в своей раскладке не трогаем никогда («ой» не станет «jq»).
        if keepScore >= Scorer.commonWord { return .keep(typed) }

        var best: (text: String, lang: Lang, switchTo: Lang?, full: Bool)?

        if invertedScore >= Scorer.knownWord,
           invertedScore > keepScore || (invertedScore == keepScore && context.previousLang == other) {
            best = (inverted, other, other, true)
        }

        // Ни так, ни так не слово — может, последние клавиши были знаками препинания.
        if best == nil, keepScore == 0 {
            best = punctuationCandidate(token, typed: typed)
        }

        guard let choice = best else { return .keep(keepScore >= Scorer.knownWord ? typed : nil) }

        if choice.full, context.previousLang != choice.lang {
            let letters = token.filter(\.isLetter).count
            let short = letters == 1 || (context.category == .code && choice.lang == .ru && letters <= 3)
            if short {
                // «b» — это «и»? По одной букве не понять: ждём следующее слово.
                if context.previousLang == typed { return .keep(typed) }
                return Decision(action: .pending(choice.text), lang: nil, switchTo: choice.switchTo)
            }
        }
        return Decision(action: .replace(choice.text), lang: choice.lang, switchTo: choice.switchTo)
    }

    /// «тестж» → «тест;», «ghbdtn,» → «привет,». Полное слово всегда важнее:
    /// «муж» и «их» сюда не попадут, потому что они уже слова.
    private func punctuationCandidate(_ token: String, typed: Lang) -> (text: String, lang: Lang, switchTo: Lang?, full: Bool)? {
        let other = typed.other
        for k in 1...2 where token.count > k + 1 {
            let head = String(token.dropLast(k))
            let tail = String(token.suffix(k))
            let tailOther = map.convert(tail, to: other)

            // Набрано в нужной раскладке, но знак нажат без переключения: «тестж» → «тест;».
            if tail.allSatisfy(\.isLetter), tailOther.allSatisfy(Self.isPunctuation),
               scorer.score(Self.core(head), typed) >= Scorer.knownWord {
                return (head + tailOther, typed, nil, false)
            }
            // Слово в чужой раскладке, а в конце — знак: «ghbdtn,» → «привет,».
            if tail.allSatisfy(Self.isPunctuation), tailOther.allSatisfy(\.isLetter) {
                let headInverted = map.convert(head, to: other)
                if scorer.score(Self.core(headInverted), other) >= Scorer.knownWord {
                    return (headInverted + tail, other, other, false)
                }
            }
        }
        return nil
    }

    /// Слово без кавычек, скобок и знаков по краям.
    static func core(_ s: String) -> String {
        guard let first = s.firstIndex(where: \.isLetter),
              let last = s.lastIndex(where: \.isLetter) else { return "" }
        return String(s[first...last])
    }

    static func isPunctuation(_ c: Character) -> Bool {
        !c.isLetter && !c.isNumber && !c.isWhitespace
    }

    /// Пути, адреса, почта, флаги, camelCase и snake_case не трогаем.
    /// `{ } < > | . ;` сюда не входят: в английской раскладке это русские Х Ъ Б Ю Ё ю ж.
    static func looksLikeCode(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber || "_/@=$".contains($0) }) { return true }
        if token.hasPrefix("-") { return true }
        var previousLower = false
        for c in token {
            if c.isUppercase, previousLower { return true }
            previousLower = c.isLowercase
        }
        return false
    }
}
