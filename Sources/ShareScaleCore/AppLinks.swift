import Foundation

/// アプリから開く外のリンク（計画 2h）。**公開のリポジトリの URL だけ**（アプリ自身は外へ通信しない。開くのは利用者のブラウザで、利用者がメニューを選んだ時だけ）
public enum AppLinks {
    /// 公開のリポジトリ（説明・使い方・困った時の手順は README にある）
    public static let repository = URL(string: "https://github.com/taki-0105a/ShareScale")!

    /// 「ヘルプ」のメニューの項目。標準の「ShareScale ヘルプ」は、ヘルプの本が無いので選んでも何も出ないため、これに置き換える
    public static var helpTitle: String { tr("ShareScale の説明を GitHub で開く", "Open ShareScale on GitHub") }
}
