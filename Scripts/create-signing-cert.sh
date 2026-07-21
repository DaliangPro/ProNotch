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

# 只授权 codesign 使用该私钥。
# 原先带 -A：那是「本机任意程序都能拿这把私钥签名」——任何跑在你账号下的进程
# （包括随手装的一个脚本、一个 npm 包）都能签出一个「ProNotch Local Signing」的 App。
# 而这个签名身份正是 macOS 记忆隐私授权的依据：伪造它，就能继承 ProNotch 已获得的
# 录屏、辅助功能等授权。省下的那点弹框远不值这个代价。
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

# 分区列表限定在签名链路必需的几项，替代 -A 来免除重复弹框。
# 这一步会弹一次钥匙串密码框：密码交给系统对话框，不进脚本、不进 shell 历史
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -l "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "⚠️  私钥分区列表未能自动设置（多半是取消了密码框）。"
    echo "   不影响签名，只是首次签名时会多弹一次「codesign 想使用私钥」，点【始终允许】即可。"
fi

echo "✅ 已创建固定自签名代码签名证书：$CERT_NAME"
echo "   私钥仅授权给 /usr/bin/codesign，不对本机其它程序开放。"
echo "   首次用它签名时若弹「codesign 想使用钥匙串中的私钥」，点【始终允许】即可（仅一次）。"
security find-identity -p codesigning -v | grep "$CERT_NAME" || true
