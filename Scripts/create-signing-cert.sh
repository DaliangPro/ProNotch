#!/bin/bash
# 创建 ProNotch 发版/安装用的「固定自签名代码签名证书」。
# 目的：签名身份恒定，朋友首次授权后，后续更新免重新授权（macOS 隐私授权按签名身份记忆，
# 而 ad-hoc 临时签名每次改代码 cdhash 都变、被当成另一个 App）。
# 私钥仅存本机登录钥匙串，一次性执行；换机、或他人要自己发版时才需再跑。
set -euo pipefail

CERT_NAME="ProNotch Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 证书已存在，无需重复创建：$CERT_NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 自签名证书需带「代码签名」用途（extendedKeyUsage=codeSigning），否则 codesign 不认
cat > "$TMP/cert.cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ProNotch Local Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass: -name "$CERT_NAME" >/dev/null 2>&1

# -A 允许本机各工具使用该私钥，减少后续签名弹框
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A

echo "✅ 已创建固定自签名代码签名证书：$CERT_NAME"
echo "   首次用它签名时若弹「codesign 想使用钥匙串中的私钥」，点【始终允许】即可（仅一次）。"
security find-identity -p codesigning -v | grep "$CERT_NAME" || true
