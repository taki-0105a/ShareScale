#!/bin/bash
# ShareScale Host.app（接続先の常駐。メニューバーのみ）を組み立てる
#   scripts/build-host-app.sh            build/ShareScale Host.app を作る（単体。開発で Host だけを試す時）
#   OUT=<フォルダ> scripts/build-host-app.sh   出力先を変える（scripts/build-sharescale.sh が ShareScale.app/Contents/Library/LoginItems/ を渡す）
#   ICON=<.icns> scripts/build-host-app.sh     作ったアイコンを使う（無ければ描く）
# ここでは組み立てて簡易署名するだけで、起動も登録もしない
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
OUT=${OUT:-build}
APP="$OUT/ShareScale Host.app"

# 版: VERSION（x.y.z、各 0〜99）。CFBundleVersion = x×10000 + y×100 + z（git の履歴が無い tarball からでも同じ値。仕様「版番号」）。
# コミット ID は表示のためだけ（BUILD_INFO があればそれ、無ければ git、どちらも無ければ unknown）。計算は ShareScale.app と共有する
. scripts/lib/sharescale-version.sh
sharescale_version "$PWD" || exit 1
VERSION=$SHARESCALE_VERSION
BUNDLE_VERSION=$SHARESCALE_BUNDLE_VERSION
COMMIT=$SHARESCALE_COMMIT
. scripts/lib/sharescale-build.sh

sharescale_swift_build ShareScaleHost
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ShareScaleHost "$APP/Contents/MacOS/ShareScaleHost"
sharescale_strip_debug "$APP/Contents/MacOS/ShareScaleHost"
sharescale_check_paths "$APP/Contents/MacOS/ShareScaleHost" "$ROOT"
sharescale_check_single_arch "$APP/Contents/MacOS/ShareScaleHost"
if [ -n "${ICON:-}" ]; then cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"; else sharescale_icon "$APP/Contents/Resources/AppIcon.icns"; fi

# 言語の宣言（CFBundleDevelopmentRegion・CFBundleLocalizations）: 文言はコードに並べて持ち（.lproj は無い）、宣言が無いと macOS は英語だけのアプリとして扱い、
# 標準の部品（文字を選んだ時のメニューなど）の文言を、日本語の環境でも英語で出す（計画 2h。実機確認 A）。
# 日本語と英語を宣言し、それ以外の言語では英語（開発の言語）にする。アプリ自身の文言の言語も、同じ決まりで選ぶ（Locale.preferredLanguages の並びの中の、日本語か英語の最初のもの。HostLanguage.detect）
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ShareScale Host</string>
  <key>CFBundleDisplayName</key><string>ShareScale Host</string>
  <key>CFBundleIdentifier</key><string>io.github.taki-0105a.ShareScale.Host</string>
  <key>CFBundleExecutable</key><string>ShareScaleHost</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
  <key>ShareScaleCommit</key><string>${COMMIT}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>接続元の Mac から表示倍率の変更を受け取るために使います。Used to receive display scale changes from the Macs you connect from.</string>
</dict></plist>
PLIST

# 簡易署名（ad-hoc）＋強化ランタイム。署名の後で壊れていないか検証する
codesign --force --options runtime --timestamp=none -s - "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
# codesign の出力は一度変数に受ける（grep -m1 などで管を先に閉じると codesign が SIGPIPE で落ち、pipefail で止まるため）
SIGNATURE=$(codesign -dvvv "$APP" 2>&1 || true)
CDHASH=$(printf '%s\n' "$SIGNATURE" | sed -n 's/^CDHash=//p')
echo "ビルド: ${APP}（バージョン ${VERSION}・CFBundleVersion ${BUNDLE_VERSION}・${COMMIT}・CDHash ${CDHASH}）"
# 単体で作った時だけ起動の仕方を出す（ShareScale.app の中に作った時は、ShareScale.app の「この Mac を接続先にする」が登録する）
if [ -z "${ICON:-}" ]; then echo "起動: open \"${APP}\"（メニューバーに出ます。終了はメニューの「ShareScale Host を終了」）"; fi
