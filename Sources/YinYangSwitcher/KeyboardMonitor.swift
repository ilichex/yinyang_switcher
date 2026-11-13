import AppKit
import Carbon
import SwitcherCore

/// Перехватывает клавиатуру и ведёт модель набранного текста.
/// На пробеле/Enter/Tab спрашивает TypingSession, нужна ли правка, и если да —
/// «съедает» разделитель, исправляет слово и сам допечатывает разделитель.
final class KeyboardMonitor {
    let session: TypingSession
    var isActive: () -> Bool = { true }
    var onEdit: (TextEdit) -> Void = { _ in }
    var onHotkey: () -> Void = {}
    var hotkey: Hotkey = .default {
        didSet { taps = TapDetector(count: hotkey.count) }
    }
    /// Пока задано — назначаем клавишу: следующее нажатие отдаётся сюда (код клавиши)
    /// и в программы не попадает.
    var onRecord: ((Int) -> Void)?
    /// Сочетание «включить/выключить»; nil — не используется.
    var toggle: Shortcut? = .defaultToggle {
        didSet { chord = ChordDetector(target: toggle?.keyCode == nil ? toggle?.modifiers ?? 0 : 0) }
    }
    var onToggle: () -> Void = {}
    /// Пока задано — записываем новое сочетание «включить/выключить». nil в ответ — Esc.
    var onRecordShortcut: ((Shortcut?) -> Void)? {
        didSet { recorder = ShortcutRecorder() }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var taps = TapDetector(count: Hotkey.default.count)
    private var chord = ChordDetector(target: Shortcut.defaultToggle.modifiers)
    private var recorder = ShortcutRecorder()
    /// Программа, в которую ушло последнее нажатие.
    private(set) var lastTarget: Int64 = 0
    /// Любое действие человека отменяет ожидающую операцию с выделением.
    private(set) var inputRevision: UInt64 = 0
    private var lastTypingAt = -TimeInterval.infinity
    private var lastDeletionAt = -TimeInterval.infinity
    var hasRecentTyping: Bool { ProcessInfo.processInfo.systemUptime - lastTypingAt < 0.25 }
    var hasRecentDeletion: Bool { ProcessInfo.processInfo.systemUptime - lastDeletionAt < 0.25 }
    private static let modifierMask: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]

    init(session: TypingSession) {
        self.session = session
    }

    func updateTarget(_ target: Int64) {
        guard target != 0, target != lastTarget else { return }
        lastTarget = target
        inputRevision &+= 1
        session.reset()
    }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Требует разрешения «Универсальный доступ». Возвращает false, если его ещё нет.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    var isStarted: Bool { tap != nil }

    /// Снимает перехват — например, если доступ отозвали, пока программа работала.
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        session.reset()
        taps.interrupt()
    }

    /// macOS выключает перехват, если обработчик долго думал; включаем обратно.
    func ensureEnabled() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            session.cursorMoved()
            taps.interrupt()
            chord.interrupt()
            inputRevision &+= 1
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if TextInjector.isOurs(event) { return pass }
        if [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            inputRevision &+= 1
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Пока перехват был выключен, ввод мог пройти мимо нашей памяти.
            session.cursorMoved()
            taps.interrupt()
            chord.interrupt()
            inputRevision &+= 1
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Курсор мог переехать — что «до него», мы больше не знаем.
            session.clicked()
            taps.interrupt()
            chord.interrupt()
            return pass
        case .flagsChanged:
            if !TextInjector.isOurs(event) { handleFlags(event) }
            return pass
        case .keyDown:
            if TextInjector.isOurs(event) { return pass }
            return handleKey(event, proxy: proxy)
        default:
            return pass
        }
    }

    private func handleFlags(_ event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modifiers = flags.rawValue & Shortcut.allModifiers
        if let onRecordShortcut {
            if let shortcut = recorder.flags(modifiers) { onRecordShortcut(shortcut) }
            return
        }
        if let onRecord {
            // Модификатор назначаем по нажатию, отпускание пропускаем.
            if let flag = Hotkey.modifierFlags[code], flags.contains(flag) { onRecord(code) }
            return
        }
        if chord.flags(modifiers, at: ProcessInfo.processInfo.systemUptime) {
            DispatchQueue.main.async { self.onToggle() }
        }
        guard let flag = hotkey.flag, hotkey.keyCodes.contains(code),
              flags.intersection(Self.modifierMask).subtracting(flag).isEmpty else {
            taps.interrupt()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if flags.contains(flag) {
            taps.press(at: now)
        } else if taps.release(at: now) {
            scheduleHotkey()
        }
    }

    private func scheduleHotkey() {
        let revision = inputRevision
        DispatchQueue.main.async {
            guard self.inputRevision == revision else { return }
            self.onHotkey()
        }
    }

    /// F-клавиша из настройки: забираем нажатие себе. true — событие съедено.
    private func handleFunctionHotkey(_ code: Int, _ event: CGEvent) -> Bool {
        guard hotkey.flag == nil, hotkey.keyCodes.contains(code), isActive(),
              event.flags.intersection(Self.modifierMask).isEmpty else { return false }
        // Автоповтор при удержании — не новое нажатие.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           taps.keyPress(at: ProcessInfo.processInfo.systemUptime) {
            scheduleHotkey()
        }
        return true
    }

    private func handleKey(_ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.rawValue & Shortcut.allModifiers
        if let onRecordShortcut {
            onRecordShortcut(code == kVK_Escape && modifiers == 0 ? nil : recorder.key(code, modifiers: modifiers))
            return nil
        }
        if let onRecord {
            onRecord(code)
            return nil
        }
        chord.interrupt()
        if let toggle, toggle.keyCode == code, toggle.modifiers == modifiers {
            // Автоповтор при удержании — не новое нажатие.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { self.onToggle() }
            }
            return nil
        }
        if handleFunctionHotkey(code, event) { return nil }
        taps.interrupt()
        // Нажатие пришло в другую программу — всё, что помнили, относится к прошлой.
        // Уведомление macOS о смене программы приходит позже первых букв, поэтому смотрим здесь.
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        updateTarget(target)

        guard isActive(), !IsSecureEventInputEnabled() else {
            // Поле пароля или выключено: ничего не запоминаем.
            session.reset()
            return pass
        }
        if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            session.interrupted()
            return pass
        }

        switch code {
        case kVK_Delete:
            lastDeletionAt = ProcessInfo.processInfo.systemUptime
            // ⌥⌫ стирает слово целиком, а где у слова граница — решает программа.
            // Стирать из памяти одну букву нельзя: остаток потом исправится вместе с новым словом.
            if event.flags.contains(.maskAlternate) {
                session.reset(keepContext: true)
            } else {
                session.backspace()
            }
            return pass
        case kVK_Space:
            // ⌥Space — неразрывный пробел, не обычный разделитель.
            if event.flags.contains(.maskAlternate) {
                session.cursorMoved()
                return pass
            }
            return boundary(" ", event, proxy: proxy)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return boundary("\n", event, proxy: proxy)
        case kVK_Tab:
            return boundary("\t", event, proxy: proxy)
        case kVK_Escape, kVK_ForwardDelete:
            session.interrupted()
            return pass
        case kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            session.cursorMoved()
            return pass
        default:
            // Option может запускать составной ввод (dead key). По отдельным событиям
            // нельзя узнать, сколько символов действительно появится в программе.
            if event.flags.contains(.maskAlternate) {
                session.cursorMoved()
                return pass
            }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            let text = String(utf16CodeUnits: buffer, count: length)
            let printable = !text.isEmpty && !text.unicodeScalars.contains {
                $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) // управляющие и F-клавиши
            }
            if printable {
                lastTypingAt = ProcessInfo.processInfo.systemUptime
                session.type(text)
            } else { session.interrupted() }
            return pass
        }
    }

    private func boundary(_ separator: Character, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        guard let planned = session.boundary(separator) else { return Unmanaged.passUnretained(event) }
        guard let edit = TextInjector.checked(planned) else {
            // Текст поменяли без нас — не трогаем и начинаем с чистого листа.
            session.reset(keepContext: true)
            return Unmanaged.passUnretained(event)
        }
        // Разделитель придержали: сначала исправляем слово, потом допечатываем его сами.
        TextInjector.apply(edit, proxy: proxy)
        if let copy = event.copy() { TextInjector.post(copy, proxy: proxy) }
        onEdit(edit)
        return nil
    }
}

private func keyboardCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type, event, proxy: proxy)
}
