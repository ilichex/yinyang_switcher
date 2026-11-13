import Testing
import SwitcherCore

/// Большие сценарии: правильный текст → как его набрали бы не в той раскладке → что
/// окажется на экране. Набор строится из правильного текста, чтобы не ошибиться в раскладке.
@Suite struct Scenarios {
    /// Набрано в английской раскладке, а хотели по-русски.
    static let russian = [
        "привет как дела", "я не знаю что сказать", "сегодня хорошая погода",
        "давай встретимся завтра", "это очень важно", "спасибо большое",
        "у меня всё хорошо", "мы будем выкладывать приложение для людей",
        "в городе идёт дождь", "с днём рождения", "Привет Мир", "кто-то звонил",
        "я написал тебе письмо", "а ты где", "ну и что", "к сожалению нет",
    ]

    /// Набрано в русской раскладке, а хотели по-английски.
    static let english = [
        "hello world", "how are you", "this is a test", "please send me the file",
        "the quick brown fox jumps over the lazy dog", "I will be there tomorrow",
        "thank you very much", "see you later", "don't worry", "it's fine",
    ]

    @Test(arguments: russian) func russianTypedInEnglishLayout(_ text: String) {
        let typed = map.convert(text, to: .en)
        #expect(typeText(typed + " ") == text + " ", "\(typed)")
    }

    @Test(arguments: english) func englishTypedInRussianLayout(_ text: String) {
        let typed = map.convert(text, to: .ru)
        #expect(typeText(typed + " ") == text + " ", "\(typed)")
    }

    @Test(arguments: russian + english) func correctTextIsLeftAlone(_ text: String) {
        #expect(typeText(text + " ") == text + " ")
    }

    @Test(arguments: [
        "user@mail.ru", "https://github.com/ilichex", "~/Desktop/git", "--force", "-m",
        "snake_case", "camelCase", "iPhone", "x86_64", "v0.2.0", "2024", "10:30", "C++", "#tag",
        "ok", "in", "on", "it", "шт", "кг", "ой", "муж", "их", "Москва", "Nikita",
    ]) func neverTouched(_ token: String) {
        #expect(typeText(token + " ") == token + " ")
    }

    @Test func punctuationTypedWithoutSwitching() {
        #expect(typeText(map.convert("привет, как дела?", to: .en) + " ") == "привет, как дела? ")
        #expect(typeText(map.convert("hello, world!", to: .ru) + " ") == "hello, world! ")
    }

    @Test func terminal() {
        #expect(typeText(map.convert("git status", to: .ru) + " ", category: .code) == "git status ")
        #expect(typeText(map.convert("cd ~/Desktop", to: .ru) + " ", category: .code).hasPrefix("cd "))
        #expect(typeText("a = b + c ", category: .code) == "a = b + c ")
    }

    @Test func numbersAndWords() {
        #expect(typeText(map.convert("2 раза", to: .en) + " ") == "2 раза ")
        #expect(typeText(map.convert("в 10 часов", to: .en) + " ") == "в 10 часов ")
    }
}

@Suite struct EdgeCases {
    @Test func capsAndMixedCase() {
        #expect(typeText(map.convert("ПРИВЕТ", to: .en) + " ") == "ПРИВЕТ ")
        #expect(typeText(map.convert("Hello", to: .ru) + " ") == "Hello ")
    }

    @Test func backspaceInsideWord() {
        let session = TypingSession(detector: detector)
        for c in "ghbdtnn" { session.type(String(c)) }
        session.backspace()
        #expect(session.boundary(" ")?.insert == "привет")
    }

    @Test func mixedScriptsAndEmoji() {
        for token in ["приvet", "привет👋", "👍", "—", "«цитата»", "..."] {
            #expect(typeText(token + " ") == token + " ", "\(token)")
        }
    }

    @Test func veryLongTextDoesNotBreak() {
        let long = String(repeating: "ghbdtn ", count: 80)
        #expect(typeText(long) == String(repeating: "привет ", count: 80))
    }

    @Test func gibberishStaysInBothLayouts() {
        for token in ["asdfgh", "фывапр", "qwerty123", "zzzz"] {
            #expect(typeText(token + " ") == token + " ", "\(token)")
        }
    }
}

/// Автозамена macOS или программа поменяли текст без нас — правку не применяем.
@Suite struct ScreenCheck {
    @Test func currentWordMayLag() {
        let edit = TextEdit(removed: "z ns", insert: "я ты")
        #expect(edit.maxLag == 2)
        #expect(edit.adjusted(toScreen: "ok z ns") == edit)
        #expect(edit.adjusted(toScreen: "ok z n") == edit) // программа ещё не показала последнюю букву
        #expect(edit.adjusted(toScreen: "ok z ") == edit)
    }

    @Test func changedEarlierWordIsCaught() {
        let edit = TextEdit(removed: "z ns", insert: "я ты")
        #expect(edit.adjusted(toScreen: "ok z. ns") == nil)
        #expect(edit.adjusted(toScreen: "ok x ns") == nil)
        #expect(edit.adjusted(toScreen: "ok ") == nil)
    }

    @Test func autoCapitalizationIsCarriedOver() {
        let edit = TextEdit(removed: "z gjikf", insert: "я пошла")
        #expect(edit.adjusted(toScreen: "Z gjikf") == TextEdit(removed: "Z gjikf", insert: "Я пошла"))
        #expect(edit.adjusted(toScreen: "Z gji") == TextEdit(removed: "Z gjikf", insert: "Я пошла"))
    }

    @Test func singleWordIsNotChecked() {
        #expect(TextEdit(removed: "ghbdtn", insert: "привет").maxLag == 6)
    }

    @Test func finishedWordMustMatch() {
        let edit = TextEdit(removed: "dont ", insert: "вщте ")
        #expect(edit.maxLag == 0)
        #expect(edit.adjusted(toScreen: "dont ") == edit)
        #expect(edit.adjusted(toScreen: "Dont ") == TextEdit(removed: "Dont ", insert: "Вщте "))
        #expect(edit.adjusted(toScreen: "don't ") == nil)
        #expect(edit.adjusted(toScreen: "dont") == nil)
    }
}

/// Сочетание «включить/выключить»: по умолчанию ⌥⌘ — нажать вместе и отпустить.
@Suite struct ToggleChord {
    let opt = Shortcut.option, cmd = Shortcut.command

    @Test func optionCommandToggles() {
        var chord = ChordDetector(target: opt | cmd)
        let r1 = chord.flags(opt, at: 0)
        #expect(!r1)
        let r2 = chord.flags(opt | cmd, at: 0.05)
        #expect(!r2)
        let optionReleased = chord.flags(cmd, at: 0.15) // ⌥ отпустили первым
        #expect(!optionReleased)
        let fired = chord.flags(0, at: 0.2)
        #expect(fired)
    }

    @Test func shortcutWithKeyDoesNotToggle() {
        var chord = ChordDetector(target: opt | cmd)
        _ = chord.flags(opt | cmd, at: 0)
        chord.interrupt() // ⌥⌘Esc, ⌥⌘D…
        let fired = chord.flags(0, at: 0.2)
        #expect(!fired)
        // Следующее чистое нажатие снова работает.
        _ = chord.flags(opt | cmd, at: 1)
        let again = chord.flags(0, at: 1.1)
        #expect(again)
    }

    @Test func extraModifierOrLongHoldDoesNotToggle() {
        var chord = ChordDetector(target: opt | cmd)
        _ = chord.flags(opt | cmd | Shortcut.shift, at: 0)
        let withShift = chord.flags(0, at: 0.1)
        #expect(!withShift)
        _ = chord.flags(opt | cmd, at: 1)
        let held = chord.flags(0, at: 3)
        #expect(!held)
        _ = chord.flags(opt, at: 4)
        let onlyOption = chord.flags(0, at: 4.1)
        #expect(!onlyOption)
    }

    @Test func interruptWithNothingHeldIsHarmless() {
        var chord = ChordDetector(target: opt | cmd)
        chord.interrupt() // обычный набор текста
        _ = chord.flags(opt | cmd, at: 0)
        let fired = chord.flags(0, at: 0.1)
        #expect(fired)
    }

    @Test func recorderCapturesChordAndKey() {
        var recorder = ShortcutRecorder()
        let r3 = recorder.flags(opt)
        #expect(r3 == nil)
        let r4 = recorder.flags(opt | cmd)
        #expect(r4 == nil)
        let r5 = recorder.flags(cmd)
        #expect(r5 == nil)
        let r6 = recorder.flags(0)
        #expect(r6 == Shortcut(modifiers: opt | cmd))
        // Один модификатор — не сочетание.
        _ = recorder.flags(opt)
        let r7 = recorder.flags(0)
        #expect(r7 == nil)
        let r8 = recorder.key(16, modifiers: Shortcut.control | opt)
        #expect(r8 == Shortcut(modifiers: Shortcut.control | opt, keyCode: 16))
        #expect(Shortcut(modifiers: Shortcut.control | opt | cmd).modifierSymbols == "⌃⌥⌘")
    }
}

/// Клавиша исправления сколько угодно раз переключает последнюю замену туда-обратно.
@Suite struct Toggling {
    /// Экран: применяет правку и проверяет, что стирается ровно то, что видно.
    struct Screen {
        var text = ""
        mutating func apply(_ edit: TextEdit) {
            #expect(text.hasSuffix(edit.removed))
            text.removeLast(edit.deleteCount)
            text += edit.insert
        }
    }

    @Test func manualWordFlipsForever() {
        let session = TypingSession(detector: detector)
        var screen = Screen(text: "ghbdtn")
        session.type("ghbdtn")
        if let r = session.invertLastWord() { screen.apply(r.edit) }
        #expect(screen.text == "привет")
        var seen: [String] = []
        for _ in 0..<4 {
            guard let r = session.undoLastFix() else { break }
            screen.apply(r.edit)
            seen.append(screen.text)
        }
        #expect(seen == ["ghbdtn", "привет", "ghbdtn", "привет"])
        #expect(session.text == "привет")
    }

    @Test func autoFixFlipsForever() {
        let session = TypingSession(detector: detector)
        var screen = Screen()
        for c in "ghbdtn" { session.type(String(c)); screen.text.append(c) }
        if let edit = session.boundary(" ") { screen.apply(edit) }
        screen.text += " "
        #expect(screen.text == "привет ")
        let first = session.undoLastFix()
        if let first { screen.apply(first.edit) }
        #expect(screen.text == "ghbdtn ")
        #expect(first?.fix.isRepeat == false) // первая отмена — голос в обучение
        let second = session.undoLastFix()
        if let second { screen.apply(second.edit) }
        #expect(screen.text == "привет ")
        #expect(second?.fix.isRepeat == true) // дальше — просто переключение
        #expect(second?.edit.switchTo == .ru)
    }

    @Test func typingEndsTheToggle() {
        let session = TypingSession(detector: detector)
        session.type("ghbdtn")
        _ = session.invertLastWord()
        session.type("a")
        #expect(session.undoLastFix() == nil)
    }

    @Test func selectionFlipsWithoutReselecting() {
        let session = TypingSession(detector: detector)
        var screen = Screen(text: "привет мир")
        session.replacedSelection("ghbdtn vbh", with: "привет мир", changes: [], lang: .ru)
        let back = session.undoLastFix()
        if let back { screen.apply(back.edit) }
        #expect(screen.text == "ghbdtn vbh")
        #expect(back?.edit.switchTo == .en)
        if let again = session.undoLastFix() { screen.apply(again.edit) }
        #expect(screen.text == "привет мир")
    }

    @Test func wholePhraseKeepsCorrectWords() {
        let session = TypingSession(detector: detector)
        let smart = SmartConverter(detector: detector)
        var screen = Screen(text: "мы идем в rbyj")
        session.type("мы идем в rbyj")
        let r = session.convertPhrase(smart)
        if let r { screen.apply(r.edit) }
        #expect(screen.text == "мы идем в кино")
        #expect(r?.edit.removed == "rbyj") // правильные слова не перепечатываем
        if let back = session.undoLastFix() { screen.apply(back.edit) }
        #expect(screen.text == "мы идем в rbyj")
        if let again = session.undoLastFix() { screen.apply(again.edit) }
        #expect(screen.text == "мы идем в кино")
    }

    @Test func phraseWithSeveralWrongWords() {
        let session = TypingSession(detector: detector)
        let smart = SmartConverter(detector: detector)
        var screen = Screen(text: "ghbdtn, rfr ltkf?")
        session.type("ghbdtn, rfr ltkf?")
        if let r = session.convertPhrase(smart) { screen.apply(r.edit) }
        #expect(screen.text == "привет, как дела?")
    }

    @Test func realWordsSurviveContraryLearning() {
        // Пользователь дважды отменял «как» → обучение говорит «rfr — английское».
        // Но уже стоящее на экране «как» исправление фразы не трогает.
        let session = TypingSession(detector: detector)
        session.learned = { $0 == "rfr" ? .lang(.en) : nil }
        let smart = SmartConverter(detector: detector)
        var screen = Screen(text: "привет как ltkf")
        session.type("привет как ltkf")
        if let r = session.convertPhrase(smart) { screen.apply(r.edit) }
        #expect(screen.text == "привет как дела")
    }

    @Test func correctPhraseFallsBackToLastWord() {
        let session = TypingSession(detector: detector)
        let smart = SmartConverter(detector: detector)
        session.type("привет мир")
        #expect(session.convertPhrase(smart) == nil)
        let r = session.invertLastWord()
        #expect(r?.edit.removed == "мир")
    }
}

/// Последнее слово можно поменять в любой момент: недописанное, дописанное после
/// возврата, с двумя пробелами, из букв обеих раскладок.
@Suite struct LastWordAnytime {
    /// Клавиатура с раскладкой: клавиши печатают буквы текущей раскладки, клавиша
    /// исправления переключает её, как в программе. `layoutSwitches: false` — macOS
    /// не успела переключить раскладку.
    final class Keyboard {
        let session = TypingSession(detector: detector)
        let smart = SmartConverter(detector: detector)
        var screen = ""
        var layout = Lang.en
        var layoutSwitches = true

        /// `keys` — клавиши в латинской раскладке.
        func press(_ keys: String) {
            for key in keys {
                let c = layout == .ru ? map.convert(String(key), to: .ru) : String(key)
                if let ch = c.first, TypingSession.boundaries.contains(ch) {
                    if let e = session.boundary(ch) { apply(e) }
                } else {
                    session.type(c)
                }
                screen += c
            }
        }

        @discardableResult
        func hotkey() -> Bool {
            if let r = session.undoLastFix() { apply(r.edit); return true }
            if let r = session.convertPhrase(smart) { apply(r.edit); return true }
            if let r = session.invertLastWord() { apply(r.edit); return true }
            return false
        }

        func apply(_ edit: TextEdit) {
            #expect(screen.hasSuffix(edit.removed), "стираем [\(edit.removed)], а на экране [\(screen)]")
            screen.removeLast(min(edit.deleteCount, screen.count))
            screen += edit.insert
            if layoutSwitches, let lang = edit.switchTo { layout = lang }
        }
    }

    @Test func partialWordBackAndContinue() {
        let k = Keyboard()
        k.press("ghbd"); k.hotkey()
        #expect(k.screen == "прив")
        k.hotkey()
        #expect(k.screen == "ghbd")
        k.press("tn")
        #expect(k.hotkey())
        #expect(k.screen == "привет")
    }

    @Test func partialWordContinuedInNewLayout() {
        let k = Keyboard()
        k.press("ghb"); k.hotkey()
        k.press("dtn ")
        #expect(k.screen == "привет ")
    }

    @Test func layoutDidNotSwitchMixedWord() {
        let k = Keyboard()
        k.layoutSwitches = false
        k.press("ghb"); k.hotkey()
        k.press("dtn")
        #expect(k.screen == "приdtn")
        #expect(k.hotkey())
        #expect(k.screen == "привет")
    }

    @Test func twoSpacesAfterWord() {
        let k = Keyboard()
        k.press("ghbdtn  ")
        #expect(k.screen == "привет  ")
        #expect(k.hotkey())
        #expect(k.screen == "ghbdtn  ")
        k.hotkey()
        #expect(k.screen == "привет  ")
    }

    @Test func manualChoiceIsNotUndoneBySpace() {
        // Вручную сделали из «привет» английское «ghbdtn» — пробел не возвращает «привет».
        let k = Keyboard()
        k.layout = .ru
        k.press("ghbdtn")
        #expect(k.screen == "привет")
        k.hotkey()
        #expect(k.screen == "ghbdtn")
        k.press(" ")
        #expect(k.screen == "ghbdtn ")
        k.press("ghbdtn ") // следующее слово исправляется как обычно
        #expect(k.screen == "ghbdtn привет ")
    }

    @Test func afterClickScreenIsTheTruth() {
        let session = TypingSession(detector: detector)
        let smart = SmartConverter(detector: detector)
        session.reset() // кликнули мышью — память пуста
        session.sync(withScreen: "старая строка\nмы идем в rbyj")
        let r = session.convertPhrase(smart)
        #expect(r?.edit.removed == "rbyj")
        #expect(r?.edit.insert == "кино")
    }

    @Test func macOSPeriodAfterTwoSpaces() {
        // Память «привет  », а macOS заменила два пробела на «. ».
        let session = TypingSession(detector: detector)
        session.type("привет  ")
        session.sync(withScreen: "привет. ")
        let r = session.invertLastWord()
        #expect(r?.edit.removed == "привет. ")
        #expect(r?.edit.insert == "ghbdtn. ")
    }

    @Test func trailingKeysThatAreLetters() {
        let session = TypingSession(detector: detector)
        session.type("k.,k.")
        #expect(session.invertLastWord()?.edit.insert == "люблю")
    }

    @Test func percentTypedInRussianLayout() {
        let session = TypingSession(detector: detector)
        session.type("скидка 99:")
        let r = session.invertLastWord()
        #expect(r?.edit.removed == "99:")
        #expect(r?.edit.insert == "99%")
        #expect(r?.edit.switchTo == .en)
        // Время и обычные числа не трогаем.
        let other = TypingSession(detector: detector)
        other.type("10:30")
        #expect(other.invertLastWord() == nil)
    }

    @Test func consistentMemoryIsKept() {
        let session = TypingSession(detector: detector)
        session.type("rbyj")
        session.sync(withScreen: "Мы идем в rbyj") // память — хвост экрана: не трогаем
        #expect(session.text == "rbyj")
    }
}

/// Выделили текст целиком и нажали клавишу: обучение от этого портиться не должно.
@Suite struct MassSelection {
    @Test func learningDoesNotBreakRealWords() {
        #expect(decide("это", learned: .lang(.en)) == .keep)
        #expect(decide("и", learned: .lang(.en)) == .keep)
        #expect(decide("бы", learned: .lang(.en)) == .keep)
    }

    @Test func learningStillFixesNonWords() {
        #expect(decide("xnj", learned: .lang(.ru)) == .replace("что"))
    }

    @Test func poisonedLearningDoesNotMixText() {
        let smart = SmartConverter(detector: detector)
        let result = smart.convert("это мне она", learned: { _ in .lang(.en) })
        #expect(result?.text == "'nj vyt jyf") // меняется целиком, а не через слово
    }

    @Test func wholeTextTeachesNothing() {
        let smart = SmartConverter(detector: detector)
        #expect(smart.convert("это мне она")?.votes == [])
        #expect(smart.convert("ghbdtn rfr ltkf")?.votes == [])
    }

    @Test func singleSelectedWordStillTeaches() {
        let smart = SmartConverter(detector: detector)
        #expect(smart.convert("ghbdtn")?.votes.map(\.key) == ["ghbdtn"])
    }
}

@Suite struct LearnedMarks {
    @Test func learnedWordKeepsItsMark() {
        #expect(decide("ghbdtn.", learned: .lang(.ru)) == .replace("привет."))
        #expect(decide("ghbdtn.", learned: .lang(.ru)) == .replace("привет."))
    }

    @Test func lettersOnPunctuationKeysStayLetters() {
        #expect(decide("k.,k.", learned: .lang(.ru)) == .replace("люблю"))
    }
}

/// Первое слово после потери курсора может оказаться хвостом другого слова.
@Suite struct HiddenWordStart {
    private func typed(_ word: String, after prepare: (TypingSession) -> Void,
                       learned: Verdict? = nil, screen: Bool? = nil) -> TextEdit? {
        let session = TypingSession(detector: detector)
        session.learned = { _ in learned }
        session.letterBefore = { _ in screen }
        prepare(session)
        session.type(word)
        return session.boundary(" ")
    }

    @Test func tailAfterArrowsIsLeftAlone() {
        #expect(typed("xnj", after: { $0.cursorMoved() }) == nil)
        #expect(typed("d", after: { $0.cursorMoved() }, learned: .lang(.ru)) == nil)
    }

    @Test func arrowsAtWordStartStillFix() {
        #expect(typed("ghbdtn", after: { $0.cursorMoved() }, screen: false)?.insert == "привет")
    }

    @Test func clickFixesUnlessInsideWord() {
        #expect(typed("ghbdtn", after: { $0.clicked() })?.insert == "привет")
        #expect(typed("ghbdtn", after: { $0.clicked() }, screen: true) == nil)
    }

    @Test func shortcutMattersOnlyMidWord() {
        #expect(typed("xnj", after: { $0.type("при"); $0.interrupted() }) == nil)
        #expect(typed("ghbdtn", after: { $0.type("тест"); _ = $0.boundary(" "); $0.interrupted() })?.insert == "привет")
    }

    @Test func erasingUnseenTextHidesTheStart() {
        #expect(typed("xnj", after: { $0.backspace() }) == nil)
    }

    @Test func onlyTheFirstWordIsSuspect() {
        let session = TypingSession(detector: detector)
        session.cursorMoved()
        session.type("xnj")
        #expect(session.boundary(" ") == nil)
        session.type("ghbdtn")
        #expect(session.boundary(" ")?.insert == "привет")
    }

    @Test func tailTeachesNothing() {
        let session = TypingSession(detector: detector)
        session.cursorMoved()
        session.type("xnj")
        #expect(session.invertLastWord() != nil)
        #expect(session.lastWordTeaches == false)
        #expect(session.lastFix?.changes == [])
    }

    @Test func screenCheck() {
        #expect(TypingSession.letterBefore("nj", inScreen: "эnj") == true)
        #expect(TypingSession.letterBefore("nj", inScreen: "тест nj") == false)
        #expect(TypingSession.letterBefore("nj", inScreen: "nj") == false)
        #expect(TypingSession.letterBefore("nj", inScreen: "тест n") == nil)
    }
}

/// macOS заменяет кавычки на типографские — это не повод забывать про замену.
@Suite struct SmartQuotes {
    @Test func undoSurvivesReplacedQuote() {
        let edit = TextEdit(removed: "\"nj vyt", insert: "Это мне").adjusted(toScreen: "«nj vyt")
        #expect(edit?.removed == "«nj vyt")
        #expect(edit?.insert == "Это мне")
    }

    @Test func apostropheToo() {
        #expect(TextEdit(removed: "'nj vyt", insert: "это мне").adjusted(toScreen: "‘nj vyt")?.insert == "это мне")
    }

    @Test func otherTextStillStops() {
        #expect(TextEdit(removed: "\"nj vyt", insert: "Это мне").adjusted(toScreen: "xnj vyt") == nil)
    }

    @Test func caseFromScreenStillCarries() {
        #expect(TextEdit(removed: "ghbdtn vbh", insert: "привет мир").adjusted(toScreen: "Ghbdtn vbh")?.insert == "Привет мир")
    }

    @Test func secondPressReturnsText() {
        let session = TypingSession(detector: detector)
        session.replacedSelection("Это мне", with: "\"nj vyt", changes: [], lang: .en)
        session.sync(withScreen: "«nj vyt")
        #expect(session.lastFix != nil)
        #expect(session.undoLastFix()?.edit.adjusted(toScreen: "«nj vyt")?.insert == "Это мне")
    }
}
