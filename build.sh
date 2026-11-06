#!/bin/bash
# Build RinKeys.app (universal: Mac chip Apple + Mac Intel) và file cài .dmg.
#   ./build.sh       → build/RinKeys.app
#   ./build.sh dmg   → build + build/RinKeys-X.Y.dmg
set -euo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")"

APP="build/RinKeys.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

echo "→ Đang build RinKeys ${VERSION}…"
xcrun swiftc --version 2>&1 | head -1
rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O \
    -target "${ARCH}-apple-macos14.0" \
    Sources/main.swift \
    -o "build/obj/RinKeys-${ARCH}" \
    -swift-version 5 -parse-as-library \
    -framework Cocoa -framework SwiftUI \
    -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework UniformTypeIdentifiers
done
lipo -create build/obj/RinKeys-arm64 build/obj/RinKeys-x86_64 -output "${APP}/Contents/MacOS/RinKeys"
cp Info.plist "${APP}/Contents/Info.plist"

# Icon app + icon thanh menu (đơn sắc, tự đổi theo nền sáng/tối)
iconutil -c icns assets/AppIcon.iconset -o "${APP}/Contents/Resources/AppIcon.icns"
cp assets/menubar/MenuBarIcon*.png "${APP}/Contents/Resources/"
# Ảnh QR ủng hộ (VietQR, lấy từ web phuocrin.com)
if [[ -f assets/donate-qr.png ]]; then cp assets/donate-qr.png "${APP}/Contents/Resources/donate-qr.png"; fi

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  echo "⚠ Ký ad-hoc (bản thử)."
  codesign --force --sign - --identifier com.phuocrin.rinkeys "${APP}"
else
  codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" \
    ${SIGN_KEYCHAIN:+--keychain "${SIGN_KEYCHAIN}"} \
    --identifier com.phuocrin.rinkeys "${APP}"
fi
codesign --verify --strict "${APP}"
codesign -d -r- "${APP}" 2>&1 | grep -i designated || true
echo "✓ Xong: ${APP}"

make_dmg() {
  DMG="build/RinKeys-${VERSION}.dmg"
  echo "→ Đang tạo file cài .dmg…"
  python3 -m venv build/.venv
  # Gói ngoài chạy không kèm khoá bí mật trong biến môi trường, và cố định phiên bản.
  env -u UPDATE_KEY -u P12_PASSWORD build/.venv/bin/pip install --quiet --disable-pip-version-check \
    "dmgbuild==1.6.7" "ds-store==1.3.3" "mac-alias==2.2.3"
  env -u UPDATE_KEY -u P12_PASSWORD build/.venv/bin/dmgbuild -s dmg_settings.py -D app="${APP}" "RinKeys" "${DMG}"
  echo "✓ File cài: ${DMG}"
}

# Gói cho bộ tự cập nhật trong app (.zip + chữ ký ed25519 .sig nếu có UPDATE_KEY).
make_update_zip() {
  ZIP="build/RinKeys-${VERSION}.zip"
  ditto -c -k --keepParent "${APP}" "${ZIP}"
  echo "✓ Gói cập nhật: ${ZIP}"
  if [[ -n "${UPDATE_KEY:-}" ]]; then
    env -u UPDATE_KEY -u P12_PASSWORD build/.venv/bin/pip install --quiet --disable-pip-version-check "cryptography==46.0.7"
    ZIP="${ZIP}" build/.venv/bin/python - <<'PY'
import base64, os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(os.environ["UPDATE_KEY"]))
path = os.environ["ZIP"]
open(path + ".sig", "w").write(base64.b64encode(key.sign(open(path, "rb").read())).decode())
PY
    echo "✓ Chữ ký gói cập nhật: ${ZIP}.sig"
  else
    echo "⚠ Không có UPDATE_KEY: gói cập nhật chưa được ký, app sẽ không tự cài gói này."
  fi
}

case "${1:-}" in
  dmg) make_dmg ;;
  release) make_dmg; make_update_zip ;;
esac
