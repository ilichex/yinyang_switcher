#!/bin/bash
# Нативные проверки без глобальных нажатий и доступа к личному буферу обмена.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product YinYangSwitcher
BIN_DIR="$(swift build --show-bin-path)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yinyang-keyboard-checks.XXXXXX")"

swiftc -I "$BIN_DIR/Modules" -module-cache-path "$CHECK_DIR/cache" \
    "$BIN_DIR"/SwitcherCore.build/*.swift.o \
    Sources/YinYangSwitcher/KeyboardMonitor.swift \
    Sources/YinYangSwitcher/Hotkey.swift \
    Sources/YinYangSwitcher/TextInjector.swift \
    Sources/YinYangSwitcher/SelectionReader.swift \
    Tests/KeyboardIntegrationChecks/main.swift \
    -o "$CHECK_DIR/keyboard-checks"

"$CHECK_DIR/keyboard-checks"
