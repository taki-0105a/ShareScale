#!/bin/bash
# リリースに添付する tarball を作る（ShareScale のリポジトリの中で実行する。GitHub には何もしない）
#   scripts/release/make-release.sh                     build/release/sharescale-<版>.tar.gz と .sha256 を作る
#   scripts/release/make-release.sh --verify            作った後に一時フォルダへ展開し、scripts/build-sharescale.sh で組み立て直す（起動しない）
#   OUT=<フォルダ> scripts/release/make-release.sh      出力先を変える（相対パスは呼んだ場所から。FORMULA も同じ）
#   FORMULA=<sharescale.rb> scripts/release/make-release.sh   Homebrew の formula の url と sha256 をこの tarball に書き換える
# コミットしていない変更があれば作らない。VERSION（x.y.z）を読み、BUILD_INFO（今のコミット ID）を足して git archive で固める。
# .gitattributes の export-ignore のもの（docs/ など）は入らない。組み立てに要るもの（Sources・Tests・assets・scripts/build-*.sh・scripts/lib）は必ず入る
set -euo pipefail
usage() { echo "使い方: scripts/release/make-release.sh [--verify]" >&2; exit 64; }
VERIFY=0
for a in "$@"; do
  case "$a" in
    --verify) VERIFY=1 ;;
    *) usage ;;
  esac
done
CALLER=$(pwd -P)
cd "$(dirname "$0")/../.."
ROOT=$(pwd -P)
# OUT と FORMULA の相対パスは、呼んだ場所から読む
case "${OUT:-}" in ""|/*) ;; *) OUT="$CALLER/$OUT" ;; esac
case "${FORMULA:-}" in ""|/*) ;; *) FORMULA="$CALLER/$FORMULA" ;; esac
REPO_URL=${REPO_URL:-https://github.com/taki-0105a/ShareScale}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "git のリポジトリの中で実行してください" >&2; exit 1; }
[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$ROOT" ] || { echo "このスクリプトがあるリポジトリの中で実行してください" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "コミットしていない変更があります。コミットしてから作ってください:" >&2
  git status --short | sed 's/^/  /' >&2
  exit 1
fi
if [ -e BUILD_INFO ]; then echo "BUILD_INFO がリポジトリにあります（tarball を作る時に足すものです。消してください）" >&2; exit 1; fi

. scripts/lib/sharescale-version.sh
sharescale_version "$ROOT" || exit 1
VERSION=$SHARESCALE_VERSION
COMMIT=$(git rev-parse --short HEAD)
NAME="sharescale-${VERSION}"
OUT=${OUT:-build/release}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
TARBALL="$OUT/${NAME}.tar.gz"

tmp=$(mktemp -d)
# 古い tarball・.sha256 は始める前に消す。失敗したら（--verify を含む）一時のもの・tarball・.sha256 を消す（古い・半端なものを残さない）
rm -f "$TARBALL" "$TARBALL.tmp" "$TARBALL.sha256"
done=0
cleanup() { rm -rf "$tmp"; if [ "$done" != 1 ]; then rm -f "$TARBALL.tmp" "$TARBALL" "$TARBALL.sha256"; fi; }
trap cleanup EXIT
printf '%s\n' "$COMMIT" > "$tmp/BUILD_INFO"
# git archive は足したファイル（BUILD_INFO）にもコミットの時刻を付ける。gzip -n で gzip の頭の時刻も 0 にする（同じコミットから同じ tarball）
git archive --format=tar --prefix="${NAME}/" --add-file="$tmp/BUILD_INFO" HEAD | gzip -n -9 > "$TARBALL.tmp"

# 一時の名前のまま中身を確かめる（組み立てに要るものがある・入れないものが無い・BUILD_INFO が今のコミット）
list=$(tar -tzf "$TARBALL.tmp")
for need in BUILD_INFO VERSION LICENSE Package.swift scripts/build-sharescale.sh scripts/build-host-app.sh \
            scripts/lib/sharescale-version.sh scripts/lib/sharescale-build.sh assets/icon/ShareScale-1024.png; do
  printf '%s\n' "$list" | grep -qxF "${NAME}/${need}" || { echo "tarball に ${need} がありません" >&2; exit 1; }
done
if printf '%s\n' "$list" | grep -qE "^${NAME}/(docs/|scripts/release/|\.git)"; then
  echo "tarball に入れないもの（docs/・scripts/release/・.git*）が入っています。.gitattributes を確かめてください" >&2; exit 1
fi
[ "$(tar -xzOf "$TARBALL.tmp" "${NAME}/BUILD_INFO" | tr -d '[:space:]')" = "$COMMIT" ] || { echo "tarball の BUILD_INFO が今のコミットと違います" >&2; exit 1; }
SHA=$(shasum -a 256 "$TARBALL.tmp" | awk '{print $1}')
mv "$TARBALL.tmp" "$TARBALL"
URL="${REPO_URL}/releases/download/v${VERSION}/${NAME}.tar.gz"
echo "tarball: ${TARBALL}（バージョン ${VERSION}・${COMMIT}）"
echo "コミットの作者: $(git log -1 --format='%an <%ae>' HEAD)（実名や個人のメールアドレスでないことを確かめてください）"

if [ "$VERIFY" = 1 ]; then
  # tarball だけから組み立て直せるか（git の履歴が無い状態。アプリは起動しない）
  mkdir "$tmp/verify"
  tar -xzf "$TARBALL" -C "$tmp/verify"
  (cd "$tmp/verify/${NAME}" && OUT="$tmp/verify/out" scripts/build-sharescale.sh)
  plist="$tmp/verify/out/ShareScale.app/Contents/Info.plist"
  got=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  commit=$(/usr/libexec/PlistBuddy -c 'Print :ShareScaleCommit' "$plist")
  [ "$got" = "$VERSION" ] && [ "$commit" = "$COMMIT" ] || { echo "組み立て直したアプリの版（${got}・${commit}）が違います" >&2; exit 1; }
  echo "tarball から組み立て直せました（バージョン ${got}・${commit}。アプリは起動していません）"
fi

printf '%s  %s\n' "$SHA" "${NAME}.tar.gz" > "$TARBALL.sha256"
echo "sha256: ${SHA}"
echo "formula に書く値:"
echo "  url \"${URL}\""
echo "  sha256 \"${SHA}\""
if [ -n "${FORMULA:-}" ]; then
  [ -f "$FORMULA" ] || { echo "formula が見つかりません: ${FORMULA}" >&2; exit 1; }
  grep -qE '^  url "' "$FORMULA" && grep -qE '^  sha256 "' "$FORMULA" || { echo "formula に url と sha256 の行がありません: ${FORMULA}" >&2; exit 1; }
  URL="$URL" SHA="$SHA" /usr/bin/perl -pi -e 's{^  url ".*"$}{  url "$ENV{URL}"}; s{^  sha256 ".*"$}{  sha256 "$ENV{SHA}"}' "$FORMULA"
  echo "formula を書き換えました: ${FORMULA}"
fi
done=1
echo "次に: タグ v${VERSION} を付け、GitHub のリリース v${VERSION} に ${NAME}.tar.gz を添付してから、tap の formula の url と sha256 を上の値にします（自動で作られるソースの圧縮ファイルは使いません）"
