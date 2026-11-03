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
