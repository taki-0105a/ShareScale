#!/bin/bash
# ShareScale.app（見る側の画面・設定。中に ShareScale Host.app）を組み立てる（仕様「配布」「アプリと部品」）
#   scripts/build-sharescale.sh              build/ShareScale.app を作る（起動しない）
#   scripts/build-sharescale.sh --dev        開発の組み立て（Info.plist に ShareScaleDevelopmentBuild。build/ から見る側として動く）
#   scripts/build-sharescale.sh --install    作ってから ~/Applications/ShareScale.app に置き、引き渡しの記録（app-state.json）を消す（予備の手順）。
#                                            入れ終えたら build/ShareScale.app は消す（名前で開いた時に、~/Applications の方が開くように。計画 2h）
#   OUT=<フォルダ> scripts/build-sharescale.sh   出力先を変える
# 組み立ては既定の方式で行い、失敗したら --build-system native でやり直す（CLT 27 の不具合への対策。試作 1）。
# 中の Host を先に署名し、外の ShareScale.app を後で署名する（--deep は使わない）。両方の実行体に組み立てた場所のパスが無いことを確かめる
set -euo pipefail
usage() { echo "使い方: scripts/build-sharescale.sh [--dev | --install]" >&2; exit 64; }
DEV=0; INSTALL=0
for a in "$@"; do
  case "$a" in
    --dev) DEV=1 ;;
    --install) INSTALL=1 ;;
    *) usage ;;
  esac
done
# 開発の組み立ては ~/Applications に置かない（複製として登録されると、組み立て直すたびに動かなくなるため）
if [ "$DEV" = 1 ] && [ "$INSTALL" = 1 ]; then echo "--dev と --install は一緒に使えません" >&2; exit 64; fi

cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
OUT=${OUT:-build}
APP="$OUT/ShareScale.app"

# 版: VERSION（x.y.z、各 0〜99）。CFBundleVersion = x×10000 + y×100 + z。計算は ShareScale Host.app と共有する（仕様「版番号」）
. scripts/lib/sharescale-version.sh
sharescale_version "$PWD" || exit 1
VERSION=$SHARESCALE_VERSION
BUNDLE_VERSION=$SHARESCALE_BUNDLE_VERSION
COMMIT=$SHARESCALE_COMMIT
. scripts/lib/sharescale-build.sh

sharescale_swift_build ShareScale
mkdir -p "$OUT"
# 前の --install の後片付けが途中で止まって残したもの（.ShareScale-built-<pid>-<乱数>）を片付ける（点検 2h）
sharescale_clean_built_leftovers "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LoginItems"
cp .build/release/ShareScale "$APP/Contents/MacOS/ShareScale"
sharescale_strip_debug "$APP/Contents/MacOS/ShareScale"
sharescale_check_paths "$APP/Contents/MacOS/ShareScale" "$ROOT"
sharescale_check_single_arch "$APP/Contents/MacOS/ShareScale"
sharescale_icon "$APP/Contents/Resources/AppIcon.icns"

# 言語の宣言（CFBundleDevelopmentRegion・CFBundleLocalizations）: 文言はコードに並べて持ち（.lproj は無い）、宣言が無いと macOS は英語だけのアプリとして扱い、
# 標準のメニュー（「ShareScale について」「ウインドウ」「編集」など）や標準の部品の文言を、日本語の環境でも英語で出す（計画 2h。実機確認 A）。
# 日本語と英語を宣言し、それ以外の言語では英語（開発の言語）にする。アプリ自身の文言の言語も、同じ決まりで選ぶ（Locale.preferredLanguages の並びの中の、日本語か英語の最初のもの。HostLanguage.detect）
DEV_KEY=""
if [ "$DEV" = 1 ]; then DEV_KEY="  <key>ShareScaleDevelopmentBuild</key><true/>"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ShareScale</string>
  <key>CFBundleDisplayName</key><string>ShareScale</string>
  <key>CFBundleIdentifier</key><string>io.github.taki-0105a.ShareScale</string>
  <key>CFBundleExecutable</key><string>ShareScale</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
  <key>ShareScaleCommit</key><string>${COMMIT}</string>
${DEV_KEY}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>接続先の Mac に表示倍率の変更を送るために使います。Used to send display scale changes to the Mac you connect to.</string>
</dict></plist>
PLIST

# 中の Host を作って先に署名する（版の計算は共通なので同じ値になる。アイコンは同じもの）
OUT="$APP/Contents/Library/LoginItems" ICON="$APP/Contents/Resources/AppIcon.icns" scripts/build-host-app.sh

# 外を簡易署名（ad-hoc）＋強化ランタイム（--deep は使わない。中の Host の署名はそのまま封じる）。入れ子まで含めて検証する
codesign --force --options runtime --timestamp=none -s - "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
# codesign の出力は一度変数に受ける（grep -m1 などで管を先に閉じると codesign が SIGPIPE で落ち、pipefail で止まるため）
SIGNATURE=$(codesign -dvvv "$APP" 2>&1 || true)
CDHASH=$(printf '%s\n' "$SIGNATURE" | sed -n 's/^CDHash=//p')
KIND="配布用"; if [ "$DEV" = 1 ]; then KIND="開発用（--dev）"; fi
echo "ビルド: ${APP}（${KIND}・バージョン ${VERSION}・CFBundleVersion ${BUNDLE_VERSION}・${COMMIT}・CDHash ${CDHASH}）"

if [ "$INSTALL" = 0 ]; then
  if [ "$DEV" = 1 ]; then
    echo "起動: open \"${APP}\"（開発用のビルドのため、~/Applications にコピーせずに build/ からそのまま動きます）"
  else
    echo "インストール: scripts/build-sharescale.sh --install（build/ から開くと、~/Applications の ShareScale か Homebrew でインストールした ShareScale を開くよう案内して終了します）"
  fi
  exit 0
fi

# ---- 予備の手順: ~/Applications/ShareScale.app に置く（仕様「配布」の予備の手順。守りは sharescale_install_copy）----
sharescale_install_copy "$APP" || exit 1
echo "インストールしました: ${HOME}/Applications/ShareScale.app（アップデートの情報 app-state.json を削除しました）"
# 入れ終えたら、組み立て用のフォルダの ShareScale.app を残さない（残すと、Spotlight などで名前から開いた時にそちらが起動して案内で止まる。計画 2h）。
# 消せなくても、入れた複製は使える（注意を出すだけで、失敗にはしない）。「削除しました」は、実際に消した時だけ関数が出す
# （無かった・OUT が ~/Applications で入れた複製そのものだった時は、何も出さない。消せなかった理由と残ったものの名前も関数が出す。点検 2h）
sharescale_remove_built "$APP" || echo "注意: ビルド用の ${APP} を片付けられませんでした（理由は上の行）。残っていると、名前で開いた時にそちらが開くことがあります" >&2
echo "次に: open \"${HOME}/Applications/ShareScale.app\"（「この Mac を接続先にする」がオンなら、開いた時に新しい ShareScale Host に登録し直します）"
