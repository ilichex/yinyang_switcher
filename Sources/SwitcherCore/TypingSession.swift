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
            guard zip(actual, visible).allSatisfy({ Self.sameOnScreen($0, $1) }) else { continue }
            var edit = self
            edit.removed = String(actual + expected.suffix(lag))
            if expected.count == insert.count {
                var letters = Array(insert)
                for i in actual.indices where actual[i] != visible[i] && actual[i].isLetter {
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

    /// Один и тот же символ с поправкой на то, что программа могла с ним сделать:
    /// поменять регистр или заменить кавычку на типографскую (`"` → `«`, `'` → `’`).
    static func sameOnScreen(_ a: Character, _ b: Character) -> Bool {
        a.lowercased() == b.lowercased() || (quoteFamily(a) != nil && quoteFamily(a) == quoteFamily(b))
    }

    private static func quoteFamily(_ c: Character) -> Int? {
        if "\"«»“”„".contains(c) { return 2 }
        if "'‘’‚".contains(c) { return 1 }
        return nil
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

    /// Как курсор оказался там, где начался набор, если мы этого не видели.
    enum Jump { case click, keys }

    public let detector: Detector
    public var category: AppCategory = .other
    /// Выученное правило для ключа слова в текущем приложении.
    public var learned: (String) -> Verdict? = { _ in nil }
    /// Стоит ли на экране буква вплотную перед этим словом. nil — программа не отвечает.
    public var letterBefore: (String) -> Bool? = { _ in nil }
    /// Набор начался после того, как мы потеряли курсор: первое слово может быть хвостом
    /// другого слова, и исправлять его отдельно нельзя.
    var jump: Jump?

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
        jump = nil
        if !keepContext { previousLang = nil }
    }

    /// Клик мышью: обычно попадают в конец текста, поэтому без явной буквы перед словом
    /// исправляем как обычно.
    public func clicked() {
        reset(keepContext: true)
        jump = .click
    }

    /// Стрелки и похожие клавиши: курсор мог встать посреди слова.
    public func cursorMoved() {
        reset(keepContext: true)
        jump = .keys
    }

    /// ⌘- и ⌃-сочетания, Esc: курсор на месте, но начало текущего слова мы забываем.
    public func interrupted() {
        let midWord = chars.last.map { !Self.boundaries.contains($0) } ?? false
        reset(keepContext: true)
        if midWord { jump = .keys }
    }

    public func type(_ s: String) {
        if chars.isEmpty, let first = s.unicodeScalars.first,
           [.nonspacingMark, .spacingMark, .enclosingMark, .format].contains(first.properties.generalCategory) {
            // Этот знак может присоединиться к символу, которого нет в нашей памяти.
            cursorMoved()
            return
        }
        // Отдельное нажатие может дописать акцент или часть emoji к предыдущему символу.
        chars = Array(String(chars) + s)
        lastFix = nil
    }

    public func backspace() {
        // Стирают то, чего мы не видели: следующие буквы могут дописывать чужое слово.
        guard !chars.isEmpty else { return cursorMoved() }
        chars.removeLast()
        lastFix = nil
        // Стирание разделителя снова делает отложенное слово текущим.
        pending.removeAll { $0.end >= chars.count }
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
        // Отложенное слово должно целиком предшествовать текущему, даже после составного ввода.
        pending.removeAll { $0.end > start }
        let isTail = continuesHiddenWord(token, start: start)
        jump = nil
        if isTail {
            pending.removeAll()
            return nil
        }
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

    /// Первое слово после потери курсора — хвост чужого слова? Экран знает точно; если он
    /// молчит, после клика считаем слово целым, а после стрелок лучше ничего не трогать.
    private func continuesHiddenWord(_ token: String, start: Int) -> Bool {
        guard start == 0, let jump else { return false }
        return letterBefore(token) ?? (jump == .keys)
    }

    /// Стоит ли в `screen` (текст перед курсором) буква или цифра вплотную перед `token`.
    /// nil — на экране ещё нет этого слова, судить не по чему.
    public static func letterBefore(_ token: String, inScreen screen: String) -> Bool? {
        let word = Array(token), shown = Array(screen)
        guard shown.count >= word.count,
              zip(shown.suffix(word.count), word).allSatisfy({ TextEdit.sameOnScreen($0, $1) }) else { return nil }
        guard let before = shown.dropLast(word.count).last else { return false }
        return before.isLetter || before.isNumber
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
    public func sync(withScreen line: String, allowIncompleteWord: Bool = false) {
        let line = String(line.split(separator: "\n", omittingEmptySubsequences: false).last ?? "").suffix(Self.maxLength)
        let shown = Array(line)
        if !chars.isEmpty, shown.count >= chars.count,
           zip(shown.suffix(chars.count), chars).allSatisfy({ TextEdit.sameOnScreen($0, $1) }) { return }
        // Accessibility иногда ещё не видит последние нажатия. Не укорачиваем слово:
        // иначе из шести букв сотрём пять и оставим лишнюю первую букву.
        if allowIncompleteWord, !chars.isEmpty, !Self.boundaries.contains(chars.last!) {
            let start = wordStart
            for missing in 1...(chars.count - start) {
                let visible = chars.dropLast(missing)
                guard shown.count >= visible.count else { continue }
                if zip(shown.suffix(visible.count), visible).allSatisfy({ TextEdit.sameOnScreen($0, $1) }) {
                    // Пустой префикс допустим только на пустом экране.
                    if !visible.isEmpty || shown.isEmpty { return }
                }
            }
        }
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
    public func invertLastWord(sourceLang: Lang? = nil) -> (edit: TextEdit, change: WordChange)? {
        var end = chars.count
        // Пробелы после слова (один, два — неважно) остаются как есть.
        while end > 0, chars[end - 1] == " " { end -= 1 }
        let tail = String(chars[end...])
        let start = (chars[..<end].lastIndex(where: { Self.boundaries.contains($0) }) ?? -1) + 1
        guard start < end else { return nil }
        let token = String(chars[start..<end])
        guard let (inverted, target) = invert(token, sourceLang: sourceLang), inverted != token else { return nil }

        chars.replaceSubrange(start..., with: inverted + tail)
        pending.removeAll()
        previousLang = target
        manualEnd = chars.count
        let change = WordChange(key: detector.key(for: token), from: target.other, to: target)
        // Хвост чужого слова словом не считаем: меняем по просьбе, но запоминать нечего.
        let teaches = LayoutMap.detectLang(token) != nil && !(start == 0 && jump == .keys)
        lastWordTeaches = teaches
        lastFix = Fix(
            kind: .manual, start: start, original: token, replaced: inverted, changes: teaches ? [change] : [],
            originalLang: LayoutMap.detectLang(token) ?? target.other, end: chars.count, replacedLang: target
        )
        return (TextEdit(removed: token + tail, insert: inverted + tail, switchTo: target), change)
    }

    /// Можно ли учиться на последнем `invertLastWord`.
    public private(set) var lastWordTeaches = true

    /// Слово в другой раскладке и её язык. Смешанное («приdtn» — раскладка не успела
    /// переключиться) целиком приводим к одной: где получается слово, иначе — к той,
    /// которой слово начинается. Знак в конце оставляем знаком, если без него слово
    /// настоящее, а с ним — нет: «ghbdtn.» → «привет.», «привет.» → «ghbdtn.»,
    /// но «k.,k.» → «люблю».
    func invert(_ token: String, sourceLang: Lang? = nil) -> (String, Lang)? {
        let envelope = TokenEnvelope(token)
        if !envelope.prefix.isEmpty, let (text, lang) = invert(envelope.body, sourceLang: sourceLang) {
            return (envelope.wrap(text), lang)
        }
        let target: Lang
        if let typed = LayoutMap.detectLang(token) {
            target = typed.other
        } else {
            let letters = token.unicodeScalars.compactMap { LayoutMap.detectLang(String($0)) }
            if letters.isEmpty, let sourceLang {
                return detector.map.invertSymbols(token, from: sourceLang).map { ($0, sourceLang.other) }
            }
            // «99:» — это «99%», набранное в русской раскладке (Shift+5 даёт там двоеточие).
            if letters.isEmpty, token.count > 1, token.last == ":", token.dropLast().allSatisfy(\.isNumber) {
                return (token.dropLast() + "%", .en)
            }
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
