import Foundation

public enum Limits: Sendable {
    public static let defaultPort = 47651
    /// 通信口として正しい範囲（接続コードの `p`・状態の `addrs.p`・手入力のアドレス）
    public static let portRange = 1...65535
    /// macOS が接続の手元の通信口（送り元）に配る範囲（一時の通信口）。Host がこの範囲で待ち受けると、待ち受けていない間に
    /// ほかの通信がその通信口を取り、待ち受けられなくなることがある（Host の診断で注意を出す。計画 2g）
    public static let ephemeralPortRange = 49152...65535
    public static let requestMaxBytes = 4 * 1024
    public static let responseMaxBytes = 16 * 1024
    public static let pairingCodeMaxBytes = 1024
    public static let maxCandidateAddresses = 8
    public static let maxPairings = 32
    public static let secretLength = Bytes32.count
    public static let idHexLength = 32
    public static let logMaxLines = 50
    /// 相手に渡す文字列（名前・機種・直近の失敗・記録の 1 行）の上限。書き出す側で切り詰め、読む側で確かめる
    public static let textMaxBytes = 256
}
