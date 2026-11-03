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
    var hotkey: Hotkey = .doubleShift

    private var tap: CFMachPort?

    // Короткое «чистое» нажатие модификатора (без других клавиш); для двойных — два подряд.
    private var hotkeyDownAt: TimeInterval = 0
    private var hotkeyClean = false
    private var lastTapUp: TimeInterval = 0
    private static let tapLength: TimeInterval = 0.3
    private static let doubleTapGap: TimeInterval = 0.35

    init(session: TypingSession) {
        self.session = session
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Курсор мог переехать — что «до него», мы больше не знаем.
            session.reset(keepContext: true)
            hotkeyClean = false
            lastTapUp = 0
            return pass
        case .flagsChanged:
            if !TextInjector.isOurs(event) { handleFlags(event) }
            return pass
        case .keyDown:
            if TextInjector.isOurs(event) { return pass }
            return handleKey(event)
        default:
            return pass
        }
    }

    private func handleFlags(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime
        let others = flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate])
            .subtracting(hotkey.flag)
        guard hotkey.keyCodes.contains(Int(code)), others.isEmpty else {
            hotkeyClean = false
            lastTapUp = 0
            return
        }
        if flags.contains(hotkey.flag) {
            if hotkey.isDouble, now - lastTapUp < Self.doubleTapGap {
                lastTapUp = 0
                hotkeyClean = false
                DispatchQueue.main.async { self.onHotkey() }
                return
            }
            hotkeyDownAt = now
            hotkeyClean = true
        } else if hotkeyClean, now - hotkeyDownAt < Self.tapLength {
            hotkeyClean = false
            if hotkey.isDouble {
                lastTapUp = now
            } else {
                DispatchQueue.main.async { self.onHotkey() }
            }
        }
    }

    private func handleKey(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        hotkeyClean = false
        lastTapUp = 0

        guard isActive(), !IsSecureEventInputEnabled() else {
            // Поле пароля или выключено: ничего не запоминаем.
            session.reset()
            return pass
        }
        if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            session.reset(keepContext: true)
            return pass
        }

        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete:
            session.backspace()
            return pass
        case kVK_Space:
            return boundary(" ", event)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return boundary("\n", event)
        case kVK_Tab:
            return boundary("\t", event)
        case kVK_Escape, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            session.reset(keepContext: true)
            return pass
        default:
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            let text = String(utf16CodeUnits: buffer, count: length)
            let printable = !text.isEmpty && !text.unicodeScalars.contains {
                $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) // управляющие и F-клавиши
            }
            if printable { session.type(text) } else { session.reset(keepContext: true) }
            return pass
        }
    }

    private func boundary(_ separator: Character, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let edit = session.boundary(separator) else { return Unmanaged.passUnretained(event) }
        // Разделитель придержали: сначала исправляем слово, потом допечатываем его сами.
        TextInjector.apply(edit)
        if let copy = event.copy() { TextInjector.post(copy) }
        onEdit(edit)
        return nil
    }
}

private func keyboardCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type, event)
}
