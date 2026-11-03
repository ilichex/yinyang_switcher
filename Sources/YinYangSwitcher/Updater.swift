import AppKit
import Security
import SwitcherCore

/// Обновления из GitHub Releases. Раз в сутки смотрит последний релиз; если версия новее,
/// скачивает YinYang.zip, проверяет, что приложение внутри подписано тем же сертификатом,
/// что и текущее, ставит его на место текущего и перезапускается.
///
/// Тот же сертификат — это и защита от подмены файла в релизе, и условие, при котором
/// macOS сохраняет выданный «Универсальный доступ». Всё состояние меняется на главном потоке.
final class Updater {
    enum State {
        case idle, checking, upToDate
        case available(AppVersion, URL)
        case installing(AppVersion)
        case failed(String)
    }

    private(set) var state: State = .idle
    let current: AppVersion
    private let repository: String?
    private var timer: Timer?

    private static let assetName = "YinYang.zip"
    private static let interval: TimeInterval = 24 * 3600

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    init(bundle: Bundle = .main) {
        repository = bundle.object(forInfoDictionaryKey: "YYUpdateRepository") as? String
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = version.flatMap(AppVersion.init) ?? AppVersion("0")!
    }

    /// Почему обновления не работают, или nil, если работают.
    var unavailableReason: String? {
        if repository == nil { return "Обновления выключены: сборка без репозитория" }
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/")
            || !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "Перенесите «Инь-Ян» в «Программы», чтобы он обновлялся"
        }
        return nil
    }

    func start() {
        guard unavailableReason == nil else { return }
        // Не мешаем запуску: первая проверка — через полминуты.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// `manual` — пользователь сам нажал «Проверить»: ставим найденное сразу и говорим об ошибках.
    func check(manual: Bool = false) {
        guard unavailableReason == nil, let repository else { return }
        if case .checking = state { return }
        if case .installing = state { return }
        state = .checking
        Task { @MainActor in
            do {
                if let (version, url) = try await latestRelease(repository), version > current {
                    state = .available(version, url)
                    if automatic || manual { install() }
                } else {
                    state = .upToDate
                }
            } catch {
                fail("Не удалось проверить обновления: \(error.localizedDescription)", show: manual)
            }
        }
    }

    func install() {
        guard case .available(let version, let url) = state else { return }
        state = .installing(version)
        Task { @MainActor in
            do {
                let app = try await download(url)
                try verify(app, expected: version)
                try replaceSelf(with: app)
                relaunch()
            } catch {
                fail("Не удалось обновиться до \(version): \(error.localizedDescription)", show: true)
            }
        }
    }

    // MARK: - Шаги

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        let tagName: String
        let assets: [Asset]
    }

    private func latestRelease(_ repository: String) async throws -> (AppVersion, URL)? {
        // updateAPI — только для проверки обновлений на локальном сервере; подпись проверяется всё равно.
        let api = UserDefaults.standard.string(forKey: "updateAPI") ?? "https://api.github.com"
        var request = URLRequest(url: URL(string: "\(api)/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("YinYang/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 — релизов ещё нет.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard let version = AppVersion(release.tagName),
              let asset = release.assets.first(where: { $0.name == Self.assetName }) else { return nil }
        return (version, asset.browserDownloadUrl)
    }

    /// Скачивает и распаковывает архив, возвращает путь к YinYang.app внутри.
    private func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("архив не скачался") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YinYangUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(Self.assetName)
        try FileManager.default.moveItem(at: file, to: zip)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("архив повреждён")
        }
        return app
    }

    private func verify(_ app: URL, expected: AppVersion) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                .flatMap(AppVersion.init), version == expected else {
            throw UpdateError("в архиве не та программа")
        }
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other
        else { throw UpdateError("не удалось проверить подпись") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(other, flags, requirement) == errSecSuccess else {
            throw UpdateError("новая версия подписана другим сертификатом")
        }
    }

    private func replaceSelf(with app: URL) throws {
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
    }

    /// Запускает новую версию, когда эта завершится.
    private func relaunch() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                           Bundle.main.bundleURL.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private func fail(_ message: String, show: Bool) {
        state = .failed(message)
        guard show else { return }
        let alert = NSAlert()
        alert.messageText = "Обновление"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
