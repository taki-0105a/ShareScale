# ShareScale の組み立ての共通の関数（scripts/build-sharescale.sh と scripts/build-host-app.sh が使う）
#   . scripts/lib/sharescale-build.sh
#
# sharescale_swift_build <product>
#   swift build -c release --product <product>。既定の方式が CLT 27 の不具合（SessionFailedError・spec の二重登録）で失敗した時だけ、
#   --build-system native で 1 回やり直す（仕様「配布」・試作 1）。コンパイルの誤りなど、ほかの失敗ではやり直さない。
#   SHARESCALE_SWIFTPM_NO_SANDBOX=1 の時は両方に --disable-sandbox を付ける（Homebrew の formula の中。計画 2e-2）
#
# sharescale_icon <出力.icns>
#   assets/icon/ShareScale-1024.png（1024×1024・透明の地・macOS の決まりの 824px のタイル。2026-09-30 に利用者が採用）を
#   sips と iconutil で .icns にする（一時フォルダは trap で片付ける）。画像が無い・1024×1024 でなければ理由を出して止まる
#
# sharescale_strip_debug <実行体>
#   デバッグの記号（記号表の N_OSO・N_SO など。組み立てた場所の絶対パスを含む）を strip -S で除く。署名の前に呼ぶ（計画 2e-2）
#
# sharescale_check_paths <実行体> <組み立てた場所>
#   実行体に組み立てた場所の絶対パスが入っていないことを strings で確かめる（入っていれば理由を出して 1 を返す）。
#   strings には標準入力から読ませる（ファイル名で渡すと、-a でも Mach-O の記号表の文字を読まない。計画 2e-2）。
#   あわせてファイルのバイトを grep -aF で直接探す（strings は日本語などを含むパスを 1 続きで拾わないため）
#
# sharescale_check_single_arch <実行体>
#   実行体のアーキテクチャが 1 つであることを確かめる（署名の確かめに kSecCSCheckAllArchitectures を付けない前提の守り）
#
# sharescale_install_copy <組み立てた ShareScale.app>
#   予備の手順（--install）: $HOME/Applications/ShareScale.app に置き、引き渡しの記録（app-state.json）を消す。
#   同じフォルダの一時的な名前に ditto → 検証 → 旧版を一時的な名前へ退避 → rename(2) → 旧版を消す。失敗・中断（INT・TERM・HUP）したら、
#   置き終える前なら元に戻し、置き終えた後なら完了の処理をする。ACL を読み取れない時も置かない。
#   HOME が使えない・HOME か ~/Applications が自分のものでない・~/Applications がリンクかほかの人が書ける（権限・書き込みを許す ACL）・
#   既存の複製がリンクか別のアプリ・動いている時は断る（1 を返す）
#
# sharescale_remove_built <組み立てた ShareScale.app>
#   予備の手順（--install）で入れ終えた後に、組み立て用のフォルダの ShareScale.app を消す（計画 2h。残すと、Spotlight などで名前から開いた時に
#   そちらが起動して、「~/Applications の ShareScale を開く」の案内で止まる）。消すのは、リンクでなく、名前が ShareScale.app で、識別子が ShareScale の
#   フォルダだけ。入れた複製（$HOME/Applications/ShareScale.app）そのものを指している時は何もしない。
#   先に同じフォルダの一時的な名前（.ShareScale-built-<pid>-<乱数>。アプリの名前でないもの）へ rename(2) で移してから消す（途中で止められても、
#   壊れたアプリが ShareScale.app の名前で残らない）。消した時だけ「削除しました」と標準出力に出す（無かった・入れた複製そのものだった時は、
#   何も出さずに 0 を返す）。消せない時は理由（消しきれなかった時は、残った隠しフォルダの名前と消し方）を標準エラーに出して 1 を返す（入れた複製はそのまま）
#
# sharescale_clean_built_leftovers <組み立て用のフォルダ>
#   前の sharescale_remove_built が途中で止まって残した .ShareScale-built-<pid>-<乱数> を片付ける（組み立ての始めに呼ぶ）。
#   消すのは、そのフォルダの直下の・名前がこの型どおりで・リンクでないフォルダで・その pid のプロセスが動いていないものだけ

# CLT 27 の既定の組み立て方式の不具合の印（試作 1 の記録）
SHARESCALE_CLT_BUG='SessionFailedError|already registered from'

sharescale_swift_build() {
  local product=$1 log rc extra=()
  # Homebrew の中の組み立て（formula が SHARESCALE_SWIFTPM_NO_SANDBOX=1 を付ける）では SwiftPM の sandbox を使わない
  # （Homebrew の sandbox の中では sandbox-exec を入れ子にできないため。Homebrew の std_swift_args と同じ。計画 2e-2）
  if [ "${SHARESCALE_SWIFTPM_NO_SANDBOX:-}" = 1 ]; then extra=(--disable-sandbox); fi
  log=$(mktemp) || return 1
  swift build -c release ${extra[@]+"${extra[@]}"} --product "$product" > "$log" 2>&1 && rc=0 || rc=$?
  cat "$log"
  if [ "$rc" -ne 0 ] && grep -qE "$SHARESCALE_CLT_BUG" "$log"; then
    rm -f "$log"
    echo "既定のビルド方式が CLT の不具合で失敗したため、--build-system native でやり直します（${product}）" >&2
    swift build -c release ${extra[@]+"${extra[@]}"} --build-system native --product "$product"
    return $?
  fi
  rm -f "$log"
  return "$rc"
}

sharescale_icon() (
  out=$1
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$tmp"' EXIT
  iconset="$tmp/AppIcon.iconset"
  src="assets/icon/ShareScale-1024.png"
  if [ ! -f "$src" ]; then echo "アイコンの画像（${src}）が見つかりません" >&2; exit 1; fi
  w=$(sips -g pixelWidth "$src" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  if [ "${w}" != 1024 ] || [ "${h}" != 1024 ]; then echo "アイコンの画像（${src}）が 1024×1024 ではありません（${w}×${h}）" >&2; exit 1; fi
  mkdir -p "$iconset" || exit 1
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$src" --out "$iconset/icon_${s}x${s}.png" >/dev/null || exit 1
    sips -z $((s*2)) $((s*2)) "$src" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null || exit 1
  done
  iconutil -c icns "$iconset" -o "$out" || exit 1
)

sharescale_strip_debug() {
  local bin=$1
  if ! command -v strip >/dev/null 2>&1; then
    echo "strip が見つかりません（Command Line Tools か Xcode をインストールしてください）" >&2
    return 1
  fi
  if ! strip -S "$bin"; then echo "デバッグの記号を除けません（${bin}）" >&2; return 1; fi
  return 0
}

sharescale_check_paths() {
  local bin=$1 root=$2 text found
  if ! command -v strings >/dev/null 2>&1; then
    echo "strings が見つかりません（Command Line Tools か Xcode をインストールしてください）" >&2
    return 1
  fi
  # strings の失敗を隠さない（読めなければ確かめられないので失敗にする）。標準入力から読ませて、記号表を含むすべてのバイトを見る
  if ! text=$(strings -a - < "$bin"); then echo "strings で読み取れません（${bin}）" >&2; return 1; fi
  found=$(printf '%s\n' "$text" | grep -F -- "$root" | head -3 || true)
  if [ -n "$found" ]; then
    echo "実行ファイルにビルドした場所のパスが入っています（${bin}）:" >&2
    printf '  %s\n' "$found" >&2
    return 1
  fi
  # strings は ASCII の続きだけを拾うので、日本語などを含むパスはファイルのバイトを直接探す（計画 2e-2）
  if LC_ALL=C grep -aqF -- "$root" "$bin"; then
    echo "実行ファイルにビルドした場所のパスが入っています（${bin}）" >&2
    return 1
  fi
  return 0
}

sharescale_check_single_arch() {
  local bin=$1 archs
  archs=$(lipo -archs "$bin" 2>/dev/null) || { echo "アーキテクチャを読み取れません（${bin}）" >&2; return 1; }
  if [ "$(printf '%s\n' $archs | grep -c .)" -ne 1 ]; then
    echo "実行ファイルのアーキテクチャが 1 つではありません（${bin}: ${archs}）" >&2
    return 1
  fi
  return 0
}

# フォルダの持ち主が自分か（HOME と ~/Applications）
sharescale_owned_by_me() {
  local d=$1 uid
  uid=$(stat -f %u "$d" 2>/dev/null) || return 1
  [ "$uid" = "$(id -u)" ]
}

# ~/Applications として使えるか（Swift 側の AppInstaller.prepareFolder と同じ条件）: 本人のもの・グループと他人が書けない・書き込みを許す ACL が無い。
# ACL を読み取れない時は置かない（Swift 側と同じく、使わない側に倒す）
sharescale_applications_safe() {
  local d=$1 mode acl
  if ! sharescale_owned_by_me "$d"; then echo "~/Applications があなたのものでないため、インストールしません" >&2; return 1; fi
  mode=$(stat -f %Lp "$d" 2>/dev/null) || { echo "~/Applications のアクセス権を読み取れません" >&2; return 1; }
  if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then echo "~/Applications にほかの人が書き込めるため、インストールしません（権限 ${mode}）" >&2; return 1; fi
  acl=$(ls -led "$d" 2>/dev/null) || { echo "~/Applications の ACL を読み取れないため、インストールしません" >&2; return 1; }
  # ls -led の 2 行目からが ACL の項目（例「 0: group:everyone allow add_file」）。許可の項目に書き込み系があれば使わない（拒否だけなら構わない）
  if printf '%s\n' "$acl" | tail -n +2 | grep -E ' allow ' | grep -qE 'write|append|delete|add_file|add_subdirectory|chown'; then
    echo "~/Applications にほかの人の書き込みを許す ACL があるため、インストールしません" >&2; return 1
  fi
  return 0
}

# rename(2) で名前を変える（BSD の mv と違い、行き先にフォルダがあっても中へ入れない。空でないフォルダがあれば失敗する）
sharescale_rename() {
  /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

sharescale_install_copy() {
  local app=$1 dir dest
  if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then echo "HOME が使えないため、インストールしません" >&2; return 1; fi
  if ! sharescale_owned_by_me "$HOME"; then echo "HOME があなたのものでないため、インストールしません" >&2; return 1; fi
  dir="$HOME/Applications"
  dest="$dir/ShareScale.app"
  SHARESCALE_STATE="$HOME/Library/Application Support/ShareScale/app-state.json"
  if [ -L "$dir" ]; then echo "~/Applications がシンボリックリンクのため、インストールしません" >&2; return 1; fi
  if [ ! -d "$dir" ]; then mkdir -m 700 "$dir" || return 1; fi
  sharescale_applications_safe "$dir" || return 1
  if [ -L "$dest" ]; then echo "~/Applications/ShareScale.app がシンボリックリンクのため、インストールしません。ゴミ箱に入れてからやり直してください" >&2; return 1; fi
  if [ -e "$dest" ]; then
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)" != "io.github.taki-0105a.ShareScale" ]; then
      echo "~/Applications/ShareScale.app は別のアプリのため、インストールしません" >&2; return 1
    fi
    if pgrep -qf "$dest/Contents/MacOS/ShareScale" 2>/dev/null; then
      echo "~/Applications の ShareScale が動いています。終了してからやり直してください" >&2; return 1
    fi
  fi
  # 一時的な名前は ShareScale.app の置き換え（Swift の AppInstaller）と同じ形（.ShareScale-install-<pid>-<乱数>。旧版は .ShareScale-old-<pid>-<乱数>）。
  # 落ちた時の残りは、次の置き換えで pid が生きていないものとして片付く
  SHARESCALE_TMP="$dir/.ShareScale-install-$$-$RANDOM"
  SHARESCALE_OLD="$dir/.ShareScale-old-$$-$RANDOM"
  SHARESCALE_DEST=$dest
  SHARESCALE_STEP=copying
  if [ -e "$SHARESCALE_TMP" ] || [ -e "$SHARESCALE_OLD" ]; then echo "作業用の一時的な名前（${SHARESCALE_TMP##*/}）がすでに使われています。もう一度やり直してください" >&2; return 1; fi
  # 途中で止められても（Ctrl-C・TERM・HUP）、置き終える前なら退避した旧版を元の名前に戻し、置き終えた後なら完了の処理をする。
  # 終了コードは INT 130・TERM 143・HUP 129
  trap 'sharescale_install_interrupted 130' INT
  trap 'sharescale_install_interrupted 143' TERM
  trap 'sharescale_install_interrupted 129' HUP
  if ! ditto "$app" "$SHARESCALE_TMP"; then sharescale_install_rollback; trap - INT TERM HUP; return 1; fi
  if ! codesign --verify --deep --strict "$SHARESCALE_TMP"; then
    echo "コピーした ShareScale.app の署名を確認できません" >&2; sharescale_install_rollback; trap - INT TERM HUP; return 1
  fi
  if [ -e "$dest" ]; then
    if ! mv "$dest" "$SHARESCALE_OLD"; then sharescale_install_rollback; trap - INT TERM HUP; return 1; fi
  fi
  # 退避の後に、別のものが置かれていないか（置かれていれば上書きしない）
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "~/Applications/ShareScale.app がインストールの途中でほかから作られたため、中止しました" >&2; SHARESCALE_DEST=""; sharescale_install_rollback; trap - INT TERM HUP; return 1
  fi
  SHARESCALE_STEP=placing
  if ! sharescale_rename "$SHARESCALE_TMP" "$dest"; then
    echo "~/Applications/ShareScale.app にインストールできませんでした" >&2; SHARESCALE_STEP=copying; sharescale_install_rollback; trap - INT TERM HUP; return 1
  fi
  sharescale_install_finish
  trap - INT TERM HUP
  return 0
}

sharescale_remove_built() {
  local app=$1 dir tmp
  # 末尾の / は、いくつ付いていても除く（名前の確かめと dirname を、フォルダそのものに当てるため）
  while [ "${app%/}" != "$app" ]; do app=${app%/}; done
  if [ "${app##*/}" != "ShareScale.app" ]; then echo "名前が ShareScale.app ではないため、削除しません（${app}）" >&2; return 1; fi
  if [ -L "$app" ]; then echo "ビルド用の ShareScale.app がシンボリックリンクのため、削除しません（${app}）" >&2; return 1; fi
  if [ ! -e "$app" ]; then return 0; fi
  if [ ! -d "$app" ]; then echo "ビルド用の ShareScale.app がフォルダではないため、削除しません（${app}）" >&2; return 1; fi
  # 入れた複製そのもの（OUT に ~/Applications を指した時など）は消さない
  if [ -n "${HOME:-}" ] && [ "$app" -ef "${HOME}/Applications/ShareScale.app" ]; then return 0; fi
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)" != "io.github.taki-0105a.ShareScale" ]; then
    echo "ビルド用の ShareScale.app が別のアプリのため、削除しません（${app}）" >&2; return 1
  fi
  dir=$(dirname "$app")
  tmp="$dir/.ShareScale-built-$$-$RANDOM"
  if [ -e "$tmp" ] || [ -L "$tmp" ]; then echo "作業用の一時的な名前（${tmp##*/}）がすでに使われています。もう一度やり直してください" >&2; return 1; fi
  if ! sharescale_rename "$app" "$tmp"; then echo "ビルド用の ShareScale.app を削除できませんでした（${app}）。Finder でゴミ箱に入れてください" >&2; return 1; fi
  if ! rm -rf "$tmp"; then
    echo "ビルド用の ShareScale.app を削除しきれませんでした。残り: ${tmp}（名前が . で始まるので Finder には出ません。次に scripts/build-sharescale.sh を実行した時に片付けます）" >&2
    return 1
  fi
  echo "ビルド用の ${app} は削除しました（名前で開いた時に、~/Applications の ShareScale が開くようにするため）"
  return 0
}

sharescale_clean_built_leftovers() {
  local dir=$1 path name pid
  [ -d "$dir" ] || return 0
  for path in "$dir"/.ShareScale-built-*; do
    name=${path##*/}
    # 名前の型（.ShareScale-built-<pid>-<乱数>。どちらも数字だけ）に合うものだけ
    [[ "$name" =~ ^\.ShareScale-built-([0-9]+)-([0-9]+)$ ]] || continue
    pid=${BASH_REMATCH[1]}
    # リンクはたどらない。フォルダだけ
    if [ -L "$path" ] || [ ! -d "$path" ]; then continue; fi
    # その pid のプロセスが動いている間は触らない（別の端末で --install の後片付けの途中かもしれない）
    if ps -p "$pid" > /dev/null 2>&1; then continue; fi
    rm -rf "$path" || echo "前回の残り（${path}）を片付けられませんでした" >&2
  done
  return 0
}

# 置き終えた後の処理: 識別子を確かめた旧版を消し、複製元の記録を消す
# （Homebrew 側へ自動で引き渡さないように。最後に登録した CDHash も消えるので、次に開いた時にログイン項目を登録し直す）
sharescale_install_finish() {
  SHARESCALE_STEP=placed
  if [ -n "${SHARESCALE_OLD:-}" ] && [ -e "$SHARESCALE_OLD" ]; then rm -rf "$SHARESCALE_OLD"; fi
  if [ -n "${SHARESCALE_STATE:-}" ]; then rm -f "$SHARESCALE_STATE"; fi
}

# 止められた時: 一時的なものが無く、元の名前に新版がある（置き終えた）なら完了の処理、そうでなければ元に戻す
sharescale_install_interrupted() {
  trap - INT TERM HUP
  if [ "${SHARESCALE_STEP:-}" = placing ] || [ "${SHARESCALE_STEP:-}" = placed ]; then
    if [ -n "${SHARESCALE_TMP:-}" ] && [ ! -e "$SHARESCALE_TMP" ] && [ -n "${SHARESCALE_DEST:-}" ] && [ -e "$SHARESCALE_DEST" ]; then
      sharescale_install_finish
      exit "$1"
    fi
  fi
  sharescale_install_rollback
  exit "$1"
}

# 置き換えの途中で止まった時: 旧版を元の名前に戻し（元の名前が空いている時だけ。rename(2) で中へ入れない）、一時的なものを消す
sharescale_install_rollback() {
  if [ -n "${SHARESCALE_OLD:-}" ] && [ -e "$SHARESCALE_OLD" ] && [ -n "${SHARESCALE_DEST:-}" ] && [ ! -e "$SHARESCALE_DEST" ] && [ ! -L "$SHARESCALE_DEST" ]; then
    sharescale_rename "$SHARESCALE_OLD" "$SHARESCALE_DEST"
  fi
  if [ -n "${SHARESCALE_TMP:-}" ] && [ -e "$SHARESCALE_TMP" ]; then rm -rf "$SHARESCALE_TMP"; fi
}
