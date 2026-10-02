import Foundation
import Network
import ShareScaleProtocol

public enum NetError: Error, Equatable, Sendable {
    /// 通信の失敗の中身（Network.framework の `NWError` の種類と値）。見る側の案内の区別に使う
    public enum Cause: Equatable, Sendable {
        case tls(OSStatus)   // TLS の失敗（誤った秘密では -9820 など）
        case posix(Int32)    // POSIX の番号（ECONNREFUSED・ENETUNREACH・EHOSTUNREACH など）
        case dns(Int32)      // 名前の解決の失敗（DNSServiceErrorType）
        case other

        public init(_ e: NWError) {
            switch e {
            case let .tls(s): self = .tls(s)
            case let .posix(c): self = .posix(c.rawValue)
            case let .dns(d): self = .dns(d)
            default: self = .other   // 新しい SDK の種類（wifiAware など）。古い SDK でも組み立てられるよう、名前では書かない
            }
        }
    }
    /// 時間切れになった段階
    public enum Stage: String, Sendable { case connecting, sending, receiving }

    case handshakeFailed(Cause)         // TLS の手続きが成立しない（誤った秘密など。中身は常に .tls）
    case unreachable(Cause)             // つながらない・届かない（TLS 以外の失敗）
    case localNetworkDenied             // ローカルネットワークの許可が無い（.waiting で経路の理由が localNetworkDenied）
    case timedOut(Stage)
    case closed                         // 相手が閉じた
    case cancelled                      // 呼び出し元のタスクが取り消された
    case session(SessionCheck.Failure)  // 版・方式・ekm の確かめに失敗
    case frame(LineFraming.FrameRejection)
    case invalidRequest                 // 書き出せない指示（名前の規則違反・1 往復で送れない名乗り・乱数を作れない時など）
    case malformedResponse
    case rejected(ErrorCode)            // Host が失敗を返した（名乗りの拒否・時間切れの not_paired など）
}

/// 1 回だけ結果を返す（時間切れ・取り消し・完了が重なっても二重に返さない）。continuation はロックの外で再開する。
/// 可変の状態（`k`）は `lock` で守る
final class Once<T: Sendable, E: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var k: CheckedContinuation<T, E>?
    init(_ k: CheckedContinuation<T, E>) { self.k = k }
    /// 返したら true（すでに返していたら false）
    @discardableResult func resume(_ r: Result<T, E>) -> Bool {
        guard let c = lock.withLock({ () -> CheckedContinuation<T, E>? in let c = k; k = nil; return c }) else { return false }
        c.resume(with: r)
        return true
    }
}

extension Once where E == Never {
    @discardableResult func resume(returning v: T) -> Bool { resume(.success(v)) }
}

/// ロックで守った 1 つの値（後から入れる）。可変の状態（`v`）は `lock` で守る
final class Slot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.withLock { v = x } }
    var value: T? { lock.withLock { v } }
}

/// 接続ごとのキューの名前（番号を付けて見分けられるようにする）
enum QueueNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0
    static func next(_ prefix: String) -> String {
        lock.withLock { counter += 1; return "\(prefix).\(counter)" }
    }
}

/// NWConnection を、決まった時刻までの読み書きとして扱う（1 接続につき 1 つ）。
/// 時間切れ・呼び出し元のタスクの取り消しは、接続を閉じて知らせる（NWConnection の読み取りは取り消せないため）。
/// 可変の状態（読み残し `buffer`）は `lock` で守る。NWConnection の通知は `queue` の上で受ける
final class Channel: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer = Data()

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    convenience init(_ connection: NWConnection, label: String) {
        self.init(connection, queue: DispatchQueue(label: QueueNames.next(label)))
    }

    /// 締め切りと取り消しのある 1 回の待ち。`start` で読み書きを始め、結果を `once` に返す。
    /// 締め切りのタイマーは待ちが終わったら取り消す
    private func wait<T: Sendable>(until deadline: DispatchTime, stage: NetError.Stage,
                                   _ start: (Once<T, Error>) -> Void) async throws -> T {
        let connection = self.connection
        let slot = Slot<Once<T, Error>>()
        let timer = DispatchWorkItem {
            if slot.value?.resume(.failure(NetError.timedOut(stage))) == true { connection.cancel() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
                let once = Once(k)
                slot.set(once)
                queue.asyncAfter(deadline: deadline, execute: timer)
                start(once)
                if Task.isCancelled, once.resume(.failure(NetError.cancelled)) { connection.cancel() }   // 始める前に取り消されていた
            }
        } onCancel: {
            if slot.value?.resume(.failure(NetError.cancelled)) == true { connection.cancel() }
        }
    }

    /// `.ready` まで待つ。失敗・時間切れは NetError。
    /// 未開始の接続を渡すのが基本（ここで始める）。開始済みの接続でも動く（今の状態にも同じ処理を当てる）
    func waitReady(until deadline: DispatchTime) async throws {
        let connection = self.connection
        try await wait(until: deadline, stage: .connecting) { (once: Once<Void, Error>) in
            let handle: @Sendable (NWConnection.State) -> Void = { [weak connection] st in
                switch st {
                case .ready: once.resume(.success(()))
                case let .failed(e):
                    once.resume(.failure(Self.stateError(e, unsatisfiedReason: nil))); connection?.cancel()
                case let .waiting(e):
                    once.resume(.failure(Self.stateError(e, unsatisfiedReason: connection?.currentPath?.unsatisfiedReason)))
                    connection?.cancel()
                case .cancelled: once.resume(.failure(NetError.closed))
                default: break
                }
            }
            connection.stateUpdateHandler = handle
            handle(connection.state)   // 開始済み（すでに .ready など）の接続にも当てる
            if connection.state == .setup { connection.start(queue: queue) }
        }
    }

    /// `.failed`・`.waiting` の分け方。TLS の失敗は `handshakeFailed`（.waiting で届くこともある。試作 6・7）、
    /// ローカルネットワークの許可が無い（.waiting で経路の理由が localNetworkDenied。仕様「macOS の権限」）は `localNetworkDenied`、
    /// ほかは `unreachable`
    static func stateError(_ error: NWError, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> NetError {
        if case .tls = error { return .handshakeFailed(NetError.Cause(error)) }
        if unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        return .unreachable(NetError.Cause(error))
    }

    /// 改行までの 1 行（改行を除く）。上限を超える・`\r` を含む行は拒否して閉じる。
    /// 改行の後のバイトは、改行と同じ受信の塊に入っていた時だけ見つかり、拒否して閉じる
    /// （後から別の塊で届いたバイトは、この読み取りでは見えない）
    func readLine(limit: Int, until deadline: DispatchTime) async throws -> Data {
        while true {
            let result: LineFraming.Result = lock.withLock { LineFraming.extract(buffer, limit: limit) }
            switch result {
            case let .line(l): lock.withLock { buffer = Data() }; return l
            case let .reject(r): connection.cancel(); throw NetError.frame(r)
            case .needMore: break
            }
            let chunk = try await receive(until: deadline)
            lock.withLock { buffer.append(chunk) }
        }
    }

    private func receive(until deadline: DispatchTime) async throws -> Data {
        let connection = self.connection
        return try await wait(until: deadline, stage: .receiving) { (once: Once<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                if let data, !data.isEmpty { once.resume(.success(data)) } else { once.resume(.failure(NetError.closed)) }
            }
        }
    }

    func send(_ data: Data, until deadline: DispatchTime) async throws {
        let connection = self.connection
        try await wait(until: deadline, stage: .sending) { (once: Once<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                once.resume(error == nil ? .success(()) : .failure(NetError.closed))
            })
        }
    }

    /// 接続の終わりを知らせる。`.ready` の後、相手から次の指示が来ないはずの間（承認待ち）に呼ぶ。
    /// 状態の `.cancelled`／`.failed` に加えて、読み取りを 1 つ置いて相手の終わりも見る
    /// （相手が閉じても（close_notify・FIN）状態は `.ready` のままで、状態だけでは分からないため）。
    /// 読み取りに何かが届いた（バイト・終わり・エラー）ら、それも終わりとして扱う（この間に送られるバイトは規則違反）
    func onEnd(_ f: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { st in
            switch st {
            case .cancelled, .failed: f()
            default: break
            }
        }
        switch connection.state {   // 置き換える前に終わっていた場合
        case .cancelled, .failed: f()
        default: break
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in f() }
    }

    func close() { connection.cancel() }
}
