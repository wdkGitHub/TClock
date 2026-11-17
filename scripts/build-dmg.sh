#!/bin/bash
# TClock DMG 打包脚本：本地与 GitHub Actions 共用。
#
# 用法：
#   scripts/build-dmg.sh [输出目录]          # 默认 <仓库>/dist
#
# 可覆盖的环境变量：
#   TCLOCK_VERSION         DMG 文件名中的版本号（默认读构建产物 Info.plist）
#   TCLOCK_CONFIGURATION   构建配置，默认 Release
#   TCLOCK_DERIVED_DATA    中间产物目录，默认 <仓库>/.build/dmg
#   GITHUB_OUTPUT          若存在，写入 version / build / dmg / dmg_name / sha256
#
# 产物：
#   TClock-<version>.dmg   含 TClock.app 与 /Applications 快捷方式的压缩 DMG
#   SHA256SUMS.txt         DMG 的 sha256 校验和
#
# 说明：工程使用临时签名（CODE_SIGN_IDENTITY = "-"），未做公证。
# 用户首次打开下载的 DMG 时，需要在「系统设置 › 隐私与安全性」里允许，
# 或执行 xattr -dr com.apple.quarantine /Applications/TClock.app。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/TClock.xcodeproj"
SCHEME="TClock"
CONFIG="${TCLOCK_CONFIGURATION:-Release}"
OUT_DIR="${1:-$ROOT/dist}"
WORK_DIR="${TCLOCK_DERIVED_DATA:-$ROOT/.build/dmg}"
APP_NAME="TClock.app"
STAGE="$WORK_DIR/stage"

mkdir -p "$OUT_DIR" "$WORK_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> [1/5] xcodebuild ${CONFIG}（arm64 + x86_64 通用二进制）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$WORK_DIR/derived" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  build

APP="$WORK_DIR/derived/Build/Products/$CONFIG/$APP_NAME"
if [[ ! -d "$APP/Contents/MacOS" ]]; then
  echo "错误：找不到构建产物 $APP" >&2
  exit 1
fi

echo "==> [2/5] 签名与版本"
# 保留 Xcode 写入的 entitlements，再用临时签名统一整包签名。
if ! codesign --force --deep --preserve-metadata=entitlements --sign - "$APP" 2>/dev/null; then
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

VERSION="${TCLOCK_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
echo "    TClock ${VERSION} (${BUILD_NUMBER})"

echo "==> [3/5] 生成 DMG"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT_DIR/TClock-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "TClock ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" | sed 's/^/    /'

echo "==> [4/5] 挂载校验 DMG"
MOUNT="$WORK_DIR/verify-mount"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
if [[ ! -x "$MOUNT/$APP_NAME/Contents/MacOS/TClock" ]]; then
  echo "错误：DMG 内缺少可执行的 TClock.app" >&2
  hdiutil detach "$MOUNT" -quiet || true
  exit 1
fi
hdiutil detach "$MOUNT" -quiet

echo "==> [5/5] 校验和"
CHECKSUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s  %s\n' "$CHECKSUM" "$(basename "$DMG")" > "$OUT_DIR/SHA256SUMS.txt"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$VERSION"
    echo "build=$BUILD_NUMBER"
    echo "dmg=$DMG"
    echo "dmg_name=$(basename "$DMG")"
    echo "sha256=$CHECKSUM"
  } >> "$GITHUB_OUTPUT"
fi

echo ""
echo "完成："
echo "  $DMG"
echo "  sha256 $CHECKSUM"
echo "  $OUT_DIR/SHA256SUMS.txt"
