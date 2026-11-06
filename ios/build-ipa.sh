#!/usr/bin/env bash
# 在 macOS 上一键导出可安装的 IPA（Ad Hoc / Development）。
# 前置：Xcode 已安装并登录 Apple ID；把 iPhone 连上 Mac 一次以登记设备。
# 用法：TEAM_ID=ABCDE12345 bash build-ipa.sh
set -e
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "此脚本只能在 macOS + Xcode 上运行（当前系统不是 Darwin）。"
  echo "Windows / Linux 上只能查看源码，无法编译或签名 iOS App。"
  exit 1
fi

if [ -z "$TEAM_ID" ]; then
  echo "请先设置 Apple Developer Team ID，例如："
  echo "  TEAM_ID=ABCDE12345 bash build-ipa.sh"
  echo "Team ID 在 developer.apple.com → Membership 里查看（免费 Apple ID 也可用）。"
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || { echo "未找到 xcodebuild，请先安装 Xcode 并运行 sudo xcode-select -s /Applications/Xcode.app"; exit 1; }

rm -rf build
mkdir -p build

echo "[1/2] Archive…"
xcodebuild \
  -project FileSharePhone.xcodeproj \
  -scheme FileSharePhone \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/FileSharePhone.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

echo "[2/2] 导出 IPA…"
# 复制导出配置并注入真实 Team ID，避免模板占位符让 -exportArchive 失败
cp exportOptions.plist build/exportOptions.plist
/usr/libexec/PlistBuddy -c "Delete :teamID" build/exportOptions.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" build/exportOptions.plist

xcodebuild -exportArchive \
  -archivePath build/FileSharePhone.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist build/exportOptions.plist \
  -allowProvisioningUpdates

echo ""
echo "完成：$(pwd)/build/ipa/FileSharePhone.ipa"
echo "安装方式：Xcode → Window → Devices and Simulators → 选中设备 → '+' 选这个 IPA；"
echo "或把 IPA 拖入 Apple Configurator / Finder（iOS 17+）安装到已登记的设备。"
echo "免费 Apple ID 签名有效期 7 天，到期需重新导出安装。"
