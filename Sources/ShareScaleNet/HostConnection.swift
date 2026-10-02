import Foundation
import Network
import ShareScaleProtocol

/// Host が照合に使う秘密の種類
public enum PairingKind: Sendable, Equatable {
    case code         // 接続コードの秘密（名乗りだけに使える）
    case registered   // 登録済みのペアリングの秘密（status・set・log・unpair）
}

/// Host の 1 接続の処理が、登録表・倍率の維持・確認の窓に問い合わせる相手（計画 2c で実装する）。
///
/// - 複数の接続から同時に呼ばれる（どの関数もスレッドに対して安全であること）
/// - 同期の関数（`lookup`・`authenticated`・`consumeCode`・`completePairing`）は長くは待たない（画面の操作や長い待ちをしない。短いロック待ちとファイルの保存はある）
/// - 非同期の関数（`approvePairing`・`respond`）は、上限・切断・取り消しの時に `HostConnection` がそのタスクを取り消し、
///   待たずに戻る。取り消しに応じない相手役のタスクは、`HostConnection` が戻った後も残る（返した値は使われない）
public protocol HostConnectionDelegate: AnyObject, Sendable {
    /// 照合の時点の登録表から引く（受け側を作った時の一覧ではなく、今の表）
    func lookup(_ id: PairingID) -> (secret: Bytes32, kind: PairingKind)?
    /// 照合（proof の確かめ）が通った直後に呼ぶ（指示の中身を確かめる前。以後の結末が `bad_request` などでも「照合に成功した」）。
    /// Host の受け付けはこれで、接続とペアリングの結び付け（解除で切るため）・登録済みの秘密での確定と最終接続・「知っている送り元」を記録する。
    /// 既定の実装は何もしない
    func authenticated(_ id: PairingID, kind: PairingKind)
    /// 名乗りの proof が通った時点で呼ぶ。コードを使用済みにできたら true（期限切れ・使用済みなら false）
    func consumeCode(_ id: PairingID) -> Bool
    /// 名乗りの 2 段の約束の 1 段目: 確認番号を出して承認を問うだけ（確認の窓を出し、押された答えを返す。true =「追加する」）。
    /// ここでは秘密を作らず、保存もしない。
    /// 承認待ちの上限（`HostTimeouts.approval`）・見る側が接続を閉じた時・`serve` のタスクが外から取り消された時は、
    /// 呼び出し側がこのタスクを取り消す（cancel）。取り消されたら確認の窓を取り下げる（`withTaskCancellationHandler` などで）。
    /// 取り消しの後に返した値は使わない
    func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String) async -> Bool
    /// 2 段目: 新しい秘密を作って保存し、それを返す（保存に失敗したら nil）。
    /// `approvePairing` が true を返し、しかもその時点で時間切れ・切断・取り消しのどれも起きていない時だけ、`HostConnection` が 1 回呼ぶ。
    /// これにより、確認の窓を取り下げた後に秘密が保存されることは無い。
    /// - 保存の後でも、応答を送れない（`.sendFailed`）・取り消される（`.cancelled`）ことはある。その時、見る側は新しい秘密を持たない。
    ///   このペアリングは新しい秘密で一度も照合に成功しないので、名乗りの後の 10 分の自動解除で片付く
    /// - その 10 分を数え始めるのは、この呼び出し（保存した時点）から
    func completePairing(codeID: PairingID, name: String, source: String) -> Bytes32?
    /// 名乗り以外の指示への応答。1 接続の全体の上限（`HostTimeouts.total`）までに返らなければ、応答せずに接続を閉じる
    /// （このタスクは取り消す。取り消しの後に返した値は使わない）
    func respond(to request: Request, from id: PairingID) async -> Response
}

public extension HostConnectionDelegate {
    func authenticated(_ id: PairingID, kind: PairingKind) {}
}

/// 時間の上限（仕様「時間の上限」）。
/// 承認待ち（`approval`）はスリープ中も進む時計（`ContinuousClock`）で数える（確認の窓を出したまま眠っても、起きた時に上限を過ぎていれば終わる）。
/// ほかはすべて `DispatchTime`（起動してからの時計で、スリープ中は止まる）で数える
public struct HostTimeouts: Sendable {
    public var handshake: Double = 5       // 受け付け（`serve` の `acceptedAt`）から .ready まで
    public var firstRequest: Double = 5    // .ready から最初の指示まで
    public var total: Double = 10          // 受け付けから数える 1 接続の全体（名乗り以外は応答を送り終えるまで。名乗りでは確認の窓を出すまで）
    public var reveal: Double = 5          // 名乗り: r を送ってから開示まで（全体の上限も超えない）
    public var approval: Double = 60       // 名乗り: 承認待ち（ContinuousClock）
    public var afterApproval: Double = 5   // 名乗り: 承認の答えが出てから応答を送り終えるまで
    public init() {}
    public static let standard = HostTimeouts()
}

/// 照合できない・名乗りが終わった理由
public enum NotPairedReason: String, Sendable {
    case noAuth               // 最初の指示に照合用の値が無い・形が違う
    case proof                // 未登録の id・proof が合わない
    case codeUsedOrExpired    // 使用済み・期限切れのコード
    case noReveal             // 開示が来ない・切れた
    case revealUnreadable     // 開示の行が読めない（応答せずに切断）
    case revealVersion        // 開示の v が 1 以外
    case commitment           // 約束と開示が合わない
    case declined             // 「追加しない」
    case approvalTimeout      // 承認待ちの上限
    case peerClosed           // 承認待ちの間に接続が切れた
}

/// 照合の前に、応答せずに切断した理由
public enum DropReason: Equatable, Sendable {
    case frame(LineFraming.FrameRejection)   // 上限超え・\r・改行の後のバイト
    case request(RequestReader.DropReason)   // JSON でない・オブジェクトでない・v が無い
}

/// 1 接続の結末（締め出し・記録の判断は呼び出し側が行う。仕様「攻撃への備え」の「失敗」に数えるかは `countsAsFailure`）
public enum HostOutcome: Equatable, Sendable {
    case served(PairingID, Request.Kind)
    case paired(codeID: PairingID)
    case handshakeFailed
    case handshakeTimeout
    case sessionRejected(SessionCheck.Failure)
    case noRequest                       // TLS は成立したが、指示が来ない・時間切れ・切れた
    case dropped(DropReason)             // 照合の前: 読めない行・上限超えなど（応答せずに切断）
    case unsupportedVersion              // 照合の前: v が 1 以外
    case notPaired(NotPairedReason)
    case badRequest(PairingID)           // 照合の後の規則違反
    case sendFailed                      // 応答を送れない
    case delegateTimeout                 // 応答を作る相手役（Host 側）が全体の上限までに返らない（応答せずに切断）
    case cancelled                       // serve のタスクが外から取り消された（接続を閉じてすぐ戻る。解除したペアリングの接続を切る時など）
    case saveFailed(codeID: PairingID)   // 承認されたが、新しい秘密を保存できない（not_paired を返す）
    case randomFailed                    // 乱数を作れない（応答せずに切断）

    /// 照合の前の切断、照合と名乗りの失敗、名乗りの途中の終わりは数える。
    /// Host 側の都合（遅れ・保存の失敗・乱数の失敗・送信の失敗・取り消し）と、照合の後の規則違反は数えない
    public var countsAsFailure: Bool {
        switch self {
        case .handshakeFailed, .handshakeTimeout, .sessionRejected, .noRequest, .dropped, .unsupportedVersion, .notPaired: return true
        case .served, .paired, .badRequest, .sendFailed, .delegateTimeout, .cancelled, .saveFailed, .randomFailed: return false
        }
    }
}

/// Host の 1 接続を最後まで扱う（仕様「接続相手の確定」「指示と応答」「名乗りと確認番号」「時間の上限」）
public enum HostConnection {
    /// 1 接続を最後まで扱い、結末を返す。
    /// - `connection` は未開始のものを渡すのが基本（ここで始める）。開始済みでも動く
    /// - `acceptedAt` は受け付けた時刻。手続きの上限と全体の上限はここから数える（受け付けてから `serve` まで待たせた場合のため）
    /// - `serve` を動かすタスクが外から取り消されたら、どの段階でも接続を閉じてすぐ戻り、結末は `.cancelled`
    ///   （ただし応答を送り終えた `.served`・`.paired` はそのまま返す）。相手役の呼び出し中なら、そのタスクも取り消す
    public static func serve(_ connection: NWConnection, delegate: HostConnectionDelegate,
                             timeouts: HostTimeouts = .standard, acceptedAt: DispatchTime = .now()) async -> HostOutcome {
        let session = Session(connection: connection, ch: Channel(connection, label: "sharescale.host.conn"),
                              delegate: delegate, t: timeouts, acceptedAt: acceptedAt)
        let o = await session.run()
        switch o {
        case .served, .paired: return o
        default: return Task.isCancelled ? .cancelled : o
        }
    }
}

/// 1 接続の処理の段: handshake → readFirst → authenticate → serveRequest／serveHello（→ readReveal → awaitApproval）
private struct Session: Sendable {
    let connection: NWConnection
    let ch: Channel
    let delegate: HostConnectionDelegate
    let t: HostTimeouts
    let acceptedAt: DispatchTime
    var totalDeadline: DispatchTime { acceptedAt + t.total }

    /// 次の段へ進むか、結末で終わるか
    enum Step<T> { case next(T), done(HostOutcome) }

    /// 照合を通った最初の指示
    struct Verified {
        let id: PairingID
        let kind: PairingKind
        let request: Request
        let ekm: Bytes32
    }

    func run() async -> HostOutcome {
        defer { ch.close() }
        let ekm: Bytes32, line: Data, v: Verified
        switch await handshake() { case let .done(o): return o; case let .next(x): ekm = x }
        switch await readFirst() { case let .done(o): return o; case let .next(x): line = x }
        switch await authenticate(line, ekm: ekm) { case let .done(o): return o; case let .next(x): v = x }
        if case let .hello(name, commitment) = v.request { return await serveHello(v, name: name, commitment: commitment) }
        return await serveRequest(v)
    }

    /// 応答を送り（`response` が nil なら送らない）、結末を返す。`required` なら、送れなかった時は `.sendFailed`
    func finish(_ outcome: HostOutcome, replying response: Response?, until deadline: DispatchTime, required: Bool = false) async -> HostOutcome {
        guard let response else { return outcome }
        let sent = (try? await ch.send(response.encoded(), until: deadline)) != nil
        return sent || !required ? outcome : .sendFailed
    }

    /// TLS の手続き（受け付けから handshake 秒）→ 版・方式の確かめ → ekm
    func handshake() async -> Step<Bytes32> {
        do { try await ch.waitReady(until: acceptedAt + t.handshake) }
        catch NetError.timedOut { return .done(.handshakeTimeout) }
        catch { return .done(.handshakeFailed) }
        switch SessionCheck.verify(connection) {
        case let .success(e): return .next(e)
        case let .failure(f): return .done(.sessionRejected(f))   // 版・方式が違う・ekm を作れない: 読まずに応答せずに切断
        }
    }

    /// 最初の指示の 1 行（.ready から firstRequest 秒、かつ全体の上限まで）
    func readFirst() async -> Step<Data> {
        do { return .next(try await ch.readLine(limit: Limits.requestMaxBytes, until: min(.now() + t.firstRequest, totalDeadline))) }
        catch let NetError.frame(r) { return .done(.dropped(.frame(r))) }
        catch { return .done(.noRequest) }
    }

    /// 読み取りの 1 段目 → 今の登録表で照合（定数時間）→ 中身の確かめ
    func authenticate(_ line: Data, ekm: Bytes32) async -> Step<Verified> {
        switch RequestReader.open(line, first: true) {
        case let .drop(reason): return .done(.dropped(.request(reason)))
        case .unsupportedVersion:
            return .done(await finish(.unsupportedVersion, replying: .error(.unsupportedVersion), until: totalDeadline))
        case .notPaired, .ready(auth: nil, body: _):
            return .done(await finish(.notPaired(.noAuth), replying: .error(.notPaired), until: totalDeadline))
        case let .ready(auth?, body):
            guard let entry = delegate.lookup(auth.id),
                  Binding.verify(proof: auth.proof, secret: entry.secret, id: auth.id, ekm: ekm) else {
                return .done(await finish(.notPaired(.proof), replying: .error(.notPaired), until: totalDeadline))
            }
            delegate.authenticated(auth.id, kind: entry.kind)   // 照合が通った（中身の確かめの前）
            guard let request = RequestReader.request(body, first: true) else {
                return .done(await finish(.badRequest(auth.id), replying: .error(.badRequest), until: totalDeadline))
            }
            return .next(Verified(id: auth.id, kind: entry.kind, request: request, ekm: ekm))
        }
    }

    /// 名乗り以外（登録済みの秘密だけ）。相手役の応答を全体の上限と競わせる
    func serveRequest(_ v: Verified) async -> HostOutcome {
        guard v.kind == .registered else {
            return await finish(.badRequest(v.id), replying: .error(.badRequest), until: totalDeadline)
        }
        let delegate = self.delegate, request = v.request, from = v.id
        switch await HostConnection.race(ch, until: .dispatch(totalDeadline), watchEnd: false, {
            await delegate.respond(to: request, from: from)
        }) {
        case let .value(response): return await finish(.served(v.id, request.kind), replying: response, until: totalDeadline, required: true)
        case .cancelled: return .cancelled
        case .deadline, .ended: return .delegateTimeout   // 応答せずに切断
        }
    }

    /// 名乗り（同じ接続で 2 往復。コードの秘密だけ）
    func serveHello(_ v: Verified, name: String, commitment: Bytes32) async -> HostOutcome {
        guard v.kind == .code else {
            return await finish(.badRequest(v.id), replying: .error(.badRequest), until: totalDeadline)
        }
        guard delegate.consumeCode(v.id) else {   // この時点でコードを使用済みにする（以後の結果にかかわらず）
            return await finish(.notPaired(.codeUsedOrExpired), replying: .error(.notPaired), until: totalDeadline)
        }
        guard let hostRandom = Bytes32.random() else { return .randomFailed }
        guard (try? await ch.send(Response.helloChallenge(hostRandom: hostRandom).encoded(), until: totalDeadline)) != nil else { return .sendFailed }
        let viewerRandom: Bytes32
        switch await readReveal(v.id) { case let .done(o): return o; case let .next(r): viewerRandom = r }
        guard Commitment.matches(commitment: commitment, reveal: viewerRandom) else {
            return await finish(.notPaired(.commitment), replying: .error(.notPaired), until: totalDeadline)
        }
        let code = ConfirmationCode.derive(ekm: v.ekm, viewerRandom: viewerRandom, hostRandom: hostRandom)
        let source = HostConnection.sourceText(endpoint: connection.endpoint)
        if case let .done(o) = await awaitApproval(codeID: v.id, name: name, code: code, source: source) { return o }
        // 承認が先に来た（時間切れ・切断より前）。取り消されていなければ、ここで初めて秘密を作って保存する
        guard !Task.isCancelled else { return .cancelled }
        guard let newSecret = delegate.completePairing(codeID: v.id, name: name, source: source) else {
            return await finish(.saveFailed(codeID: v.id), replying: .error(.notPaired), until: .now() + t.afterApproval)
        }
        return await finish(.paired(codeID: v.id), replying: .paired(newSecret: newSecret), until: .now() + t.afterApproval, required: true)
    }

    /// 開示の行（r を送ってから reveal 秒、かつ受け付けから total 秒）。一般の規則を当てる:
    /// 読めない → 応答せずに切断、v が 1 以外 → unsupported_version、形は読めるが規則違反 → bad_request。
    /// 応答の締め切りは、確認の窓を出すまでと同じ全体の上限
    func readReveal(_ id: PairingID) async -> Step<Bytes32> {
        let line: Data
        do { line = try await ch.readLine(limit: Limits.requestMaxBytes, until: min(.now() + t.reveal, totalDeadline)) }
        catch NetError.frame { return .done(.notPaired(.revealUnreadable)) }   // 上限超え・\r・改行の後のバイト
        catch { return .done(.notPaired(.noReveal)) }
        let body: JSONValue
        switch RequestReader.open(line, first: false) {
        case .drop, .notPaired: return .done(.notPaired(.revealUnreadable))
        case .unsupportedVersion:
            return .done(await finish(.notPaired(.revealVersion), replying: .error(.unsupportedVersion), until: totalDeadline))
        case let .ready(_, b): body = b
        }
        guard case let .reveal(viewerRandom)? = RequestReader.request(body, first: false) else {
            return .done(await finish(.badRequest(id), replying: .error(.badRequest), until: totalDeadline))
        }
        return .next(viewerRandom)
    }

    /// 承認待ち（ContinuousClock で approval 秒）。上限・接続の終わり・取り消しのどれかが先なら、承認のタスクを取り消す（確認の窓を取り下げさせる）
    func awaitApproval(codeID: PairingID, name: String, code: Int, source: String) async -> Step<Void> {
        let delegate = self.delegate
        let deadline = ContinuousClock.now + .seconds(t.approval)
        switch await HostConnection.race(ch, until: .continuous(deadline), watchEnd: true, {
            await delegate.approvePairing(codeID: codeID, name: name, confirmationCode: code, source: source)
        }) {
        case .value(true): return .next(())
        case .value(false):
            return .done(await finish(.notPaired(.declined), replying: .error(.notPaired), until: .now() + t.afterApproval))
        case .deadline:
            return .done(await finish(.notPaired(.approvalTimeout), replying: .error(.notPaired), until: .now() + t.afterApproval))
        case .ended: return .done(.notPaired(.peerClosed))
        case .cancelled: return .done(.cancelled)
        }
    }
}

extension HostConnection {
    enum Waited<T: Sendable>: Sendable { case value(T), deadline, ended, cancelled }

    /// race の締め切り。`dispatch` はスリープ中に止まる時計、`continuous` はスリープ中も進む時計
    enum RaceDeadline: Sendable {
        case dispatch(DispatchTime)
        case continuous(ContinuousClock.Instant)
    }

    /// `work` を別のタスクで動かし、値・締め切り・（`watchEnd` なら）接続の終わり・呼び出し元のタスクの取り消しのうち、
    /// 先に来たものを返す。値より先にほかが来たら、`work` のタスクを取り消して待たずに戻る（取り消しに応じない相手でも止まらない）。
    /// 締め切りのタイマーは終わったら取り消す
    static func race<T: Sendable>(_ ch: Channel, until deadline: RaceDeadline, watchEnd: Bool,
                                  _ work: @escaping @Sendable () async -> T) async -> Waited<T> {
        let state = RaceState<Waited<T>>()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Waited<T>, Never>) in
                let once = Once(k)
                state.setOnce(once)
                state.setWork(Task { once.resume(returning: .value(await work())) })
                switch deadline {
                case let .dispatch(d):
                    let item = CancelableWork { once.resume(returning: .deadline) }
                    state.setStopTimer { item.cancel() }
                    ch.queue.asyncAfter(deadline: d, execute: item.item)
                case let .continuous(instant):
                    let timer = Task {
                        if (try? await Task.sleep(until: instant, clock: .continuous)) != nil { once.resume(returning: .deadline) }
                    }
                    state.setStopTimer { timer.cancel() }
                }
                if watchEnd { ch.onEnd { once.resume(returning: .ended) } }
                if Task.isCancelled { once.resume(returning: .cancelled) }   // 取り消しが once を置く前に来ていた場合
            }
        } onCancel: {
            state.once?.resume(returning: .cancelled)
        }
        state.stopTimer()
        if case .value = result {} else { state.cancelWork() }
        return result
    }

    /// 送り元のアドレス。文字列を経ずに生のバイトから作る（IPv4-mapped は IPv4 に直し、ゾーンは付けない）。名前なら nil
    public static func sourceAddress(_ host: NWEndpoint.Host) -> ShareScaleProtocol.IPAddress? {
        switch host {
        case let .ipv4(a): return ShareScaleProtocol.IPAddress(bytes: [UInt8](a.rawValue))
        case let .ipv6(a): return ShareScaleProtocol.IPAddress(bytes: [UInt8](a.rawValue))
        case .name: return nil
        @unknown default: return nil
        }
    }
    public static func sourceAddress(of endpoint: NWEndpoint) -> ShareScaleProtocol.IPAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return sourceAddress(host)
    }

    /// 確認の窓に出す送り元。アドレスでなければ "?"
    static func sourceText(_ host: NWEndpoint.Host) -> String { sourceAddress(host)?.text ?? "?" }
    static func sourceText(endpoint: NWEndpoint) -> String { sourceAddress(of: endpoint)?.text ?? "?" }
}

/// 取り消せる `DispatchWorkItem`（`cancel` はどのスレッドから呼んでもよいが、`DispatchWorkItem` は Sendable と宣言されていないので包む）
struct CancelableWork: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ work: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: work) }
    func cancel() { item.cancel() }
}

/// race の 1 回分: 結果を返す口、`work` のタスク、締め切りのタイマーの止め方（取り消しの口からも触る）。
/// 可変の状態（`o`・`work`・`stop`）は `lock` で守る
final class RaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var o: Once<T, Never>?
    private var work: Task<Void, Never>?
    private var stop: (@Sendable () -> Void)?
    var once: Once<T, Never>? { lock.withLock { o } }
    func setOnce(_ x: Once<T, Never>) { lock.withLock { o = x } }
    func setWork(_ t: Task<Void, Never>) { lock.withLock { work = t } }
    func setStopTimer(_ f: @escaping @Sendable () -> Void) { lock.withLock { stop = f } }
    func cancelWork() { lock.withLock { work }?.cancel() }
    func stopTimer() { lock.withLock { stop }?() }
}
