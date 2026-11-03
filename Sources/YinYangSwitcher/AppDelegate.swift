import AppKit
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
    private var permissionTimer: Timer?

    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YinYang", isDirectory: true)
        .appendingPathComponent("learning.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            session.reset()
        }

        monitor.hotkey = context.hotkey
        monitor.isActive = { [unowned self] in context.isActive }
        monitor.onEdit = { [unowned self] edit in
            if let lang = edit.switchTo { sources.select(lang) }
            icon.spin()
        }
        monitor.onHotkey = { [unowned self] in hotkey() }

        startWhenPermitted()
        updater.start()
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
        if AXIsProcessTrustedWithOptions(options), monitor.start() { return }
        // Ждём, пока пользователь выдаст доступ в Системных настройках.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] timer in
            if AXIsProcessTrusted(), monitor.start() {
                timer.invalidate()
                permissionTimer = nil
            }
        }
    }

    // MARK: - Клавиша ручного исправления (по умолчанию двойной Shift)

    /// 1) сразу после автозамены — отменить её;
    /// 2) есть выделение — умно инвертировать выделенное;
    /// 3) иначе — инвертировать последнее слово.
    /// Каждое ручное действие — голос в обучение: два раза — и слово запомнено.
    private func hotkey() {
        guard context.isActive else { return }
        if let (edit, fix) = session.undoLastFix() {
            TextInjector.apply(edit)
            if let lang = edit.switchTo { sources.select(lang) }
            for change in fix.changes { vote(change.key, change.from) }
            icon.spin()
            return
        }
        switch SelectionReader.viaAccessibility() {
        case .text(let selection) where !selection.isEmpty:
            convertSelection(selection)
        case .text:
            if !invertLastWord() { NSSound.beep() }
        case .unsupported:
            // Только что набранное слово важнее: ⌘C без выделения в некоторых
            // редакторах копирует всю строку.
            if invertLastWord() { return }
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
        session.reset(keepContext: true)
        icon.spin()
    }

    private func invertLastWord() -> Bool {
        guard let (edit, change) = session.invertLastWord() else { return false }
        TextInjector.apply(edit)
        if let lang = edit.switchTo { sources.select(lang) }
        vote(change.key, change.to)
        icon.spin()
        return true
    }

    private func vote(_ key: String, _ lang: Lang) {
        store.vote(key: key, lang: lang, app: context.bundleID, category: context.category)
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sources.reload()

        let title = NSMenuItem(title: "Инь-Ян \(updater.current) · свитчер раскладки", action: nil, keyEquivalent: "")
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

        let enabled = item("Исправлять раскладку", #selector(toggleEnabled))
        enabled.state = context.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(hotkeyItem())
        menu.addItem(.separator())

        if !context.bundleID.isEmpty {
            menu.addItem(disabled("Сейчас: \(context.appName)"))
            let categoryItem = NSMenuItem(title: "Тип: \(context.category.title)", action: nil, keyEquivalent: "")
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
        let root = NSMenuItem(title: "Исправить вручную: \(context.hotkey.shortTitle)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(disabled("Клавиша"))
        for hotkey in Hotkey.allCases {
            let h = item(hotkey.title, #selector(setHotkey(_:)))
            h.representedObject = hotkey.rawValue
            h.state = hotkey == context.hotkey ? .on : .off
            submenu.addItem(h)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("Что она делает"))
        submenu.addItem(disabled("Только что исправилось само — отменяет"))
        submenu.addItem(disabled("Выделен текст — исправляет выделенное"))
        submenu.addItem(disabled("Иначе — исправляет последнее слово"))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Исправите одно слово дважды — оно запомнится"))
        root.submenu = submenu
        return root
    }

    private func rulesItem() -> NSMenuItem {
        let rules = store.rules
        let root = NSMenuItem(title: "Выученные слова (\(Set(rules.map(\.key)).count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if rules.isEmpty {
            submenu.addItem(disabled("Пока пусто. Исправьте слово двойным ⇧ два раза — и оно запомнится."))
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

    @objc private func setHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let hotkey = Hotkey(rawValue: raw) else { return }
        context.hotkey = hotkey
        monitor.hotkey = hotkey
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
