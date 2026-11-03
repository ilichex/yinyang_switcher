#!/bin/bash
# Подписывает приложение: scripts/sign.sh build/YinYang.app
#
# Сертификат берётся из SIGNING_P12 (файл) + SIGNING_P12_PASSWORD — так в GitHub Actions,
# иначе из ~/.yinyang-signing (scripts/make-signing-cert.sh). Если его нет — подпись ad-hoc:
# работает, но после каждой пересборки доступ придётся выдавать заново, и такая
# сборка не умеет обновляться (обновление должно быть подписано тем же сертификатом).
set -euo pipefail
APP="$1"

DIR="${YINYANG_SIGNING_DIR:-$HOME/.yinyang-signing}"
P12="${SIGNING_P12:-$DIR/signing.p12}"
if [ ! -f "$P12" ]; then
    codesign --force --sign - "$APP"
    echo "Сертификата нет — подпись ad-hoc (см. scripts/make-signing-cert.sh)."
    exit 0
fi
PASSWORD="${SIGNING_P12_PASSWORD:-$(cat "$DIR/password.txt")}"

# Временная связка ключей только для подписи; основную связку не трогаем.
TMP=$(mktemp -d)
KEYCHAIN="$TMP/signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
eval "SEARCH_LIST=($(security list-keychains -d user))"
cleanup() {
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    security list-keychains -d user -s "${SEARCH_LIST[@]}"
    rm -rf "$TMP"
}
trap cleanup EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# codesign ищет ключ только в списке связок; на время подписи добавляем, cleanup вернёт как было.
security list-keychains -d user -s "${SEARCH_LIST[@]}" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Самоподписанному сертификату система не доверяет, поэтому ищем его по отпечатку, а не по имени.
IDENTITY=$(security find-identity "$KEYCHAIN" | awk '/YinYang/ { print $2; exit }')
codesign --force --sign "$IDENTITY" "$APP"
echo "Подписано сертификатом «YinYang»."
