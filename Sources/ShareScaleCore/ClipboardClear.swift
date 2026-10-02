import Foundation

/// 見る側のクリップボードの消去の判定（仕様「見る側」のクリップボード。実際の操作は 2d-2）。
/// 貼り付けた時の `NSPasteboard.changeCount` と、ペアリングの成功後の値を比べ、同じなら（まだそのコードのままなら）消す。
/// 中身は読まない（読むと貼り付けの確認画面が出るため）
public enum ClipboardClear: Sendable {
    /// `changeCountAtPaste`: コードを貼り付けた（読んだ）時の `changeCount`。`now`: ペアリングの成功後の `changeCount`。
    /// 貼り付けを記録していなければ（nil）消さない
    public static func shouldClear(changeCountAtPaste: Int?, now: Int) -> Bool {
        guard let at = changeCountAtPaste else { return false }
        return at == now
    }
}
