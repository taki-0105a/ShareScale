import Darwin
import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// host-control の書き手（ShareScale.app の「この Mac の接続先」が使う。仕様「同じ Mac の中の受け渡し」）。
/// - 指示: `request-<uuid>.json` を一時ファイル（600・`O_EXCL`・`O_NOFOLLOW`）→ rename で置き（`HostControlFolder.writeRequest`。`ProtectedFiles`）、
///   `DistributedNotificationCenter` に `deliverImmediately: true` で通知する（`notify`。試験では差し替える）
/// - 状態: `state.json` を `HostControlState.decode` で読み、Host が動いているかは `pid` の生存（`kill(pid, 0)`）で判定する
///   （`updated` は「最後に書いた時刻」で、生存の印ではない）
/// 秘密・コードの文字列はこの受け渡しに載せない（「新しい見る側を追加」のコードは Host 自身の窓に出る）
public final class HostControlClient: @unchecked Sendable {
    public let folder: HostControlFolder
    private let notify: @Sendable () -> Void
    private let wallClock: @Sendable () -> Date
    private let isAlive: @Sendable (pid_t) -> Bool

    public init(folder: HostControlFolder = .standard(), notify: @escaping @Sendable () -> Void = { HostControlFolder.postNotification() },
                wallClock: @escaping @Sendable () -> Date = { Date() }, isAlive: @escaping @Sendable (pid_t) -> Bool = { ProtectedFiles.isAlive($0) }) {
        self.folder = folder; self.notify = notify; self.wallClock = wallClock; self.isAlive = isAlive
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRequest   // `op` に合わない `id`／`value`（`unpair`・`snooze` には `id`、`set_*` には `value` が要る）
    }

    /// Host の様子（`state.json` から）。
    /// `pid` は使い回されることがある（落ちた Host の pid を別のプロセスが持つと `.running` に見える）。
    /// 画面は「操作しても反応が無ければ『この Mac を接続先にする』をオンにし直してください」を添える（2d-2）
    public enum HostState: Equatable, Sendable {
        case running(HostControlState.Summary)           // `running` が真で、`pid` が生きている
        case notRunning(last: HostControlState.Summary?) // `state.json` が無い（nil）、`running` が偽、または `pid` が生きていない
        case unknown(problem: String)                    // `state.json` はあるが読めない・形が違う（権限を直すか、Host を起動し直す）
        public var summary: HostControlState.Summary? {
            switch self { case let .running(s): return s; case let .notRunning(s): return s; case .unknown: return nil }
        }
        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    public func hostState() -> HostState {
        let r = folder.readStateDetailed()
        if let p = r.problem { return .unknown(problem: p) }
        guard let s = r.summary else { return .notRunning(last: nil) }
        guard s.running, let pid = pid_t(exactly: s.pid), isAlive(pid) else { return .notRunning(last: s) }
        return .running(s)
    }

    /// 指示を置いて通知する（`at` は今の壁時計）
    public func send(_ op: HostControlOp, id: PairingID? = nil, value: Bool? = nil) throws {
        guard let q = HostControlRequest(op: op, id: id, value: value, at: Int64(wallClock().timeIntervalSince1970)) else { throw Error.invalidRequest }
        try folder.writeRequest(q)
        notify()
    }

    // 「この Mac の接続先」の操作
    public func pause() throws { try send(.pause) }
    public func resume() throws { try send(.resume) }
    /// 新しい見る側を追加（コードは Host 自身の窓に出る。ファイルには期限だけ）
    public func issueCode() throws { try send(.issueCode) }
    public func unpair(_ id: PairingID) throws { try send(.unpair, id: id) }
    /// 80 日の知らせの「あとで」
    public func snooze(_ id: PairingID) throws { try send(.snooze, id: id) }
    public func setTailscaleOnly(_ on: Bool) throws { try send(.setTailscaleOnly, value: on) }
    public func setAllowGlobal(_ on: Bool) throws { try send(.setAllowGlobal, value: on) }
    public func quit() throws { try send(.quit) }
    /// 発行中のコードの窓をもう一度出す（ShareScale.app のメニュー。計画 2f-2）
    public func showCode() throws { try send(.showCode) }
    /// Host の診断の窓を出す（ShareScale.app のメニュー。計画 2f-2）
    public func showDiagnostics() throws { try send(.showDiagnostics) }

    /// Host が動いていない時の案内（「この Mac を接続先にする」＝ログイン項目の登録。計画 2e-1）。ShareScale.app は `AppLanguage.current.host` を渡す（文言はここ 1 か所）
    public static func notRunningGuidance(_ state: HostState, language: HostLanguage) -> String? {
        switch state {
        case .running: return nil
        case .unknown:
            // 生の理由（`problem`）は本文に出さない（DESIGN.md「文言」。画面は「詳細をコピー」に渡す。計画 2e-1）
            // 見出し（「状態を読み取れません」）と同じ文を重ねず、すぐできる操作を先に書く（仕上げ 2026-09-30）
            return language.t("「この Mac を接続先にする」をオフにしてからもう一度オンにするか、~/Library/Application Support/ShareScale/host-control/ のアクセス権を確認してください。",
                              "Turn Use This Mac as a Target off and then on again, or check the permissions of ~/Library/Application Support/ShareScale/host-control/.")
        case let .notRunning(last):
            if last == nil {
                return language.t("この Mac の ShareScale Host はまだ動いていません。「この Mac を接続先にする」をオンにしてください。",
                                  "ShareScale Host isn’t running on this Mac yet. Turn on Use This Mac as a Target.")
            }
            return language.t("この Mac の ShareScale Host が動いていません。「この Mac を接続先にする」をオフにしてからもう一度オンにするか、システム設定 › 一般 › ログイン項目を確認してください。",
                              "ShareScale Host isn’t running on this Mac. Turn Use This Mac as a Target off and then on again, or check System Settings › General › Login Items.")
        }
    }
}
