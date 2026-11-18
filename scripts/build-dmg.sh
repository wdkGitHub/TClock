#!/bin/bash
# TClock DMG 打包脚本：本地与 GitHub Actions 共用。
#
# 用法：
#   scripts/build-dmg.sh [输出目录]          # 默认 <仓库>/dist
#
# 版本规则：
#   完整版本 = MARKETING_VERSION（手动维护）+ "." + CURRENT_PROJECT_VERSION（CI 每次打包自增）
#   例：MARKETING_VERSION=1.0、CURRENT_PROJECT_VERSION=3 → 完整版本 1.0.3
#   完整版本会写入 Info.plist（CFBundleShortVersionString / CFBundleVersion）、
#   DMG 文件名与卷标，也是 Release tag 使用的版本号。
#
# 可覆盖的环境变量：
#   TCLOCK_VERSION        完整版本号（如 1.0.3）。CI 由工作流传入；
#                         不传则自动从 TClock.xcodeproj 的两个版本字段组合。
#   TCLOCK_CONFIGURATION   构建配置，默认 Release
#   TCLOCK_DERIVED_DATA    中间产物目录，默认 <仓库>/.build/dmg
#   GITHUB_OUTPUT          若存在，写入 version / full_version / base_version / build / dmg / dmg_name / sha256
#
# 产物：
#   TClock-<完整版本>.dmg   含 TClock.app 与 /Applications 快捷方式的压缩 DMG
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
PBX="$PROJECT/project.pbxproj"

mkdir -p "$OUT_DIR" "$WORK_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 从工程读取两个版本字段，组合出完整版本号。
BASE_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' "$PBX" | head -1)"
BUILD_NUMBER="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);/\1/p' "$PBX" | head -1)"
if [[ -z "$BASE_VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "错误：无法从 $PBX 读取 MARKETING_VERSION / CURRENT_PROJECT_VERSION" >&2
  exit 1
fi
COMPOSED_VERSION="${BASE_VERSION}.${BUILD_NUMBER}"
# CI 传入完整版本时以它为准（与 trigger 时读到的 build 一致），否则本地自动组合。
VERSION="${TCLOCK_VERSION:-$COMPOSED_VERSION}"

echo "==> [1/5] xcodebuild ${CONFIG}（arm64 + x86_64 通用二进制）"
# 通过命令行 build setting 覆盖，让 Info.plist 的版本字段等于完整版本（不改动工程文件）。
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$WORK_DIR/derived" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
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

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "错误：产物版本 ${PLIST_VERSION} 与期望的 ${VERSION} 不一致" >&2
  exit 1
fi
echo "    TClock ${VERSION}（version ${BASE_VERSION} · build ${BUILD_NUMBER}）"

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
    echo "full_version=$VERSION"
    echo "base_version=$BASE_VERSION"
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
