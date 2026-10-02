import Foundation
import Network
import ShareScaleProtocol

/// 見る側の通信。
/// - `exchange`（静的）: 1 往復の指示（status・set・log・unpair）を 1 つの接続で
/// - `pair`（静的）: 名乗り全体（接続コードの秘密で hello → 確認番号 → reveal → 新しい秘密）を 1 つの接続で
/// - `open` → `exchange`／`pair`（インスタンス）: 見る側の候補の試し方（仕様「見る側」。計画 2d-1 の `Connector`）のために、
///   つなぐ（`.ready`＋版・方式の確認）ことと、指示を送ることを分けたもの。開いたまま選ばれなかった接続は `close()`
///
/// 1 接続の中身（つなぐ → 版・方式を確かめ ekm を取り出す → 最初の指示に proof を付けて送る → 応答を読む）。
/// 可変の状態は持たない（すべて `let`。読み書きの状態は `Channel` が自分のロックで守る）
public final class ViewerChannel: @unchecked Sendable {
    let ekm: Bytes32
    public let id: PairingID
    let secret: Bytes32
    let channel: Channel

    init(channel: Channel, id: PairingID, secret: Bytes32, ekm: Bytes32) {
        self.channel = channel; self.id = id; self.secret = secret; self.ekm = ekm
    }

    /// 手放されたら接続を閉じる（閉じ忘れで Host の枠を占め続けないように）
    deinit { channel.close() }

    /// `readyDeadline` までに TLS が成立し、版・方式の確かめに通れば（ekm を取り出して）開いた接続を返す。
    /// 失敗は `NetError`（届かない・ローカルネットワークの許可が無い・TLS の失敗・時間切れ・版と方式の拒否）。`parameters` は試験で差し替えるため
    public static func open(to endpoint: NWEndpoint, id: PairingID, secret: Bytes32, until readyDeadline: DispatchTime,
                            parameters: NWParameters? = nil) async throws -> ViewerChannel {
        let conn = NWConnection(to: endpoint, using: parameters ?? TLSSettings.parameters(id: id, secret: secret))
        let ch = Channel(conn, label: "sharescale.viewer")
        try await ch.waitReady(until: readyDeadline)
        switch SessionCheck.verify(conn) {
        case let .success(ekm): return ViewerChannel(channel: ch, id: id, secret: secret, ekm: ekm)
        case let .failure(f): ch.close(); throw NetError.session(f)
        }
    }

    static func open(to endpoint: NWEndpoint, id: PairingID, secret: Bytes32, readyTimeout: Double = 5,
                     parameters: NWParameters? = nil) async throws -> ViewerChannel {
        try await open(to: endpoint, id: id, secret: secret, until: .now() + readyTimeout, parameters: parameters)
    }

    /// 接続の最初の指示（proof を付ける）。名前の規則違反など、書き出せない指示は invalidRequest
    func sendFirst(_ request: Request, until deadline: DispatchTime) async throws {
        let auth = Auth(id: id, proof: Binding.proof(secret: secret, id: id, ekm: ekm))
        guard let line = request.encodedAsFirst(auth: auth) else { throw NetError.invalidRequest }
        try await channel.send(line, until: deadline)
    }

    func sendFirst(_ request: Request, timeout: Double = 5) async throws {
        try await sendFirst(request, until: .now() + timeout)
    }

    /// 名乗りの 2 つ目の指示（開示）
    func sendReveal(_ random: Bytes32, until deadline: DispatchTime) async throws {
        guard let line = Request.reveal(random: random).encodedAsReveal() else { throw NetError.invalidRequest }
        try await channel.send(line, until: deadline)
    }

    func sendReveal(_ random: Bytes32, timeout: Double = 5) async throws {
        try await sendReveal(random, until: .now() + timeout)
    }

    /// 応答を 1 つ読む（上限 16 KiB。形が違えば malformedResponse）
    func receive(expecting: Response.Expectation, until deadline: DispatchTime) async throws -> Response {
        let line = try await channel.readLine(limit: Limits.responseMaxBytes, until: deadline)
        guard let r = try? Response.decode(line, expecting: expecting) else { channel.close(); throw NetError.malformedResponse }
        return r
    }

    func receive(expecting: Response.Expectation, timeout: Double) async throws -> Response {
        try await receive(expecting: expecting, until: .now() + timeout)
    }

    /// 接続を閉じる（選ばれなかった接続・使い終えた接続）。何度呼んでもよい
    public func close() { channel.close() }

    /// 開いた接続で 1 往復の指示（status・set・log・unpair）を行う（接続の最初の指示として proof を付けて送り、応答を読む。1 接続に 1 回だけ）。
    /// 送信・受信を `deadline` で打ち切る。終わったら閉じる（Host も応答の後に閉じる）。
    /// Host の失敗の応答（`not_paired` など）は `Response.error` として返す。名乗り（hello・reveal）は送らずに `invalidRequest` を投げる
    public func exchange(_ request: Request, expecting: Response.Expectation, until deadline: DispatchTime) async throws -> Response {
        switch request.kind {
        case .hello, .reveal: throw NetError.invalidRequest
        case .status, .set, .log, .unpair: break
        }
        defer { close() }
        try await sendFirst(request, until: deadline)
        return try await receive(expecting: expecting, until: deadline)
    }

    /// 開いた接続で名乗り全体を行う（`pair` の静的な形と同じ。`id`・`secret` は接続コードのもの）。終わったら閉じる
    public func pair(name: String, showCode: @Sendable (Int) -> Void, until deadline: DispatchTime) async throws -> Bytes32 {
        defer { close() }
        guard let viewerRandom = Bytes32.random() else { throw NetError.invalidRequest }
        try await sendFirst(.hello(name: NameRules.sanitize(name), commitment: Commitment.make(viewerRandom)), until: deadline)
        let hostRandom: Bytes32
        switch try await receive(expecting: .hello, until: deadline) {
        case let .helloChallenge(r): hostRandom = r
        case let .error(code): throw NetError.rejected(code)
        default: throw NetError.malformedResponse
        }
        showCode(ConfirmationCode.derive(ekm: ekm, viewerRandom: viewerRandom, hostRandom: hostRandom))
        try await sendReveal(viewerRandom, until: deadline)
        switch try await receive(expecting: .reveal, until: deadline) {
        case let .paired(newSecret): return newSecret
        case let .error(code): throw NetError.rejected(code)
        default: throw NetError.malformedResponse
        }
    }

    /// 1 往復の指示（status・set・log・unpair）をまとめて行う。接続・送信・受信のすべてを、始めてから `timeout` 秒の 1 つの締め切りで打ち切る。
    /// Host の失敗の応答（`not_paired` など）は `Response.error` として返す（`pair` は投げる。扱いが違うので注意）。
    /// 名乗り（hello・reveal）は送らずに `invalidRequest` を投げる（送ると接続コードが使用済みになる。名乗りは `pair` で行う）
    public static func exchange(_ request: Request, expecting: Response.Expectation, to endpoint: NWEndpoint,
                                id: PairingID, secret: Bytes32, timeout: Double = 10) async throws -> Response {
        switch request.kind {
        case .hello, .reveal: throw NetError.invalidRequest
        case .status, .set, .log, .unpair: break
        }
        let deadline = DispatchTime.now() + timeout
        let ch = try await open(to: endpoint, id: id, secret: secret, until: min(.now() + 5, deadline))
        return try await ch.exchange(request, expecting: expecting, until: deadline)
    }

    /// 名乗り全体（仕様「名乗りと確認番号」）。`id`・`secret` は接続コードのもの。
    /// 名前は `NameRules.sanitize` で整えてから送る。確認番号は `showCode` で見る側の画面へ渡す（Host の承認を待つ間に表示する）。
    /// 承認されたら新しい秘密を返す。Host が失敗を返したら（拒否・時間切れ・使用済みのコードの `not_paired` など）`NetError.rejected`。
    /// 接続から応答までを、始めてから `timeout` 秒（既定 80 秒。確認待ちを含む）の 1 つの締め切りで打ち切る。
    /// Host が締め切りの直前に閉じた時などは、途中で `NetError.closed` が届くこともある。これもペアリングの失敗として扱う
    public static func pair(to endpoint: NWEndpoint, id: PairingID, secret: Bytes32, name: String,
                            showCode: @Sendable (Int) -> Void, timeout: Double = 80) async throws -> Bytes32 {
        let deadline = DispatchTime.now() + timeout
        let ch = try await open(to: endpoint, id: id, secret: secret, until: min(.now() + 5, deadline))
        return try await ch.pair(name: name, showCode: showCode, until: deadline)
    }
}
