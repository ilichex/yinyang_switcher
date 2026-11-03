// swift-tools-version: 5.10
import PackageDescription

// Без Xcode Swift Testing лежит в Command Line Tools, и SwiftPM его сам не находит.
let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "YinYangSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(
            name: "YinYangSwitcher",
            dependencies: ["SwitcherCore"]
        ),
        // Тесты собраны как программа: без Xcode `swift test` их не запускает.
        // Запуск: swift run core-tests
        .executableTarget(
            name: "core-tests",
            dependencies: ["SwitcherCore"],
            path: "Tests/SwitcherCoreTests",
            swiftSettings: [.unsafeFlags(["-F", testingFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", testingFrameworks, "-framework", "Testing",
                "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", testingLibs,
            ])]
        ),
    ]
)
