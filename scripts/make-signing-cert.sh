#!/bin/bash
# Создаёт бесплатный самоподписанный сертификат «YinYang» для подписи сборок.
#
# Зачем: macOS выдаёт «Универсальный доступ» конкретной подписи. Пока все версии
# подписаны одним сертификатом, доступ переживает пересборки и обновления.
# Gatekeeper такой сертификат не признаёт — первый запуск всё равно через
# «Всё равно открыть», — но для обновлений это и не нужно.
#
# Файлы кладутся в ~/.yinyang-signing (не в репозиторий!). Потеряете их — следующая
# версия будет подписана другим сертификатом, и доступ придётся выдать заново.
set -euo pipefail

DIR="${YINYANG_SIGNING_DIR:-$HOME/.yinyang-signing}"
if [ -f "$DIR/signing.p12" ]; then
    echo "Сертификат уже есть: $DIR/signing.p12"
    exit 0
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = YinYang
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
PASSWORD=$(openssl rand -hex 16)
# -legacy: иначе `security import` не прочитает файл.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name YinYang -out signing.p12 -passout "pass:$PASSWORD"
echo -n "$PASSWORD" > password.txt
rm key.pem cert.cnf
chmod 600 ./*

echo "Готово: $DIR/signing.p12"
echo
echo "Для GitHub (Settings → Secrets and variables → Actions → New repository secret):"
echo "  SIGNING_P12          — вывод: base64 -i $DIR/signing.p12 | pbcopy"
echo "  SIGNING_P12_PASSWORD — вывод: pbcopy < $DIR/password.txt"
