#!/bin/bash
# Собирает build/YinYang.app. Xcode не нужен — хватает Command Line Tools.
#
# Подпись — scripts/sign.sh: сертификатом «YinYang», если он есть (см. README),
# и тогда macOS не сбрасывает разрешения после пересборки и обновлений.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product YinYangSwitcher

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .

APP=build/YinYang.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${UNIVERSAL:-0}" = 1 ]; then
    # Для раздачи: один файл для Apple Silicon и Intel.
    swift build -c release --product YinYangSwitcher --triple x86_64-apple-macosx14.0
    lipo -create .build/arm64-apple-macosx/release/YinYangSwitcher \
        .build/x86_64-apple-macosx/release/YinYangSwitcher -output "$APP/Contents/MacOS/YinYang"
else
    cp .build/release/YinYangSwitcher "$APP/Contents/MacOS/YinYang"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Версия: VERSION, иначе последний тег git, иначе как в Info.plist.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
PLIST="$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$PLIST"
fi
# Откуда брать обновления: в GitHub Actions — текущий репозиторий, локально — origin.
REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##' || true)}"
if [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    /usr/libexec/PlistBuddy -c "Add :YYUpdateRepository string $REPO" "$PLIST"
fi

./scripts/sign.sh "$APP"

echo "Готово: $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST"))"
