#!/bin/bash
# Собирает build/YinYang.dmg: внутри приложение и ярлык «Программы» —
# установка перетаскиванием, как у обычных программ.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build-app.sh

STAGE=build/dmg
DMG=build/YinYang.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/YinYang.app "$STAGE/"
ln -s /Applications "$STAGE/Программы"

hdiutil create -volname "Инь-Ян" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Готово: $DMG ($(du -h "$DMG" | cut -f1))"
