import AppKit
import Carbon
import SwitcherCore

/// Клавиша ручного исправления: какая клавиша и сколько раз подряд её нажать.
///
/// Подходят только клавиши, которые ничего не печатают: модификаторы (у них «чистое»
/// нажатие без других клавиш ничего не делает) и F-клавиши (их нажатие программа забирает
/// себе). Буквы и цифры нельзя — их пришлось бы задерживать при каждом наборе.
struct Hotkey: Equatable {
    /// Несколько кодов — «любой»: левая или правая клавиша.
    var keyCodes: Set<Int>
    /// 1, 2 или 3.
    var count: Int

    /// Одно нажатие ⌥ — самое быстрое; ⌥ с буквой (особые знаки) и ⌥⌘ нажатием не считаются.
    static let `default` = Hotkey(keyCodes: [kVK_Option, kVK_RightOption], count: 1)
    static let counts = 1...3

    static let presets: [(title: String, keyCodes: Set<Int>)] = [
        ("⇧ Shift (любой)", [kVK_Shift, kVK_RightShift]),
        ("⌥ Option (любой)", [kVK_Option, kVK_RightOption]),
        ("Правый ⌥ Option", [kVK_RightOption]),
        ("Правый ⌘ Command", [kVK_RightCommand]),
        ("fn", [kVK_Function]),
    ]

    /// Флаг модификатора, или nil для F-клавиши.
    var flag: CGEventFlags? { keyCodes.first.flatMap { Self.modifierFlags[$0] } }

    var keyTitle: String {
        if let preset = Self.presets.first(where: { $0.keyCodes == keyCodes }) { return preset.title }
        return keyCodes.sorted().map(Self.name(of:)).joined(separator: " / ")
    }

    var title: String { "\(Self.countTitle(count).lowercased()) \(keyTitle)" }

    static func countTitle(_ count: Int) -> String {
        switch count {
        case 1: "Одинарное"
        case 3: "Тройное"
        default: "Двойное"
        }
    }

    static func isAllowed(_ code: Int) -> Bool {
        modifierFlags[code] != nil || functionKeys[code] != nil
    }

    static func name(of code: Int) -> String {
        switch code {
        case kVK_Shift: "Левый ⇧ Shift"
        case kVK_RightShift: "Правый ⇧ Shift"
        case kVK_Control: "Левый ⌃ Control"
        case kVK_RightControl: "Правый ⌃ Control"
        case kVK_Option: "Левый ⌥ Option"
        case kVK_RightOption: "Правый ⌥ Option"
        case kVK_Command: "Левый ⌘ Command"
        case kVK_RightCommand: "Правый ⌘ Command"
        case kVK_Function: "fn"
        default: functionKeys[code] ?? "клавиша \(code)"
        }
    }

    static let modifierFlags: [Int: CGEventFlags] = [
        kVK_Shift: .maskShift, kVK_RightShift: .maskShift,
        kVK_Control: .maskControl, kVK_RightControl: .maskControl,
        kVK_Option: .maskAlternate, kVK_RightOption: .maskAlternate,
        kVK_Command: .maskCommand, kVK_RightCommand: .maskCommand,
        kVK_Function: .maskSecondaryFn,
    ]

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20", kVK_Help: "Insert",
    ]

    // MARK: - Хранение

    init(keyCodes: Set<Int>, count: Int) {
        self.keyCodes = keyCodes
        self.count = min(max(count, Self.counts.lowerBound), Self.counts.upperBound)
    }

    init(defaults: UserDefaults) {
        // Числа могли записаться строками (defaults write -array 97) — понимаем и так.
        let codes = (defaults.array(forKey: "hotkeyKeys") ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
        if !codes.isEmpty, codes.allSatisfy(Self.isAllowed) {
            self.init(keyCodes: Set(codes), count: defaults.integer(forKey: "hotkeyCount"))
            return
        }
        // Настройка из версии 0.1, где были только готовые варианты.
        switch defaults.string(forKey: "hotkey") {
        case "doubleOption": self.init(keyCodes: [kVK_Option, kVK_RightOption], count: 2)
        case "rightOption": self.init(keyCodes: [kVK_RightOption], count: 1)
        case "rightCommand": self.init(keyCodes: [kVK_RightCommand], count: 1)
        default: self = .default
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(keyCodes.sorted(), forKey: "hotkeyKeys")
        defaults.set(count, forKey: "hotkeyCount")
        defaults.removeObject(forKey: "hotkey")
    }
}

// MARK: - Сочетание «включить/выключить»

extension Shortcut {
    static let presets: [(title: String, shortcut: Shortcut)] = [
        ("⌥⌘ — нажать вместе и отпустить", .defaultToggle),
        ("⌃⌥ — нажать вместе и отпустить", Shortcut(modifiers: control | option)),
        ("⌃⌥Y", Shortcut(modifiers: control | option, keyCode: kVK_ANSI_Y)),
    ]

    var title: String { modifierSymbols + (keyCode.map(Self.keyName) ?? "") }

    /// Аккорд — от двух модификаторов: один ⌥ или ⇧ жмут постоянно. С клавишей — нужен ⌘ или ⌃,
    /// иначе сочетание мешало бы печатать (⇧ — заглавные, ⌥ — особые знаки); F-клавиши можно как есть.
    var isAllowed: Bool {
        guard let keyCode else { return modifiers.nonzeroBitCount >= 2 }
        if Hotkey.functionKeys[keyCode] != nil { return true }
        return keyCode != kVK_Escape && modifiers & (Self.command | Self.control) != 0
    }

    /// Буква на клавише в латинской раскладке: «Y», а не код 16.
    static func keyName(_ code: Int) -> String {
        if let name = Hotkey.functionKeys[code] { return name }
        switch code {
        case kVK_Space: return "Пробел"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "клавиша \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "клавиша \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
