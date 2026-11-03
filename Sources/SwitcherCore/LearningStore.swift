import Foundation

/// Выученные правила: «в этом приложении слово с такими клавишами — русское».
/// Хранятся голоса, а не да/нет: каждое ручное исправление или отмена — голос,
/// старые голоса со временем весят меньше. Так противоречия не копятся.
public final class LearningStore {
    public struct Votes: Codable, Equatable {
        public var ru: Double
        public var en: Double
        public var updated: Date

        func decayed(to now: Date) -> Votes {
            let factor = pow(0.5, now.timeIntervalSince(updated) / LearningStore.halfLife)
            return Votes(ru: ru * factor, en: en * factor, updated: now)
        }

        var verdict: Verdict? {
            // Небольшой допуск: затухание превращает 2 голоса в 1.9999.
            let t = LearningStore.threshold - 0.01
            if ru >= t, en >= t, abs(ru - en) < t { return .unstable }
            if ru - en >= t { return .lang(.ru) }
            if en - ru >= t { return .lang(.en) }
            return nil
        }
    }

    public struct Rule: Equatable {
        public var key: String
        public var scope: String
        public var verdict: Verdict
    }

    /// Сколько исправлений нужно, чтобы слово попало в личный словарь.
    public static let threshold = 2.0
    /// Через полгода голос весит вдвое меньше.
    public static let halfLife: TimeInterval = 180 * 24 * 3600

    /// ключ слова → область («app:<bundle id>» или «cat:<категория>») → голоса
    public private(set) var entries: [String: [String: Votes]] = [:]
    private let url: URL?
    private let now: () -> Date

    public init(url: URL?, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? decoder.decode([String: [String: Votes]].self, from: data) {
            entries = saved
        }
    }

    public static func appScope(_ bundleID: String) -> String { "app:" + bundleID }
    public static func categoryScope(_ category: AppCategory) -> String { "cat:" + category.rawValue }

    public func vote(key: String, lang: Lang, weight: Double = 1, app: String, category: AppCategory) {
        let date = now()
        for scope in [Self.appScope(app), Self.categoryScope(category)] {
            var v = entries[key]?[scope]?.decayed(to: date) ?? Votes(ru: 0, en: 0, updated: date)
            switch lang {
            case .ru: v.ru += weight
            case .en: v.en += weight
            }
            entries[key, default: [:]][scope] = v
        }
        save()
    }

    /// Правило для слова: сначала приложение, потом его категория, потом общее.
    /// Общим правило становится, когда одинаково выучено в двух категориях —
    /// привычка из кода не перетекает в мессенджеры сама по себе.
    public func verdict(key: String, app: String, category: AppCategory) -> Verdict? {
        guard let scopes = entries[key] else { return nil }
        let date = now()
        if let v = scopes[Self.appScope(app)]?.decayed(to: date).verdict { return v }
        if let v = scopes[Self.categoryScope(category)]?.decayed(to: date).verdict { return v }

        let byCategory = scopes.filter { $0.key.hasPrefix("cat:") }.compactMap { $0.value.decayed(to: date).verdict }
        for lang in [Lang.ru, .en] where byCategory.filter({ $0 == .lang(lang) }).count >= 2 {
            if !byCategory.contains(.lang(lang.other)) { return .lang(lang) }
        }
        return nil
    }

    public var rules: [Rule] {
        let date = now()
        return entries.flatMap { key, scopes in
            scopes.compactMap { scope, votes in
                votes.decayed(to: date).verdict.map { Rule(key: key, scope: scope, verdict: $0) }
            }
        }
        .sorted { ($0.key, $0.scope) < ($1.key, $1.scope) }
    }

    public func remove(key: String) {
        entries[key] = nil
        save()
    }

    public func removeAll() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("YinYang: не удалось сохранить правила: \(error)")
        }
    }
}
