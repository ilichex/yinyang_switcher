import Foundation
import Testing
import SwitcherCore

// Фиксированный словарь делает сценарии независимыми от словарей и настроек macOS.
private struct AuditDictionary: SpellChecking {
    func isValid(_ word: String, lang: Lang) -> Bool {
        switch lang {
        case .ru: ["идем", "люблю", "тест", "скидка", "кино"].contains(word.lowercased())
        case .en: ["hello", "world", "swift", "test"].contains(word.lowercased())
        }
    }
}

private func auditDetector() -> Detector {
    Detector(map: .macRussian, scorer: Scorer(spell: AuditDictionary()))
}

@Suite struct BehaviorAudit {
    @Test func erasedPendingSeparatorBecomesPartOfCurrentWord() {
        let session = TypingSession(detector: auditDetector())
        session.type("b")
        #expect(session.boundary(" ") == nil)
        session.backspace()
        session.type("ltv")
        let edit = session.boundary(" ")
        #expect(edit?.removed == "bltv")
        #expect(edit?.insert == "идем")
        #expect(session.text == "идем ")
    }

    @Test func erasedAndRetypedSeparatorDoesNotDuplicatePendingWord() {
        let session = TypingSession(detector: auditDetector())
        session.type("b")
        #expect(session.boundary(" ") == nil)
        for _ in 0..<3 {
            session.backspace()
            #expect(session.boundary(" ") == nil)
        }
        session.type("ghbdtn")
        let edit = session.boundary(" ")
        #expect(edit?.removed == "b ghbdtn")
        #expect(edit?.insert == "и привет")
        #expect(session.text == "и привет ")
    }

    @Test(arguments: AppCategory.allCases)
    func correctTokensSurviveEveryApplicationCategory(_ category: AppCategory) {
        let detector = auditDetector()
        let tokens = ["привет", "муж", "их", "дела", "hello", "world", "git", "swift", "10:30", "99%",
                      "fooBar", "snake_case", "https://example.com", "user@example.com", "--help", "/tmp/test", "🙂"]
        for token in tokens {
            let session = TypingSession(detector: detector)
            session.category = category
            session.type(token)
            #expect(session.boundary(" ") == nil, "Категория \(category), токен \(token)")
            #expect(session.text == token + " ")
        }
    }

    @Test(arguments: ["🙂", "👨‍👩‍👧‍👦", "e\u{301}"])
    func selectionUndoUsesVisibleCharacters(_ prefix: String) {
        let session = TypingSession(detector: auditDetector())
        let original = prefix + " ghbdtn"
        let replaced = prefix + " привет"
        session.replacedSelection(original, with: replaced, changes: [], lang: .ru)
        var screen = replaced
        for expected in [original, replaced, original, replaced] {
            guard let edit = session.undoLastFix()?.edit else {
                Issue.record("Повторная отмена должна оставаться доступной")
                return
            }
            #expect(screen.hasSuffix(edit.removed))
            guard screen.hasSuffix(edit.removed) else { return }
            screen.removeLast(edit.deleteCount)
            screen += edit.insert
            #expect(screen == expected)
        }
    }

    @Test func recentScreenSnapshotMayLagBehindWholeCurrentWord() {
        let session = TypingSession(detector: auditDetector())
        session.type("ghbdtn")
        session.sync(withScreen: "ghbdt", allowIncompleteWord: true)
        let edit = session.invertLastWord()?.edit
        #expect(edit?.removed == "ghbdtn")
        #expect(edit?.insert == "привет")
    }

    @Test func recentSnapshotMayContainUntrackedPrefixAndLaggingWord() {
        let session = TypingSession(detector: auditDetector())
        session.type("ghbdtn")
        session.sync(withScreen: "старая строка\nэто ghbdt", allowIncompleteWord: true)
        let edit = session.invertLastWord()?.edit
        #expect(edit?.removed == "ghbdtn")
        #expect(edit?.insert == "привет")
    }

    @Test func completeSnapshotCanReplaceShortenedCurrentWord() {
        let session = TypingSession(detector: auditDetector())
        session.type("ghbdtn")
        session.sync(withScreen: "ghbdt")
        #expect(session.text == "ghbdt")
        #expect(session.invertLastWord()?.edit.removed == "ghbdt")
    }

    @Test func symbolInversionUsesSourceLayout() {
        for (input, source, expected) in [(":", Lang.ru, "%"), ("%", .en, ":"), ("99:", .ru, "99%"), ("50,5:", .ru, "50,5%") ] {
            let session = TypingSession(detector: auditDetector())
            session.type(input)
            let edit = session.invertLastWord(sourceLang: source)?.edit
            #expect(edit?.removed == input)
            #expect(edit?.insert == expected)
            #expect(edit?.switchTo == source.other)
            #expect(session.undoLastFix()?.edit.insert == input)
        }
    }

    @Test func selectedSymbolsCanBeConvertedWithoutLetters() {
        let smart = SmartConverter(detector: auditDetector())
        for (input, source, expected) in [(":", Lang.ru, "%"), ("99:", .ru, "99%"), ("%", .en, ":")] {
            let result = smart.convert(input, sourceLang: source)
            #expect(result?.text == expected)
            #expect(result?.lang == source.other)
            #expect(result?.votes.isEmpty == true)
        }
    }

    @Test func plainNumbersAndClockTimeAreNotInverted() {
        for input in ["99", "10:30", "2026", "3.14"] {
            let session = TypingSession(detector: auditDetector())
            session.type(input)
            #expect(session.invertLastWord() == nil)
            #expect(session.invertLastWord(sourceLang: .ru) == nil)
            #expect(session.invertLastWord(sourceLang: .en) == nil)
            #expect(session.text == input)
        }
    }

    @Test func combiningInputDoesNotInflateDeletionCount() {
        let session = TypingSession(detector: auditDetector())
        session.type("e")
        session.type("\u{301}")
        #expect(session.text == "e\u{301}")
        #expect(session.chars.count == 1)
        #expect(session.invertLastWord() == nil)
        session.backspace()
        #expect(session.text.isEmpty)
    }

    @Test func symbolCorrectionDoesNotTeachWordRules() {
        let session = TypingSession(detector: auditDetector())
        session.type(":")
        #expect(session.invertLastWord(sourceLang: .ru)?.edit.insert == "%")
        #expect(!session.lastWordTeaches)
        #expect(session.lastFix?.changes.isEmpty == true)
        #expect(session.undoLastFix()?.fix.changes.isEmpty == true)
    }

    @Test func framingQuotesArePreservedWhileLettersChange() {
        let smart = SmartConverter(detector: auditDetector())
        for (input, expected) in [("\"ghbdtn\"", "\"привет\""), ("\"привет\"", "\"ghbdtn\"")] {
            let session = TypingSession(detector: auditDetector())
            session.type(input)
            #expect(session.invertLastWord()?.edit.insert == expected)
            #expect(smart.convert(input)?.text == expected)
        }
    }

    @Test func deterministicEditingSequencesKeepScreenAndSessionConsistent() {
        let chunks = ["b", "ghbdtn", "ltv", "hello", "🙂", "e\u{301}", "\u{301}", "rbyj", ":", "99", "тест"]
        let detector = auditDetector()
        let smart = SmartConverter(detector: detector)
        for seed in UInt64(1)...20 {
            let session = TypingSession(detector: detector)
            var screen = ""
            var random = seed
            func apply(_ edit: TextEdit?) -> Bool {
                guard let edit else { return true }
                let matches = screen.hasSuffix(edit.removed)
                #expect(matches, "seed=\(seed), экран=\(screen), удаляем=\(edit.removed)")
                guard matches else { return false }
                screen.removeLast(edit.deleteCount)
                screen += edit.insert
                return true
            }
            for _ in 0..<400 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                switch (random >> 32) % 10 {
                case 0...3:
                    let text = chunks[Int(random % UInt64(chunks.count))]
                    session.type(text)
                    screen += text
                case 4...5:
                    guard apply(session.boundary(" ")) else { return }
                    screen += " "
                case 6:
                    session.backspace()
                    if !screen.isEmpty { screen.removeLast() }
                case 7:
                    let edit = session.undoLastFix()?.edit
                        ?? session.convertPhrase(smart)?.edit
                        ?? session.invertLastWord()?.edit
                    guard apply(edit) else { return }
                case 8:
                    session.reset()
                    screen = ""
                default:
                    guard apply(session.boundary("\n")) else { return }
                    screen += "\n"
                }
                #expect(screen.hasSuffix(session.text), "seed=\(seed), экран=\(screen), память=\(session.text)")
            }
        }
    }
}
