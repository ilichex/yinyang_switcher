import Foundation
import Testing
import SwitcherCore

let map = LayoutMap.macRussian
let detector = Detector(map: map, scorer: Scorer(spell: SystemSpellChecker()))

func decide(_ token: String, previous: Lang? = nil, category: AppCategory = .other, learned: Verdict? = nil) -> Decision.Action {
    detector.decide(token, context: DetectionContext(previousLang: previous, category: category, learned: learned)).action
}

/// Печатает строку посимвольно, как это делает пользователь, и возвращает то, что видно на экране.
func typeText(_ input: String, category: AppCategory = .other, learned: @escaping (String) -> Verdict? = { _ in nil }) -> String {
    let session = TypingSession(detector: detector)
    session.category = category
    session.learned = learned
    var screen: [Character] = []
    for c in input {
        if TypingSession.boundaries.contains(c) {
            if let edit = session.boundary(c) {
                screen.removeLast(edit.deleteCount)
                screen.append(contentsOf: edit.insert)
            }
            screen.append(c)
        } else {
            session.type(String(c))
            screen.append(c)
        }
    }
    return String(screen)
}

@Suite struct Layout {
    @Test func convertsBothWays() {
        #expect(map.convert("ghbdtn", to: .ru) == "привет")
        #expect(map.convert("руддщ", to: .en) == "hello")
        #expect(map.convert("Ghbdtn", to: .ru) == "Привет")
        #expect(map.convert("nt,z", to: .ru) == "тебя")
        #expect(map.convert("to\\", to: .ru) == "ещё")
    }

    @Test func detectsLanguage() {
        #expect(LayoutMap.detectLang("ghbdtn") == .en)
        #expect(LayoutMap.detectLang("привет") == .ru)
        #expect(LayoutMap.detectLang("приvet") == nil)
        #expect(LayoutMap.detectLang("123") == nil)
    }
}

@Suite struct Decisions {
    @Test func wrongLayoutIsFixed() {
        #expect(decide("ghbdtn") == .replace("привет"))
        #expect(decide("руддщ") == .replace("hello"))
        #expect(decide("yt") == .replace("не"))
        #expect(decide("vs") == .replace("мы"))
    }

    @Test func correctWordsStay() {
        for w in ["привет", "hello", "муж", "их", "ой", "ok", "in", "шт", "кг"] {
            #expect(decide(w) == .keep, "\(w)")
        }
    }

    @Test func gibberishIsLeftToUser() {
        #expect(decide("ghbdtnr") == .keep)
        #expect(decide("фывапр") == .keep)
    }

    @Test func trailingKeyIsPunctuation() {
        #expect(decide("тестж") == .replace("тест;"))
        #expect(decide("ghbdtn,") == .replace("привет,"))
        // «ntcn.» не подходит: «тестю» — настоящее слово (от «тесть»).
        #expect(decide("ghbdtn.") == .replace("привет."))
    }

    @Test func singleLetterWaitsForContext() {
        #expect(decide("b") == .pending("и"))
        #expect(decide("b", previous: .ru) == .replace("и"))
        #expect(decide("b", previous: .en) == .keep)
    }

    @Test func terminalCommandsInRussianLayout() {
        #expect(decide("пше") == .replace("git"))
        #expect(decide("св") == .replace("cd"))
        #expect(decide("ды") == .replace("ls"))
    }

    @Test func codeIsNotTouched() {
        for w in ["user_id", "https://ya.ru", "a@b.c", "--help", "myVar", "x2"] {
            #expect(decide(w) == .keep, "\(w)")
        }
    }

    @Test func shortWordsInCodeWaitForRussianContext() {
        #expect(decide("yt", category: .code) == .pending("не"))
        #expect(decide("yt", previous: .ru, category: .code) == .replace("не"))
    }

    @Test func learnedRulesWin() {
        #expect(decide("b", learned: .lang(.en)) == .keep)
        #expect(decide("ghbdtn", learned: .unstable) == .keep)
        #expect(decide("руддщ", learned: .lang(.ru)) == .keep)
    }
}

@Suite struct Typing {
    @Test func userScenarioPendingLetter() {
        // «и» набрали в английской раскладке, дальше пошли русские слова.
        #expect(typeText("b ltkf ") == "и дела ")
        #expect(typeText("ghbdtn rfr ltkf ") == "привет как дела ")
    }

    @Test func pendingLetterStaysInEnglish() {
        #expect(typeText("b hello ") == "b hello ")
    }

    @Test func pendingResolvedByCorrectlyTypedWord() {
        // Пользователь сам переключил раскладку после «b».
        #expect(typeText("b дела ") == "и дела ")
    }

    @Test func enterResetsPending() {
        #expect(typeText("b\nltkf ") == "b\nдела ")
    }

    @Test func undoRestoresOriginal() {
        let session = TypingSession(detector: detector)
        session.type("ghbdtn")
        let edit = session.boundary(" ")
        #expect(edit?.insert == "привет")
        let undo = session.undoLastFix()
        #expect(undo?.edit.insert == "ghbdtn ")
        #expect(undo?.edit.deleteCount == 7)
        #expect(undo?.fix.changes == [WordChange(key: "ghbdtn", from: .en, to: .ru)])
        #expect(session.text == "ghbdtn ")
    }

    @Test func invertLastWord() {
        let session = TypingSession(detector: detector)
        session.type("ghbdtnr")
        let r = session.invertLastWord()
        #expect(r?.edit == TextEdit(deleteCount: 7, insert: "приветк", switchTo: .ru))
        #expect(r?.change == WordChange(key: "ghbdtnr", from: .en, to: .ru))
    }

    @Test func russianCommentInCodeEditor() {
        #expect(typeText("a + b ", category: .code) == "a + b ")
        #expect(typeText("// b ghjdthrf ", category: .code) == "// и проверка ")
    }

    @Test func learnedExceptionInCodeEditor() {
        #expect(typeText("a + b ", category: .code, learned: { $0 == "b" ? .lang(.en) : nil }) == "a + b ")
    }
}

@Suite struct Selection {
    let smart = SmartConverter(detector: detector)

    @Test func onlyUnclearWordsAreInverted() {
        #expect(smart.convert("Привет vbh")?.text == "Привет мир")
        #expect(smart.convert("hello цщкдв")?.text == "hello world")
    }

    @Test func everythingInvertedWhenNothingToFix() {
        #expect(smart.convert("привет")?.text == "ghbdtn")
        #expect(smart.convert("привет")?.lang == .en)
    }

    @Test func pendingResolvedByNeighbours() {
        #expect(smart.convert("b ltkf")?.text == "и дела")
    }
}

@Suite struct Versions {
    @Test func parsesTags() {
        #expect(AppVersion("v1.2.3")?.parts == [1, 2, 3])
        #expect(AppVersion("0.1")?.description == "0.1")
        #expect(AppVersion("1.2-beta") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test func comparesNumerically() {
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
        #expect(AppVersion("1.2")! == AppVersion("v1.2.0")!)
        #expect(AppVersion("0.1.0")! < AppVersion("0.2")!)
    }
}

@Suite struct Learning {
    @Test func twoVotesMakeARule() {
        let store = LearningStore(url: nil)
        store.vote(key: "b", lang: .en, app: "com.microsoft.VSCode", category: .code)
        #expect(store.verdict(key: "b", app: "com.microsoft.VSCode", category: .code) == nil)
        store.vote(key: "b", lang: .en, app: "com.microsoft.VSCode", category: .code)
        #expect(store.verdict(key: "b", app: "com.microsoft.VSCode", category: .code) == .lang(.en))
        // В мессенджере правило из редактора кода не действует.
        #expect(store.verdict(key: "b", app: "ru.keepcoder.Telegram", category: .chat) == nil)
        // А в другом редакторе — действует через категорию.
        #expect(store.verdict(key: "b", app: "dev.zed.Zed", category: .code) == .lang(.en))
    }

    @Test func flipFloppingBecomesUnstable() {
        let store = LearningStore(url: nil)
        for lang in [Lang.ru, .en, .ru, .en] {
            store.vote(key: "ns", lang: lang, app: "x", category: .chat)
        }
        #expect(store.verdict(key: "ns", app: "x", category: .chat) == .unstable)
    }

    @Test func promotedToGlobalAfterTwoCategories() {
        let store = LearningStore(url: nil)
        for _ in 0..<2 { store.vote(key: "jy", lang: .ru, app: "a", category: .chat) }
        #expect(store.verdict(key: "jy", app: "z", category: .docs) == nil)
        for _ in 0..<2 { store.vote(key: "jy", lang: .ru, app: "b", category: .browser) }
        #expect(store.verdict(key: "jy", app: "z", category: .docs) == .lang(.ru))
    }

    @Test func oldVotesFade() {
        var date = Date(timeIntervalSince1970: 0)
        let store = LearningStore(url: nil, now: { date })
        for _ in 0..<2 { store.vote(key: "b", lang: .en, app: "a", category: .code) }
        date += LearningStore.halfLife
        #expect(store.verdict(key: "b", app: "a", category: .code) == nil)
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LearningStore(url: url)
        for _ in 0..<2 { store.vote(key: "b", lang: .en, app: "a", category: .code) }
        let reloaded = LearningStore(url: url)
        #expect(reloaded.verdict(key: "b", app: "a", category: .code) == .lang(.en))
    }
}
