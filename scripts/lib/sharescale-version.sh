# ShareScale の版（scripts/build-host-app.sh と scripts/build-sharescale.sh が共有する。仕様「版番号」）
#   . scripts/lib/sharescale-version.sh
#   sharescale_version <リポジトリの根> || exit 1
# 設定する変数:
#   SHARESCALE_VERSION         VERSION の x.y.z（各 0〜99。先頭の 0 は不可）。CFBundleShortVersionString
#   SHARESCALE_BUNDLE_VERSION  x×10000 + y×100 + z（git の履歴が無い tarball からでも同じ値）。CFBundleVersion
#   SHARESCALE_COMMIT          表示のためだけのコミット ID（BUILD_INFO があればそれ、無ければ git（未コミットの変更があれば -dirty）、どちらも無ければ unknown）。
#                              BUILD_INFO の中身が 7〜40 文字の小文字の 16 進（任意で -dirty）でなければ unknown（Info.plist に任意の文字列を入れないため）
# VERSION の形が違えば理由を標準エラーに出して 1 を返す
sharescale_version() {
  local root=$1 text a b c n
  text=$(tr -d '[:space:]' < "$root/VERSION") || return 1
  IFS=. read -r a b c <<< "$text"
  for n in "$a" "$b" "$c"; do
    [[ "$n" =~ ^(0|[1-9][0-9]?)$ ]] || { echo "VERSION は x.y.z（各 0〜99。先頭の 0 は不可）で書いてください: ${text}" >&2; return 1; }
  done
  SHARESCALE_VERSION=$text
  SHARESCALE_BUNDLE_VERSION=$((10#$a*10000 + 10#$b*100 + 10#$c))
  if [ -f "$root/BUILD_INFO" ]; then
    SHARESCALE_COMMIT=$(tr -d '[:space:]' < "$root/BUILD_INFO")
    [[ "$SHARESCALE_COMMIT" =~ ^[0-9a-f]{7,40}(-dirty)?$ ]] || SHARESCALE_COMMIT=unknown
  else
    SHARESCALE_COMMIT=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ "$SHARESCALE_COMMIT" != unknown ] && [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
      SHARESCALE_COMMIT="${SHARESCALE_COMMIT}-dirty"
    fi
  fi
  return 0
}
