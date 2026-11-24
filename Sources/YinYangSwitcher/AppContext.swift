import AppKit
import SwitcherCore

/// Активная программа и настройки пользователя.
final class AppContext {
    private(set) var bundleID = ""
    private(set) var appName = ""

    private let defaults = UserDefaults.standard

    var automaticCorrectionEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Мгновенное переключение раскладки по fn (🌐). Работает, только если сама система
    /// на эту клавишу ничего не делает.
    var globeSwitch: Bool {
        get { defaults.object(forKey: "globeSwitch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "globeSwitch") }
    }

    var disabledApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "disabledApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "disabledApps") }
    }

    var hotkey: Hotkey {
        get { Hotkey(defaults: defaults) }
        set { newValue.save(to: defaults) }
    }

    /// Сочетание «включить/выключить»; nil — пользователь его отключил.
    var toggleShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "toggleOff") { return nil }
            guard let modifiers = defaults.object(forKey: "toggleModifiers") as? Int else { return .defaultToggle }
            let shortcut = Shortcut(modifiers: UInt64(modifiers), keyCode: defaults.object(forKey: "toggleKey") as? Int)
            return shortcut.isAllowed ? shortcut : .defaultToggle
        }
        set {
            defaults.set(newValue == nil, forKey: "toggleOff")
            guard let newValue else { return }
            defaults.set(Int(newValue.modifiers), forKey: "toggleModifiers")
            defaults.set(newValue.keyCode, forKey: "toggleKey")
        }
    }

    var isActive: Bool { !isNeverApp && !disabledApps.contains(bundleID) }

    // Поиск приложений может отдать устаревший текст сразу после ввода.
    var usesTrackedText: Bool {
        bundleID == "com.apple.dock" || bundleID == "com.apple.apps.launcher"
    }

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
    }

    static func displayName(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
