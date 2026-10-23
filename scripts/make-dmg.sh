#!/bin/bash
# 打包 Mac 版安装包（.dmg）：发布构建 → 本机临时签名 → 带「拖到应用程序」快捷方式与首次打开说明的磁盘映像。
# 未使用 Apple 开发者账号签名公证，其他 Mac 首次打开需在「系统设置 → 隐私与安全性」中放行一次。
# 用法：scripts/make-dmg.sh，生成 build/Noir-版本号.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project Noir.xcodeproj -scheme NoirMac -configuration Release build -quiet
# 构建产物在 Xcode 默认的 DerivedData 中
PRODUCTS=$(xcodebuild -project Noir.xcodeproj -scheme NoirMac -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
APP="$PRODUCTS/Noir.app"
[ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p build
OUT="build/Noir-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/墨影.app"
# 本机临时签名（Apple 芯片要求 App 必须有签名），保留沙盒权限与强化运行时
codesign --force --sign - --options runtime --entitlements Apps/macOS/Noir.entitlements "$STAGE/墨影.app"
codesign --verify --deep --strict "$STAGE/墨影.app"
ln -s /Applications "$STAGE/应用程序"

cat > "$STAGE/首次打开说明.txt" <<TXT
墨影 Noir $VERSION 安装说明

1. 把「墨影」拖到「应用程序」文件夹。
2. 第一次打开时，系统会提示“Apple 无法验证墨影是否包含恶意软件”，点「完成」。
   （墨影是免费的开源软件，还没有向 Apple 付费注册签名，所以会有这个提示。）
3. 打开「系统设置 → 隐私与安全性」，往下翻到“安全性”一栏，
   找到“已阻止使用墨影”，点「仍要打开」，输入开机密码确认。
4. 之后就可以像普通 App 一样直接打开了，这一步只需要做一次。

系统要求：macOS 15 或更新，Apple 芯片（M2 及更新）。
源代码：https://github.com/lidedongsn/Noir
TXT

rm -f "$OUT"
hdiutil create -volname "墨影 $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
echo "→ $OUT ($(du -h "$OUT" | cut -f1))"
shasum -a 256 "$OUT"
