import Foundation

/// Что сделать с текстом на экране: стереть `removed` (последние символы перед курсором)
/// и набрать `insert`.
public struct TextEdit: Equatable {
    /// Что, по нашим данным, сейчас стоит перед курсором. Перед правкой сверяемся с экраном:
    /// автозамена macOS или программа могли поменять текст без нас.
    public var removed: String
    public var insert: String
    public var switchTo: Lang?

    public var deleteCount: Int { removed.count }

    /// Сколько последних символов программа могла ещё не успеть показать: текущее слово
    /// набрано только что, а уже законченные слова (до последнего разделителя) — давно.
    public var maxLag: Int {
        removed.count - ((removed.lastIndex { TypingSession.boundaries.contains($0) })
            .map { removed.distance(from: removed.startIndex, to: $0) + 1 } ?? 0)
    }

    /// Сверка с текстом перед курсором (`screen`, с запасом на `maxLag` символов слева).
    /// nil — текст поменяли без нас (автозамена macOS, подсказки программы), стирать вслепую
    /// нельзя. Если поменялся только регистр (macOS сделала первую букву заглавной), длина
    /// та же: правку применяем и переносим заглавные буквы в исправленный текст.
    public func adjusted(toScreen screen: String) -> TextEdit? {
        let expected = Array(removed)
        let shown = Array(screen)
        for lag in 0...maxLag {
            let visible = Array(expected.dropLast(lag))
            guard shown.count >= visible.count else { continue }
            let actual = Array(shown.suffix(visible.count))
            guard zip(actual, visible).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { continue }
            var edit = self
            edit.removed = String(actual + expected.suffix(lag))
            if expected.count == insert.count {
                var letters = Array(insert)
                for i in actual.indices where actual[i] != visible[i] {
                    let changed = actual[i].isUppercase ? letters[i].uppercased() : letters[i].lowercased()
                    // «ß».uppercased() — две буквы; такие оставляем как есть.
                    if changed.count == 1 { letters[i] = Character(changed) }
                }
                edit.insert = String(letters)
            }
            return edit
        }
        return nil
    }

    public init(removed: String, insert: String, switchTo: Lang? = nil) {
        self.removed = removed
        self.insert = insert
        self.switchTo = switchTo
    }
}

/// Модель того, что пользователь набрал с последнего «сброса» (клик мышью, стрелки,
/// смена приложения). Знает только хвост текста, но этого достаточно: исправляем
/// последние слова, а всё, что раньше, не трогаем.
public struct WordChange: Equatable {
    /// Ключ слова (клавиши в английской раскладке).
    public var key: String
    public var from: Lang
    public var to: Lang

    public init(key: String, from: Lang, to: Lang) {
        self.key = key
        self.from = from
        self.to = to
    }
}

public final class TypingSession {
    public struct Fix: Equatable {
        public enum Kind: Equatable { case auto, manual }
        public var kind: Kind
        public var start: Int
        public var original: String
        public var replaced: String
        /// Слова, сменившие раскладку (для обучения).
        public var changes: [WordChange]
        public var originalLang: Lang?
        /// Длина набора сразу после исправления: если пользователь продолжил печатать,
        /// отмена уже не имеет смысла.
        public var end: Int
    }

    struct Pending {
        var start: Int
        var end: Int
        var replacement: String
        var lang: Lang
        var key: String
    }

    public let detector: Detector
    public var category: AppCategory = .other
    /// Выученное правило для ключа слова в текущем приложении.
    public var learned: (String) -> Verdict? = { _ in nil }

    public private(set) var chars: [Character] = []
    public private(set) var lastFix: Fix?
    public private(set) var previousLang: Lang?
    var pending: [Pending] = []

    public static let boundaries: Set<Character> = [" ", "\n", "\t"]
    static let maxLength = 300

    public init(detector: Detector) {
        self.detector = detector
    }

    public var text: String { String(chars) }

    public func reset(keepContext: Bool = false) {
        chars.removeAll(keepingCapacity: true)
        pending.removeAll()
        lastFix = nil
        if !keepContext { previousLang = nil }
    }

    public func type(_ s: String) {
        chars.append(contentsOf: s)
        lastFix = nil
    }

    public func backspace() {
        guard !chars.isEmpty else { return }
        chars.removeLast()
        lastFix = nil
        pending.removeAll { $0.end > chars.count }
    }

    var wordStart: Int {
        (chars.lastIndex(where: { Self.boundaries.contains($0) }) ?? -1) + 1
    }

    /// Пользователь нажал пробел, Enter или Tab. Если вернулась правка — её надо
    /// применить до того, как символ-разделитель попадёт в программу.
    public func boundary(_ separator: Character) -> TextEdit? {
        defer {
            chars.append(separator)
            if separator != " " {
                // После Enter/Tab сообщение может уже уйти — старое не трогаем.
                reset(keepContext: true)
            } else if chars.count > Self.maxLength {
                reset(keepContext: true)
            }
        }

        let start = wordStart
        let token = String(chars[start...])
        guard !token.isEmpty else { return nil }

        let key = detector.key(for: token)
        let context = DetectionContext(previousLang: previousLang, category: category, learned: learned(key))
        let decision = detector.decide(token, context: context)

        var newToken: String?
        switch decision.action {
        case .pending(let replacement):
            if let lang = decision.switchTo {
                pending.append(Pending(start: start, end: chars.count, replacement: replacement, lang: lang, key: key))
            }
            return nil
        case .keep:
            break
        case .replace(let text):
            newToken = text
        }

        // Числа и знаки ничего не говорят о языке — отложенные слова ждут следующего слова.
        if decision.lang == nil, newToken == nil { return nil }
        let resolved = decision.lang.map { lang in pending.filter { $0.lang == lang } } ?? []
        pending.removeAll()
        if let lang = decision.lang { previousLang = lang }
        guard newToken != nil || !resolved.isEmpty else { return nil }

        // Собираем новый хвост: отложенные короткие слова + текущее слово.
        let from = resolved.first?.start ?? start
        var rebuilt = ""
        var i = from
        for p in resolved {
            rebuilt += String(chars[i..<p.start]) + p.replacement
            i = p.end
        }
        rebuilt += String(chars[i..<start]) + (newToken ?? token)

        let original = String(chars[from...])
        chars.replaceSubrange(from..., with: rebuilt)
        let typedLang = LayoutMap.detectLang(token)
        var changes = resolved.map { WordChange(key: $0.key, from: $0.lang.other, to: $0.lang) }
        if newToken != nil, let from = typedLang, let to = decision.lang, from != to {
            changes.append(WordChange(key: key, from: from, to: to))
        }
        lastFix = Fix(
            kind: .auto, start: from, original: original, replaced: rebuilt,
            changes: changes, originalLang: typedLang ?? resolved.first?.lang.other,
            end: chars.count + 1
        )
        let switchTo = newToken != nil ? decision.switchTo : resolved.first?.lang
        return TextEdit(removed: original, insert: rebuilt, switchTo: switchTo)
    }

    /// Отменить последнее исправление (горячая клавиша сразу после замены).
    public func undoLastFix() -> (edit: TextEdit, fix: Fix)? {
        guard let fix = lastFix, fix.end == chars.count else { return nil }
        let tail = String(chars[(fix.start + fix.replaced.count)...])
        let edit = TextEdit(
            removed: String(chars[fix.start...]),
            insert: fix.original + tail,
            switchTo: fix.originalLang
        )
        chars.replaceSubrange(fix.start..., with: fix.original + tail)
        lastFix = nil
        pending.removeAll()
        previousLang = fix.originalLang
        return (edit, fix)
    }

    /// Принудительно инвертировать последнее слово (горячая клавиша без выделения).
    public func invertLastWord() -> (edit: TextEdit, change: WordChange)? {
        var end = chars.count
        var tail = ""
        // Слово уже закончено пробелом — берём его.
        if end > 0, chars[end - 1] == " " {
            tail = " "
            end -= 1
        }
        let start = (chars[..<end].lastIndex(where: { Self.boundaries.contains($0) }) ?? -1) + 1
        guard start < end else { return nil }
        let token = String(chars[start..<end])
        guard let typed = LayoutMap.detectLang(token) else { return nil }
        let target = typed.other
        let inverted = detector.map.convert(token, to: target)

        chars.replaceSubrange(start..., with: inverted + tail)
        pending.removeAll()
        previousLang = target
        let change = WordChange(key: detector.key(for: token), from: typed, to: target)
        lastFix = Fix(
            kind: .manual, start: start, original: token, replaced: inverted, changes: [change],
            originalLang: typed, end: chars.count
        )
        return (TextEdit(removed: token + tail, insert: inverted + tail, switchTo: target), change)
    }
}
