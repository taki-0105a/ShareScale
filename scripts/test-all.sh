#!/bin/bash
# ShareScale の試験をすべて順に流し、最後にまとめて結果を出す。1 つでも失敗したら終了コード 1
#   scripts/test-all.sh
# swift test には XCTest が要る（Xcode）。試験はループバック（127.0.0.1）だけを使い、利用者のホームの実際の場所には書かない
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
steps=0
step() {
  local name=$1; shift
  local out; out=$("$@" 2>&1); local rc=$?
  steps=$((steps + 1))
  if [ $rc -eq 0 ]; then echo "✓ $name"; else
    echo "✗ $name"; printf '%s\n' "$out" | tail -30; fail=1
    # 落ちた試験の名前が tail に入らないことがあるので、全文を残して場所を出す（build/ は .gitignore の対象）
    local log; log="build/test-logs/$(date +%Y%m%d-%H%M%S)-step${steps}.log"
    if mkdir -p build/test-logs && printf '%s\n' "$out" > "$log"; then echo "    全文: $log"; fi
  fi
  # swift test の件数を拾って表示
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "Test Suite '[A-Za-z]+\.xctest' (passed|failed)" -A1 \
    | grep -oE "Executed [0-9]+ tests?, with [0-9]+ failures?" | sed 's/^/    /'
}
scripts=(scripts/*.sh scripts/lib/*.sh)
if [ -d scripts/release ]; then scripts+=(scripts/release/*.sh); fi
step "swift test" swift test
# 変数名のすぐ後に全角などの文字が続くと、UTF-8 の設定の bash は変数名の一部として読む（例: $AK の直後に「（」を書くと「AK（」という変数になる）。${AK} と書く。
# 検査の型の $ は [$] と書く（bash -c の二重引用符の中の \$ は $ になり、grep の拡張正規表現では行末の印として読まれて何にも当たらない）。
# 型の最後の [^…] にはタブを入れてある（変数の後のタブは全角文字ではない。計画 2e-2）
step "変数名の後の全角文字（\${…} で囲む）" bash -c 'bad=$(for f; do LC_ALL=C grep -nHE "[$][A-Za-z_][A-Za-z0-9_]*[^	 -~]" "$f"; done); [ -z "$bad" ] || { printf "%s\n" "$bad"; exit 1; }' _ "${scripts[@]}"
step "シェルスクリプトの構文" bash -c 'for f; do bash -n "$f" || exit 1; done' _ "${scripts[@]}"
[ $fail -eq 0 ] && echo "すべて成功" || echo "失敗あり"
exit $fail
