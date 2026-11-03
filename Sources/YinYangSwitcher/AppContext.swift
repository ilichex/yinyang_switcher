import AppKit
import SwitcherCore

/// Активная программа, её категория и настройки пользователя.
final class AppContext {
    private(set) var bundleID = ""
    private(set) var appName = ""
    private(set) var category: AppCategory = .other

    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var disabledApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "disabledApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "disabledApps") }
    }

    var hotkey: Hotkey {
        get { Hotkey(defaults: defaults) }
        set { newValue.save(to: defaults) }
    }

    private var customCategories: [String: String] {
        get { defaults.dictionary(forKey: "appCategories") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "appCategories") }
    }

    /// Исправлять ли сейчас.
    var isActive: Bool { enabled && !isNeverApp && !disabledApps.contains(bundleID) }

    /// Там, где наши исправления попали бы не туда: виртуальные машины и удалённые столы
    /// (у гостевой системы своя раскладка), менеджеры паролей.
    var isNeverApp: Bool {
        Self.neverApps.contains(bundleID) || Self.neverPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static let neverApps: Set<String> = [
        "com.vmware.fusion", "org.virtualbox.app.VirtualBoxVM", "org.virtualbox.app.VirtualBox",
        "com.utmapp.UTM", "com.microsoft.rdc.macos", "com.apple.ScreenSharing",
        "com.teamviewer.TeamViewer", "com.p5sys.jump.mac.viewer", "com.realvnc.vncviewer",
        "com.anydesk.anydeskmacos", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    ]
    private static let neverPrefixes = ["com.parallels."]

    func update(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        bundleID = id
        appName = app.localizedName ?? id
        category = category(for: id)
    }

    func category(for bundleID: String) -> AppCategory {
        if let raw = customCategories[bundleID], let custom = AppCategory(rawValue: raw) { return custom }
        if let known = Self.knownApps[bundleID] { return known }
        if let match = Self.knownPrefixes.first(where: { bundleID.hasPrefix($0.prefix) }) { return match.category }
        return .other
    }

    func setCategory(_ category: AppCategory, for bundleID: String) {
        customCategories[bundleID] = category.rawValue
        if bundleID == self.bundleID { self.category = category }
    }

    static func displayName(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static let knownPrefixes: [(prefix: String, category: AppCategory)] = [
        ("com.jetbrains.", .code), ("com.google.Chrome", .browser), ("org.mozilla.", .browser),
    ]

    private static let knownApps: [String: AppCategory] = [
        // Код и терминал
        "com.apple.Terminal": .code, "com.googlecode.iterm2": .code, "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code, "dev.warp.Warp-Stable": .code, "com.apple.dt.Xcode": .code,
        "com.sublimetext.4": .code, "dev.zed.Zed": .code, "net.kovidgoyal.kitty": .code,
        "org.alacritty": .code, "com.mitchellh.ghostty": .code, "com.github.wez.wezterm": .code,
        "com.exafunction.windsurf": .code, "com.vscodium": .code,
        // Переписка
        "ru.keepcoder.Telegram": .chat, "com.tdesktop.Telegram": .chat, "net.whatsapp.WhatsApp": .chat,
        "com.tinyspeck.slackmacgap": .chat, "com.apple.MobileSMS": .chat, "com.hnc.Discord": .chat,
        "com.viber.osx": .chat, "com.microsoft.teams2": .chat, "com.apple.mail": .chat,
        // Документы
        "com.apple.Notes": .docs, "com.apple.TextEdit": .docs, "com.apple.iWork.Pages": .docs,
        "com.microsoft.Word": .docs, "md.obsidian": .docs, "notion.id": .docs,
        // Браузеры
        "com.apple.Safari": .browser, "company.thebrowser.Browser": .browser,
        "ru.yandex.desktop.yandex-browser": .browser, "com.microsoft.edgemac": .browser,
    ]
}
