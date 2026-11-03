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
        public var replacedLang: Lang? = nil
        /// Это уже переключение туда-обратно, а не первая отмена: за него не голосуем.
        public var isRepeat = false

        /// Тот же кусок наоборот: следующее нажатие вернёт его.
        func flipped(end: Int) -> Fix {
            Fix(kind: kind, start: start, original: replaced, replaced: original,
                changes: changes.map { WordChange(key: $0.key, from: $0.to, to: $0.from) },
                originalLang: replacedLang, end: end, replacedLang: originalLang, isRepeat: true)
        }
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
    /// Конец текста, который пользователь только что выбрал вручную. Слово, задевающее его,
    /// автозамена на ближайшем пробеле не трогает: ручной выбор важнее догадки.
    var manualEnd: Int?

    public static let boundaries: Set<Character> = [" ", "\n", "\t"]
    public static let maxLength = 300

    public init(detector: Detector) {
        self.detector = detector
    }

    public var text: String { String(chars) }

    public func reset(keepContext: Bool = false) {
        chars.removeAll(keepingCapacity: true)
        pending.removeAll()
        lastFix = nil
        manualEnd = nil
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
        manualEnd = manualEnd.map { min($0, chars.count) }
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
        if let manualEnd, manualEnd > start {
            // Слово выбрано вручную (может, дописано) — оставляем как есть.
            pending.removeAll()
            if let lang = LayoutMap.detectLang(token) { previousLang = lang }
            return nil
        }

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
            end: chars.count + 1, replacedLang: decision.lang ?? resolved.first?.lang
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
        // Не забываем: следующее нажатие вернёт исправление обратно — и так сколько угодно.
        lastFix = fix.flipped(end: chars.count)
        manualEnd = chars.count
        pending.removeAll()
        previousLang = fix.originalLang
        return (edit, fix)
    }

    /// Пользователь заменил выделенный текст. Запоминаем, чтобы следующее нажатие вернуло
    /// его обратно без повторного выделения. Огромные куски не запоминаем.
    public func replacedSelection(_ original: String, with replaced: String, changes: [WordChange], lang: Lang?) {
        reset(keepContext: true)
        guard replaced.count <= Self.maxSelection else { return }
        chars = Array(replaced)
        if let lang { previousLang = lang }
        lastFix = Fix(kind: .manual, start: 0, original: original, replaced: replaced, changes: changes,
                      originalLang: Self.lastLang(original), end: chars.count, replacedLang: lang)
        manualEnd = chars.count
    }

    /// Сверить память с текстом перед курсором (строка до курсора, как её видит программа).
    /// Совпадает — оставляем: там больше сведений. Нет (кликнули в другое место, macOS что-то
    /// заменила) — верим экрану: так последнее слово можно поменять в любой момент.
    public func sync(withScreen line: String) {
        let line = String(line.split(separator: "\n", omittingEmptySubsequences: false).last ?? "").suffix(Self.maxLength)
        if !chars.isEmpty, line.lowercased().hasSuffix(text.lowercased()) { return }
        reset(keepContext: true)
        chars = Array(line)
    }

    static let maxSelection = 1000

    /// Исправить всё, что набрано с последнего клика или Enter: меняются только слова,
    /// похожие на набранные не в той раскладке, понятные остаются. nil — таких слов нет.
    public func convertPhrase(_ smart: SmartConverter) -> (edit: TextEdit, changes: [WordChange])? {
        let text = String(chars)
        guard let result = smart.convert(text, category: category, learned: learned, typed: true),
              result.text != text else { return nil }
        let converted = Array(result.text)
        // Стираем только с первого изменившегося символа.
        var start = 0
        while start < min(chars.count, converted.count), chars[start] == converted[start] { start += 1 }
        let original = String(chars[start...])
        let replaced = String(converted[start...])
        chars = converted
        pending.removeAll()
        if let lang = result.lang { previousLang = lang }
        lastFix = Fix(kind: .manual, start: start, original: original, replaced: replaced, changes: result.changes,
                      originalLang: Self.lastLang(text), end: chars.count, replacedLang: result.lang)
        manualEnd = chars.count
        return (TextEdit(removed: original, insert: replaced, switchTo: result.lang), result.changes)
    }

    /// Язык последнего слова с буквами.
    static func lastLang(_ text: String) -> Lang? {
        text.split(whereSeparator: \.isWhitespace).reversed().lazy.compactMap { LayoutMap.detectLang(String($0)) }.first
    }

    /// Принудительно поменять раскладку последнего слова (клавиша без выделения).
    /// Слово может быть недописанным, с пробелами после него или из букв обеих раскладок.
    public func invertLastWord() -> (edit: TextEdit, change: WordChange)? {
        var end = chars.count
        // Пробелы после слова (один, два — неважно) остаются как есть.
        while end > 0, chars[end - 1] == " " { end -= 1 }
        let tail = String(chars[end...])
        let start = (chars[..<end].lastIndex(where: { Self.boundaries.contains($0) }) ?? -1) + 1
        guard start < end else { return nil }
        let token = String(chars[start..<end])
        guard let (inverted, target) = invert(token) else { return nil }

        chars.replaceSubrange(start..., with: inverted + tail)
        pending.removeAll()
        previousLang = target
        manualEnd = chars.count
        let change = WordChange(key: detector.key(for: token), from: target.other, to: target)
        lastFix = Fix(
            kind: .manual, start: start, original: token, replaced: inverted, changes: [change],
            originalLang: LayoutMap.detectLang(token) ?? target.other, end: chars.count, replacedLang: target
        )
        return (TextEdit(removed: token + tail, insert: inverted + tail, switchTo: target), change)
    }

    /// Слово в другой раскладке и её язык. Смешанное («приdtn» — раскладка не успела
    /// переключиться) целиком приводим к одной: где получается слово, иначе — к той,
    /// которой слово начинается. Знак в конце оставляем знаком, если без него слово
    /// настоящее, а с ним — нет: «ghbdtn.» → «привет.», «привет.» → «ghbdtn.»,
    /// но «k.,k.» → «люблю».
    func invert(_ token: String) -> (String, Lang)? {
        let target: Lang
        if let typed = LayoutMap.detectLang(token) {
            target = typed.other
        } else {
            let letters = token.unicodeScalars.compactMap { LayoutMap.detectLang(String($0)) }
            guard let first = letters.first else { return nil }
            if isWord(detector.map.convert(token, to: .ru), .ru) { target = .ru }
            else if isWord(detector.map.convert(token, to: .en), .en) { target = .en }
            else { target = first }
        }
        let full = detector.map.convert(token, to: target)
        let marks = token.reversed().prefix { ".,!?:;".contains($0) }.count
        if marks > 0, marks < token.count, !isWord(full, target) {
            let core = String(token.dropLast(marks))
            let kept = detector.map.convert(core, to: target)
            let source = LayoutMap.detectLang(token)
            if isWord(kept, target) || source.map({ isWord(core, $0) }) == true {
                return (kept + token.suffix(marks), target)
            }
        }
        return (full, target)
    }

    private func isWord(_ text: String, _ lang: Lang) -> Bool {
        detector.scorer.score(text.trimmingCharacters(in: .punctuationCharacters), lang) > 0
    }
}
