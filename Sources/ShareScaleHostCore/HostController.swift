import Foundation
import ShareScaleEngine
import ShareScaleNet
import ShareScaleProtocol
import SystemConfiguration

/// 通信の `Mode`（`ShareScaleProtocol`）と倍率の維持の `ScaleMode`（`ShareScaleEngine`）の変換
public extension ScaleMode {
    init(_ mode: Mode) {
        switch mode { case .oneX: self = .x1; case .twoX: self = .x2; case .off: self = .off }
    }
    var wire: Mode {
        switch self { case .x1: return .oneX; case .x2: return .twoX; case .off: return .off }
    }
}

/// 名乗りの確認の窓に渡すもの
public struct ApprovalRequest: Equatable, Sendable {
    public let codeID: PairingID
    public let name: String              // 規則で検査した名前（`NameRules.validate` 済み）
    public let confirmationCode: Int
    public let source: String            // 送り元の数字の表記（名前なら "?"）
    public let sourceClass: SourceClass
    /// 3 桁ずつ空けた確認番号（例 `012 345`）
    public var formattedCode: String { ConfirmationCode.format(confirmationCode) }
    /// 書き出し（`ShareScaleSnapshots`）が確認の窓を描くためにも使う
    public init(codeID: PairingID, name: String, confirmationCode: Int, source: String, sourceClass: SourceClass) {
        self.codeID = codeID; self.name = name; self.confirmationCode = confirmationCode; self.source = source; self.sourceClass = sourceClass
    }
}

/// 確認の窓（計画 2c-2 の窓が実装する。試験は偽物）
public protocol PairingApprover: AnyObject, Sendable {
    /// 確認の窓を出し、押された答えを返す（true =「追加する」）。複数の接続から同時に呼ばれうる。
    /// 呼ばれた時点で Task が取り消し済みなら窓を出さずに false を返す。`withdraw` の後も必ず答え（false）を返して戻る
    func requestApproval(_ request: ApprovalRequest) async -> Bool
    /// 承認待ちが取り消された（60 秒の時間切れ・見る側が閉じた・Host がその接続を切った）。窓を取り下げる。
    /// 取り下げた後に押された答えは使われない（`requestApproval` は false で戻る）
    func withdraw(_ request: ApprovalRequest)
}

/// この Mac の名前と機種（`status` の `name`・`model`）
public struct HostIdentity: Sendable {
    public var name: @Sendable () -> String
    public var model: @Sendable () -> String
    public init(name: @escaping @Sendable () -> String, model: @escaping @Sendable () -> String) { self.name = name; self.model = model }

    /// コンピュータ名（システム設定 › 一般 › 共有）と機種名（`system_profiler` は遅いので最初の 1 回だけ。読めなければ hw.model）
    public static let system = HostIdentity(name: { SystemNames.computerName() ?? "" }, model: { SystemNames.model() })
}

public enum SystemNames {
    public static func computerName() -> String? { SCDynamicStoreCopyComputerName(nil, nil) as String? }
    /// `.local` の名前（`LocalHostName`）
    public static func localHostName() -> String? { SCDynamicStoreCopyLocalHostName(nil) as String? }
    private static let cachedModel: String = {
        let r = ChildProcess.run(URL(fileURLWithPath: "/usr/sbin/system_profiler"), ["SPHardwareDataType"], timeout: 10)
        if let line = r.output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Model Name:") }),
           let v = line.components(separatedBy: "Model Name:").last?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        return sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 ? String(cString: buf) : "Mac"
    }()
    public static func model() -> String { cachedModel }
}

/// Host の本体が担う応答（`HostApplication`。仕様「指示と応答」）。
/// - `status`: 名前・機種・一時停止・共有中・mode・仮想ディスプレイ・ambiguous・last_error・set_by・addrs
/// - `set`: 一時停止中は `paused`、前の指示の反映中は `busy`。mode と set_by を保存し、判定を起こして最大 3 秒待ってから `status`
/// - `log`: その見る側の範囲の記録（`HostLog.recent(for:)`）
/// - 名乗りの承認は `PairingApprover` に渡す（取り消されたら `withdraw`）
///
/// 可変の状態は持たない（状態は `ScaleMaintainer`・`HostLog` がそれぞれのロックで持つ）
public final class HostController: HostApplication, @unchecked Sendable {
    public let maintainer: ScaleMaintainer
    public let log: HostLog
    private weak var approver: PairingApprover?
    private let identity: HostIdentity
    private let addresses: @Sendable () -> (port: Int, addresses: [String])
    private let wallClock: @Sendable () -> Date
    public let setWait: Double

    /// - `approver` は弱く持つ（`HostRuntime` が強く持つ。無くなっていたら承認せず、記録に残す）
    /// - `addresses`: 今の通信口と候補アドレス（接続コードと同じ選び方）
    public init(maintainer: ScaleMaintainer, log: HostLog, approver: PairingApprover?, identity: HostIdentity,
                addresses: @escaping @Sendable () -> (port: Int, addresses: [String]),
                wallClock: @escaping @Sendable () -> Date = { Date() }, setWait: Double = 3) {
        self.maintainer = maintainer; self.log = log; self.approver = approver; self.identity = identity
        self.addresses = addresses; self.wallClock = wallClock; self.setWait = setWait
    }

    // ---- HostApplication ----

    public func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String, sourceClass: SourceClass) async -> Bool {
        guard let approver else {
            log.write("pairing requested by \"\(name)\" from \(source) (\(sourceClass.rawValue)) declined: no approval window")
            return false
        }
        let req = ApprovalRequest(codeID: codeID, name: name, confirmationCode: confirmationCode, source: source, sourceClass: sourceClass)
        log.write("pairing requested by \"\(name)\" from \(source) (\(sourceClass.rawValue))")
        let ok = await withTaskCancellationHandler {
            await approver.requestApproval(req)
        } onCancel: {
            approver.withdraw(req)
        }
        log.write("pairing \(Task.isCancelled ? "withdrawn" : ok ? "approved" : "declined"): \"\(name)\"")
        return ok && !Task.isCancelled
    }

    public func respond(to request: Request, from id: PairingID) async -> Response {
        switch request {
        case .status:
            return status(for: id, maintainer.snapshot)
        case let .set(mode):
            let snap = maintainer.snapshot
            if snap.paused { return .error(.paused) }
            let m = ScaleMode(mode)
            switch maintainer.requestMode(m, by: id.hex, at: Int64(wallClock().timeIntervalSince1970)) {
            case .busy: return .error(.busy)
            case let .accepted(seq):
                log.write("set \(m.rawValue)", topic: .pairing(id))
                return status(for: id, await maintainer.waitUntilCovered(seq, timeout: setWait))
            }
        case .log:
            return .log(log.recent(for: id))
        case .hello, .reveal, .unpair:
            return .error(.badRequest)   // HostServer・HostConnection が扱う（ここには来ない）
        }
    }

    /// `status` の応答。候補アドレスが作れない時（「Tailscale 経由だけ」で Tailscale が無い時など）は `busy`
    func status(for id: PairingID, _ s: EngineSnapshot) -> Response {
        let (port, addrs) = addresses()
        let vd = s.target.flatMap { t -> StatusPayload.VirtualDisplay? in
            let source: StatusPayload.VirtualDisplay.DisplaySource = t.source == .learned ? .learned : .signature
            return StatusPayload.VirtualDisplay(resolution: "\(t.width)x\(t.height)", scaling: t.scale >= 2 ? .twoX : .oneX, source: source)
        }
        let mode = s.mode.wire
        let setBy = s.setBy.map { StatusPayload.SetBy(byYou: $0.by == id.hex, at: max(0, $0.at)) }
        let payload = StatusPayload(name: identity.name(), model: identity.model(), paused: s.paused, session: s.session, mode: mode,
                                    virtualDisplay: vd, ambiguous: s.ambiguous, lastError: Self.lastError(s), setBy: setBy,
                                    port: port, addresses: addrs)
            // 解像度が 5 桁を超えるなどで作れない時は、仮想ディスプレイ無しで作り直す
            ?? StatusPayload(name: identity.name(), model: identity.model(), paused: s.paused, session: s.session, mode: mode,
                             virtualDisplay: nil, ambiguous: s.ambiguous, lastError: Self.lastError(s), setBy: setBy,
                             port: port, addresses: addrs)
        return payload.map { .status($0) } ?? .error(.busy)
    }

    /// `last_error` に出すもの: 奪い合い（ほかのアプリが倍率を何度も戻している）＞ 直近の失敗
    static func lastError(_ s: EngineSnapshot) -> String? {
        if s.contention { return "the scale keeps being changed back (another app may be changing it)" }
        return s.lastError
    }
}
