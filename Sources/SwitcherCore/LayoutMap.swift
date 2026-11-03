import Carbon
import Foundation

public enum Lang: String, Codable, Sendable {
    case ru, en

    public var other: Lang { self == .ru ? .en : .ru }
}

/// Соответствие символов между английской и русской раскладкой «по клавишам».
/// Строится из реальных раскладок системы, поэтому знаки препинания совпадают
/// с тем, что пользователь видит на своей клавиатуре.
public struct LayoutMap: Sendable {
    public let enToRu: [Character: Character]
    public let ruToEn: [Character: Character]

    public init(pairs: [(en: Character, ru: Character)]) {
        var e2r: [Character: Character] = [:]
        var r2e: [Character: Character] = [:]
        for (e, r) in pairs where e != r {
            if e2r[e] == nil { e2r[e] = r }
            if r2e[r] == nil { r2e[r] = e }
        }
        enToRu = e2r
        ruToEn = r2e
    }

    /// Переводит строку так, будто те же клавиши нажали в раскладке `target`.
    /// Символы, которых нет в таблице (цифры, пробелы), остаются как есть.
    public func convert(_ s: String, to target: Lang) -> String {
        let table = target == .ru ? enToRu : ruToEn
        return String(s.map { table[$0] ?? $0 })
    }

    /// Символ, который даст та же клавиша в другой раскладке.
    public func counterpart(of c: Character, to target: Lang) -> Character? {
        (target == .ru ? enToRu : ruToEn)[c]
    }

    /// Раскладка, в которой, судя по буквам, набран текст. nil — букв нет или они смешаны.
    public static func detectLang(_ s: String) -> Lang? {
        var hasRu = false, hasEn = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0400...0x04FF: hasRu = true
            case 0x41...0x5A, 0x61...0x7A: hasEn = true
            default: break
            }
        }
        if hasRu == hasEn { return nil }
        return hasRu ? .ru : .en
    }
}

extension LayoutMap {
    /// Таблица для пары «ABC» + «Русская» (маковская). Используется в тестах
    /// и как запасной вариант, если раскладки не удалось прочитать из системы.
    public static let macRussian: LayoutMap = {
        let pairs: [(Character, Character)] = [
            ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("h", "р"), ("g", "п"),
            ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("q", "й"),
            ("w", "ц"), ("e", "у"), ("r", "к"), ("y", "н"), ("t", "е"), ("]", "ъ"),
            ("o", "щ"), ("u", "г"), ("[", "х"), ("i", "ш"), ("p", "з"), ("l", "д"),
            ("j", "о"), ("'", "э"), ("k", "л"), (";", "ж"), ("\\", "ё"), (",", "б"),
            ("n", "т"), ("m", "ь"), (".", "ю"), ("`", "]"), ("§", ">"),
            ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("H", "Р"), ("G", "П"),
            ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"), ("Q", "Й"),
            ("W", "Ц"), ("E", "У"), ("R", "К"), ("Y", "Н"), ("T", "Е"), ("}", "Ъ"),
            ("O", "Щ"), ("U", "Г"), ("{", "Х"), ("I", "Ш"), ("P", "З"), ("L", "Д"),
            ("J", "О"), ("\"", "Э"), ("K", "Л"), (":", "Ж"), ("|", "Ё"), ("<", "Б"),
            ("N", "Т"), ("M", "Ь"), (">", "Ю"), ("~", "["), ("±", "<"),
            ("@", "\""), ("#", "№"), ("$", "%"), ("^", ","), ("%", ":"), ("&", "."), ("*", ";"),
        ]
        return LayoutMap(pairs: pairs.map { (en: $0.0, ru: $0.1) })
    }()

    /// Строит таблицу из двух раскладок системы, нажимая «виртуально» каждую клавишу.
    public static func fromSystem(en: TISInputSource, ru: TISInputSource) -> LayoutMap? {
        guard let enKeys = keyTable(en), let ruKeys = keyTable(ru) else { return nil }
        // Сначала без Shift: при совпадении символов приоритет у основного слоя.
        let keys = enKeys.keys.sorted { ($0.shift ? 1 : 0, $0.code) < ($1.shift ? 1 : 0, $1.code) }
        let pairs = keys.compactMap { key in
            ruKeys[key].map { (en: enKeys[key]!, ru: $0) }
        }
        return pairs.isEmpty ? nil : LayoutMap(pairs: pairs)
    }

    struct Key: Hashable {
        let code: UInt16
        let shift: Bool
    }

    private static func keyTable(_ source: TISInputSource) -> [Key: Character]? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var table: [Key: Character] = [:]
        // 36 Return, 48 Tab, 49 Space — не символы.
        for code in UInt16(0)...50 where ![36, 48, 49].contains(code) {
            for shift in [false, true] {
                var dead: UInt32 = 0
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), shift ? 2 : 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &dead, 4, &length, &buffer
                )
                guard status == noErr, length == 1 else { continue }
                let s = String(utf16CodeUnits: buffer, count: length)
                guard let c = s.first, !c.isWhitespace, c.asciiValue.map({ $0 >= 0x20 }) ?? true else { continue }
                table[Key(code: code, shift: shift)] = c
            }
        }
        return table
    }
}
