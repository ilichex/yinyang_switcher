import AppKit
import Carbon
import ServiceManagement
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let context = AppContext()
    private let sources = InputSources()
    private lazy var detector = Detector(map: sources.map, scorer: Scorer(spell: SystemSpellChecker()))
    private lazy var session = TypingSession(detector: detector)
    private lazy var smart = SmartConverter(detector: detector)
    private lazy var monitor = KeyboardMonitor(session: session)
    private let store = LearningStore(url: AppDelegate.storageURL)
    private let updater = Updater()

    private var statusItem: NSStatusItem!
    private var icon: StatusIcon!
    private var healthTimer: Timer?

    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YinYang", isDirectory: true)
        .appendingPathComponent("learning.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Две копии (из DMG и из «Программ») исправляли бы каждое слово дважды.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if let running = others.first {
            running.activate()
            NSApp.terminate(nil)
            return
        }

        // Новые значки macOS ставит левее всех, и на MacBook с вырезом в полной строке
        // меню они прячутся под ним. При первом запуске просим место ближе к часам;
        // дальше macOS запоминает, куда пользователь перетащил значок с ⌘.
        let positionKey = "NSStatusItem Preferred Position YinYang"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(Self.preferredPosition, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "YinYang"
        icon = StatusIcon(button: statusItem.button!)
        icon.dimmed = !context.enabled
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        context.update(NSWorkspace.shared.frontmostApplication)
        session.category = context.category
        session.learned = { [unowned self] key in
            store.verdict(key: key, app: context.bundleID, category: context.category)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [unowned self] note in
            context.update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            session.category = context.category
        }

        monitor.hotkey = context.hotkey
        monitor.isActive = { [unowned self] in context.isActive && sources.currentIsSupported }
        monitor.onEdit = { [unowned self] edit in
            if let lang = edit.switchTo { sources.select(lang) }
            icon.spin()
        }
        monitor.onHotkey = { [unowned self] in hotkey() }
        // По умолчанию ⌥⌘ — быстро выключить и включить обратно, не открывая меню.
        monitor.toggle = context.toggleShortcut
        monitor.onToggle = { [unowned self] in toggleEnabled() }
        icon.shortcutTitle = context.toggleShortcut?.title

        // Первое обращение к словарям macOS долгое (до секунды). Случись оно внутри перехвата,
        // буквы следующего слова проскочили бы мимо, а правка стёрла бы не то.
        for word in ["ghbdtn", "руддщ"] { _ = detector.decide(word, context: DetectionContext()) }

        startWhenPermitted()
        updater.start()
    }

    /// Другой свитчер исправлял бы те же слова повторно, и они «прыгали» бы туда-обратно.
    private static func rivalSwitcher() -> String? {
        NSWorkspace.shared.runningApplications.lazy.compactMap(\.localizedName)
            .first { name in ["Punto Switcher", "Caramba"].contains { name.localizedCaseInsensitiveContains($0) } }
    }

    /// Расстояние от правого края экрана, точки.
    private static let preferredPosition = 260

    /// Повторный запуск (двойной клик в «Программах», Spotlight) открывает меню у курсора —
    /// на случай, если значок не поместился в строку меню.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    // MARK: - Разрешения

    private func startWhenPermitted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        checkHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in
            checkHealth()
        }
    }

    /// Раз в 2 секунды: доступ выдали — включаем перехват; macOS его выключила — включаем
    /// обратно; доступ отозвали — снимаем перехват, чтобы не мешать клавиатуре.
    private func checkHealth() {
        if AXIsProcessTrusted() {
            if monitor.isStarted { monitor.ensureEnabled() } else { monitor.start() }
        } else if monitor.isStarted {
            monitor.stop()
        }
    }

    // MARK: - Клавиша ручного исправления (по умолчанию двойной Shift)

    /// 1) только что исправлено (само или вручную) — вернуть как было; следующее нажатие
    ///    снова исправит, и так сколько угодно, пока вы не продолжили печатать;
    /// 2) есть выделение — умно исправить выделенное;
    /// 3) иначе — исправить набранную фразу: только слова, похожие на набранные не в той
    ///    раскладке; если таких нет — поменять раскладку последнего слова.
    /// Каждое ручное действие — голос в обучение: два раза — и слово запомнено.
    private func hotkey() {
        // В поле пароля ничего не печатаем и буфер обмена не трогаем.
        guard context.isActive, !IsSecureEventInputEnabled() else { return }
        // С последнего нажатия переключились в другую программу — её текста мы не знаем.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, Int64(front) != monitor.lastTarget {
            session.reset()
        }
        if let (planned, fix) = session.undoLastFix() {
            guard let edit = TextInjector.checked(planned) else { return mismatch() }
            TextInjector.apply(edit)
            if let lang = edit.switchTo { sources.select(lang) }
            // Голос — только за первую отмену; дальше это просто переключение туда-обратно.
            if !fix.isRepeat {
                for change in fix.changes { vote(change.key, change.from) }
            }
            icon.spin()
            return
        }
        switch SelectionReader.viaAccessibility() {
        case .text(let selection) where !selection.isEmpty:
            convertSelection(selection)
        case .text:
            if !convertTyped() { NSSound.beep() }
        case .unsupported:
            // Только что набранное важнее: ⌘C без выделения в некоторых
            // редакторах копирует всю строку.
            if convertTyped() { return }
            SelectionReader.viaClipboard { [self] selection in
                if let selection { convertSelection(selection) } else { NSSound.beep() }
            }
        }
    }

    private func convertSelection(_ selection: String) {
        guard let result = smart.convert(selection, category: context.category, learned: session.learned) else {
            return NSSound.beep()
        }
        TextInjector.type(result.text)
        if let lang = result.lang { sources.select(lang) }
        for change in result.changes { vote(change.key, change.to) }
        // Запоминаем замену: следующее нажатие вернёт как было, выделять заново не нужно.
        session.replacedSelection(selection, with: result.text, changes: result.changes, lang: result.lang)
        icon.spin()
    }

    /// Набранное без выделения: сначала вся фраза, потом последнее слово. false — менять нечего.
    private func convertTyped() -> Bool {
        // Память могла разойтись с экраном (клик в другое место, замена от macOS) — сверяемся,
        // если программа отвечает. В терминалах и редакторах кода курсор для Accessibility
        // бывает не там, где ввод, — там верим только памяти.
        if context.category != .code, let line = SelectionReader.textBeforeCursor(TypingSession.maxLength) {
            session.sync(withScreen: line)
        }
        if let (planned, changes) = session.convertPhrase(smart) {
            guard let edit = TextInjector.checked(planned) else {
                mismatch()
                return true
            }
            TextInjector.apply(edit)
            if let lang = edit.switchTo { sources.select(lang) }
            for change in changes { vote(change.key, change.to) }
            icon.spin()
            return true
        }
        return invertLastWord()
    }

    private func invertLastWord() -> Bool {
        guard let (planned, change) = session.invertLastWord() else { return false }
        guard let edit = TextInjector.checked(planned) else {
            mismatch()
            return true
        }
        TextInjector.apply(edit)
        if let lang = edit.switchTo { sources.select(lang) }
        vote(change.key, change.to)
        icon.spin()
        return true
    }

    /// На экране не то, что мы помним: стирать вслепую нельзя.
    private func mismatch() {
        session.reset(keepContext: true)
        NSSound.beep()
    }

    private func vote(_ key: String, _ lang: Lang) {
        store.vote(key: key, lang: lang, app: context.bundleID, category: context.category)
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sources.reload()

        let title = NSMenuItem(title: "YinYang \(updater.current) · свитчер раскладки", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if case .available(let version, _) = updater.state {
            menu.addItem(item("⬆︎ Обновить до \(version)", #selector(installUpdate)))
        }

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠️ Выдать доступ «Универсальный доступ»…", #selector(openAccessibilitySettings)))
        } else if !monitor.isRunning {
            menu.addItem(disabled("⚠️ Перехват клавиатуры не запущен"))
        }
        if !sources.isReady {
            menu.addItem(disabled("⚠️ Включите русскую и английскую раскладки"))
        }
        if let rival = Self.rivalSwitcher() {
            menu.addItem(disabled("⚠️ Запущен \(rival) — выключите один из свитчеров"))
        }

        let enabled = item("Исправлять раскладку", #selector(toggleEnabled))
        enabled.state = context.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(toggleItem())
        menu.addItem(hotkeyItem())
        menu.addItem(.separator())

        if !context.bundleID.isEmpty {
            menu.addItem(disabled("Сейчас: \(context.appName)"))
            let categoryItem = NSMenuItem(title: "Текущий режим: \(context.category.title)", action: nil, keyEquivalent: "")
            let categories = NSMenu()
            for category in AppCategory.allCases {
                let c = item(category.title, #selector(setCategory(_:)))
                c.representedObject = category.rawValue
                c.state = category == context.category ? .on : .off
                categories.addItem(c)
            }
            categoryItem.submenu = categories
            menu.addItem(categoryItem)
            let skip = item("Не исправлять в \(context.appName)", #selector(toggleApp))
            skip.state = context.disabledApps.contains(context.bundleID) ? .on : .off
            menu.addItem(skip)
            menu.addItem(.separator())
        }

        menu.addItem(rulesItem())
        menu.addItem(.separator())
        let login = item("Запускать при входе", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(updatesItem())
        menu.addItem(item("Выйти", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func updatesItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Обновления", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let reason = updater.unavailableReason {
            submenu.addItem(disabled(reason))
        } else {
            switch updater.state {
            case .checking: submenu.addItem(disabled("Проверяю…"))
            case .installing(let version): submenu.addItem(disabled("Ставлю версию \(version)…"))
            case .upToDate: submenu.addItem(disabled("У вас последняя версия"))
            case .failed(let message): submenu.addItem(disabled(message))
            case .idle, .available: break
            }
            submenu.addItem(item("Проверить сейчас", #selector(checkForUpdates)))
            let auto = item("Обновлять автоматически", #selector(toggleAutoUpdate))
            auto.state = updater.automatic ? .on : .off
            submenu.addItem(auto)
        }
        root.submenu = submenu
        return root
    }

    private func hotkeyItem() -> NSMenuItem {
        let current = context.hotkey
        let root = NSMenuItem(title: "Исправить вручную: \(current.title)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(disabled("Клавиша"))
        var keys = Hotkey.presets
        if !keys.contains(where: { $0.keyCodes == current.keyCodes }) {
            keys.append((current.keyTitle, current.keyCodes))
        }
        for key in keys {
            let k = item(key.title, #selector(setHotkeyKey(_:)))
            k.representedObject = key.keyCodes.sorted()
            k.state = key.keyCodes == current.keyCodes ? .on : .off
            submenu.addItem(k)
        }
        submenu.addItem(item("Назначить свою…", #selector(recordHotkey)))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Нажатие"))
        for count in Hotkey.counts {
            let c = item(Hotkey.countTitle(count), #selector(setHotkeyCount(_:)))
            c.tag = count
            c.state = count == current.count ? .on : .off
            submenu.addItem(c)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("Что она делает"))
        submenu.addItem(disabled("Только что исправлено — возвращает; ещё раз — снова исправляет"))
        submenu.addItem(disabled("Выделен текст — исправляет выделенное"))
        submenu.addItem(disabled("Иначе — исправляет набранную фразу или последнее слово"))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Исправите одно слово дважды — оно запомнится"))
        root.submenu = submenu
        return root
    }

    private func toggleItem() -> NSMenuItem {
        let current = context.toggleShortcut
        let root = NSMenuItem(title: "Вкл/выкл сочетанием: \(current?.title ?? "не задано")", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        var choices = Shortcut.presets
        if let current, !choices.contains(where: { $0.shortcut == current }) {
            choices.append((current.title, current))
        }
        for choice in choices {
            let c = item(choice.title, #selector(setToggleShortcut(_:)))
            c.representedObject = [Int(choice.shortcut.modifiers), choice.shortcut.keyCode ?? -1]
            c.state = choice.shortcut == current ? .on : .off
            submenu.addItem(c)
        }
        submenu.addItem(item("Назначить своё…", #selector(recordToggleShortcut)))
        let off = item("Не использовать", #selector(setToggleShortcut(_:)))
        off.state = current == nil ? .on : .off
        submenu.addItem(off)
        submenu.addItem(.separator())
        submenu.addItem(disabled("У выключенного YinYang в строке меню — половина значка"))
        root.submenu = submenu
        return root
    }

    private func rulesItem() -> NSMenuItem {
        let rules = store.rules
        let root = NSMenuItem(title: "Выученные слова (\(Set(rules.map(\.key)).count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if rules.isEmpty {
            submenu.addItem(disabled("Пока пусто. Исправьте слово вручную два раза — и оно запомнится."))
        }
        for rule in rules.prefix(60) {
            let word: String
            switch rule.verdict {
            case .lang(let lang): word = sources.map.convert(rule.key, to: lang)
            case .unstable: word = "\(rule.key) / \(sources.map.convert(rule.key, to: .ru)) — не трогать"
            }
            let scope = rule.scope.hasPrefix("app:")
                ? AppContext.displayName(forBundleID: String(rule.scope.dropFirst(4)))
                : AppCategory(rawValue: String(rule.scope.dropFirst(4)))?.title ?? rule.scope
            let r = item("\(word) · \(scope)", #selector(forgetRule(_:)))
            r.representedObject = rule.key
            r.toolTip = "Нажмите, чтобы забыть это слово"
            submenu.addItem(r)
        }
        if !rules.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(item("Забыть всё", #selector(forgetAll)))
        }
        root.submenu = submenu
        return root
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        context.enabled.toggle()
        icon.dimmed = !context.enabled
        session.reset()
    }

    @objc private func toggleApp() {
        var apps = context.disabledApps
        if apps.remove(context.bundleID) == nil { apps.insert(context.bundleID) }
        context.disabledApps = apps
        session.reset()
    }

    @objc private func setCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let category = AppCategory(rawValue: raw) else { return }
        context.setCategory(category, for: context.bundleID)
        session.category = category
    }

    private func setHotkey(_ hotkey: Hotkey) {
        context.hotkey = hotkey
        monitor.hotkey = hotkey
    }

    @objc private func setHotkeyKey(_ sender: NSMenuItem) {
        guard let codes = sender.representedObject as? [Int] else { return }
        setHotkey(Hotkey(keyCodes: Set(codes), count: context.hotkey.count))
    }

    @objc private func setHotkeyCount(_ sender: NSMenuItem) {
        setHotkey(Hotkey(keyCodes: context.hotkey.keyCodes, count: sender.tag))
    }

    private func setToggle(_ shortcut: Shortcut?) {
        context.toggleShortcut = shortcut
        monitor.toggle = shortcut
        icon.shortcutTitle = shortcut?.title
    }

    @objc private func setToggleShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? [Int], raw.count == 2 else { return setToggle(nil) }
        setToggle(Shortcut(modifiers: UInt64(raw[0]), keyCode: raw[1] < 0 ? nil : raw[1]))
    }

    @objc private func recordToggleShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard monitor.isRunning else {
            alert.messageText = "Сначала выдайте доступ «Универсальный доступ»"
            alert.runModal()
            return
        }
        alert.messageText = "Нажмите сочетание"
        alert.informativeText = """
            Модификаторы вместе — например ⌥⌘ или ⌃⇧ (нажать и отпустить), \
            или клавиша с ⌘ или ⌃ — например ⌃⌥Y. F-клавиши можно и без модификаторов.

            Esc — отмена.
            """
        alert.addButton(withTitle: "Отмена")
        monitor.onRecordShortcut = { [unowned self] shortcut in
            guard let shortcut else { return NSApp.abortModal() }
            guard shortcut.isAllowed else { return NSSound.beep() }
            setToggle(shortcut)
            NSApp.abortModal()
        }
        alert.runModal()
        monitor.onRecordShortcut = nil
    }

    /// Ждёт нажатия клавиши и назначает её. Нажатия ловит перехват клавиатуры,
    /// поэтому без доступа «Универсальный доступ» назначить нельзя.
    @objc private func recordHotkey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard monitor.isRunning else {
            alert.messageText = "Сначала выдайте доступ «Универсальный доступ»"
            alert.runModal()
            return
        }
        alert.messageText = "Нажмите клавишу"
        alert.informativeText = """
            Подойдёт модификатор — ⇧ Shift, ⌃ Control, ⌥ Option, ⌘ Command (левый или правый), fn — \
            или F-клавиша. Буквы и цифры не подходят: они печатают текст.

            Esc — отмена.
            """
        alert.addButton(withTitle: "Отмена")
        monitor.onRecord = { [unowned self] code in
            if code == kVK_Escape { return NSApp.abortModal() }
            guard Hotkey.isAllowed(code) else { return NSSound.beep() }
            setHotkey(Hotkey(keyCodes: [code], count: context.hotkey.count))
            NSApp.abortModal()
        }
        alert.runModal()
        monitor.onRecord = nil
    }

    @objc private func installUpdate() {
        updater.install()
    }

    @objc private func checkForUpdates() {
        updater.check(manual: true)
    }

    @objc private func toggleAutoUpdate() {
        updater.automatic.toggle()
    }

    @objc private func forgetRule(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { store.remove(key: key) }
    }

    @objc private func forgetAll() {
        store.removeAll()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не получилось включить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
