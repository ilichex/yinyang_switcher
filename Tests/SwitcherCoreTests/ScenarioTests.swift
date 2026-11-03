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
