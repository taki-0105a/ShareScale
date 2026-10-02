import CryptoKit
import Network
import Security
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 確認番号の安全性の前提（仕様「脅威モデル」）: 見る側・Host の両方が、相手の ECDHE の公開値を検証する。
/// TLS 1.2 の最初のやり取りを手で組み立てる偽の相手から、不正な公開値（小さい位数の点・範囲外の値・曲線外の点・無限遠点）を送り、
/// 本物の側が illegal_parameter（47）で断ることを確かめる。正しい公開値（対照）では手続きが先に進む。
final class TLSPremiseTests: XCTestCase {
    // ---- TLS のバイト列の組み立て ----
    static func u16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    static func u24(_ v: Int) -> Data { Data([UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    static func handshake(_ type: UInt8, _ body: Data) -> Data { Data([type]) + u24(body.count) + body }
    static func record(_ type: UInt8, _ body: Data) -> Data { Data([type, 0x03, 0x03]) + u16(body.count) + body }
    static func ext(_ t: Int, _ body: Data) -> Data { u16(t) + u16(body.count) + body }
    static func random(_ n: Int) -> Data { var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b); return Data(b) }
    static func hex(_ h: String) -> Data { Data(stride(from: 0, to: h.count, by: 2).map { UInt8(h.dropFirst($0).prefix(2), radix: 16)! }) }

    struct Curve: Sendable { let id: Int; let name: String; let valid: @Sendable () -> Data; let bad: [(String, Data)] }
    static let curves: [Curve] = [
        Curve(id: 0x001d, name: "X25519", valid: { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }, bad: [
            ("すべて 0", Data(repeating: 0, count: 32)),
            ("1", Data([1] + [UInt8](repeating: 0, count: 31))),
            ("位数 8 a", hex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")),
            ("位数 8 b", hex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157")),
            ("p-1", hex("ec" + String(repeating: "ff", count: 30) + "7f")),
            ("p", hex("ed" + String(repeating: "ff", count: 30) + "7f")),
            ("p+1", hex("ee" + String(repeating: "ff", count: 30) + "7f")),
        ]),
        Curve(id: 0x0017, name: "P-256", valid: { P256.KeyAgreement.PrivateKey().publicKey.x963Representation },
              bad: [("曲線外", Data([4]) + random(64)), ("無限遠点", Data([0]))]),
        Curve(id: 0x0018, name: "P-384", valid: { P384.KeyAgreement.PrivateKey().publicKey.x963Representation },
              bad: [("曲線外", Data([4]) + random(96)), ("無限遠点", Data([0]))]),
        Curve(id: 0x0019, name: "P-521", valid: { P521.KeyAgreement.PrivateKey().publicKey.x963Representation },
              bad: [("曲線外", Data([4]) + random(132)), ("無限遠点", Data([0]))]),
    ]

    /// 生の TCP で TLS のレコードを読み書きする（同期。試験の中だけで使う）
    final class Raw: @unchecked Sendable {
        let c: NWConnection
        private var buf = Data()
        init(_ c: NWConnection) { self.c = c }
        static func connect(_ port: NWEndpoint.Port) -> Raw? {
            let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp); let s = DispatchSemaphore(value: 0)
            c.stateUpdateHandler = { if case .ready = $0 { s.signal() } }
            c.start(queue: DispatchQueue(label: "raw")); return s.wait(timeout: .now() + 3) == .success ? Raw(c) : nil
        }
        func send(_ d: Data) { let s = DispatchSemaphore(value: 0); c.send(content: d, completion: .contentProcessed { _ in s.signal() }); _ = s.wait(timeout: .now() + 3) }
        /// レコードを 1 つ（時間切れ・閉じたら nil）
        func read(timeout: Double) -> (type: UInt8, body: Data)? {
            let end = Date().addingTimeInterval(timeout)
            while true {
                if buf.count >= 5 {
                    let len = Int(buf[buf.startIndex + 3]) << 8 | Int(buf[buf.startIndex + 4])
                    if buf.count >= 5 + len {
                        let t = buf[buf.startIndex]; let b = Data(buf[(buf.startIndex + 5)..<(buf.startIndex + 5 + len)])
                        buf = Data(buf[(buf.startIndex + 5 + len)...]); return (t, b)
                    }
                }
                let left = end.timeIntervalSinceNow; if left <= 0 { return nil }
                let s = DispatchSemaphore(value: 0); let got = Box<Data>()
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in if let d { got.set(d) }; s.signal() }
                guard s.wait(timeout: .now() + left) == .success, let g = got.value, !g.isEmpty else { return nil }
                buf += g
            }
        }
        /// 決まった handshake の型（14 = ServerHelloDone など）が届くまで読む
        func readUntilHandshake(_ type: UInt8, timeout: Double) -> Bool {
            for _ in 0..<8 {
                guard let (t, b) = read(timeout: timeout), t == 22 else { return false }
                var i = b.startIndex
                while i + 4 <= b.endIndex {
                    if b[i] == type { return true }
                    i += 4 + (Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]))
                }
            }
            return false
        }
    }
    static func isIllegalParameterAlert(_ r: (type: UInt8, body: Data)?) -> Bool {
        guard let r, r.type == 21, r.body.count == 2 else { return false }
        return r.body[r.body.startIndex] == 2 && r.body[r.body.startIndex + 1] == 47
    }

    // ---- 偽の見る側 → 本物の Host ----
    /// `wait` 秒まで Host の返事を待つ（正しい公開値の対照では返事が無いので、短くする。断る時は返事が来た時点で戻るので、長くしても遅くならない）
    func hostReaction(to point: Data, curve: Int, host: LoopbackHost, id: PairingID, wait: Double = 4) -> (type: UInt8, body: Data)? {
        guard case let .hostPort(_, port) = host.endpoint, let r = Raw.connect(port) else { return nil }
        defer { r.c.cancel() }
        let exts = Self.ext(0x000a, Self.u16(2) + Self.u16(curve)) + Self.ext(0x000b, Data([1, 0])) + Self.ext(0xff01, Data([0]))
        let hello = Self.u16(0x0303) + Self.random(32) + Data([0]) + Self.u16(2) + Self.u16(0xCCAC) + Data([1, 0]) + Self.u16(exts.count) + exts
        r.send(Self.record(22, Self.handshake(1, hello)))
        guard r.readUntilHandshake(14, timeout: 3) else { return (0, Data()) }   // ServerHelloDone まで
        let ident = TLSSettings.identity(id)
        r.send(Self.record(22, Self.handshake(16, Self.u16(ident.count) + ident + Data([UInt8(point.count)]) + point)))
        return r.read(timeout: wait)
    }
    func testHostRejectsInvalidPublicValuesOnEveryCurve() throws {
        let d = FakeDelegate(); let id = pid(0xA1); d.register(id, secret(0x11), .registered)
        let host = try LoopbackHost(psks: [id: secret(0x11)], delegate: d); defer { host.stop() }
        for c in Self.curves {
            let control = hostReaction(to: c.valid(), curve: c.id, host: host, id: id, wait: 0.4)
            XCTAssertNil(control, "\(c.name): 正しい公開値では Host は断らずに続きを待つ")
            for (label, point) in c.bad {
                XCTAssertTrue(Self.isIllegalParameterAlert(hostReaction(to: point, curve: c.id, host: host, id: id)),
                              "\(c.name) \(label): Host が illegal_parameter で断る")
            }
        }
    }

    // ---- 偽の Host → 本物の見る側 ----
    func viewerReaction(to point: Data, curve: Int) throws -> (sent: (type: UInt8, body: Data)?, viewer: Error?) {
        let fake = try NWListener(using: loopbackParameters(.tcp))
        let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var sent: (type: UInt8, body: Data)?
        fake.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        fake.newConnectionHandler = { c in
            c.stateUpdateHandler = { st in
                guard case .ready = st else { return }
                DispatchQueue.global().async {
                    let r = Raw(c)
                    guard let (t, _) = r.read(timeout: 3), t == 22 else { done.signal(); return }
                    let e = Self.ext(0xff01, Data([0])) + Self.ext(0x000b, Data([1, 0]))
                    let sh = Self.u16(0x0303) + Self.random(32) + Data([0]) + Self.u16(0xCCAC) + Data([0]) + Self.u16(e.count) + e
                    let ske = Self.u16(0) + Data([3]) + Self.u16(curve) + Data([UInt8(point.count)]) + point
                    r.send(Self.record(22, Self.handshake(2, sh) + Self.handshake(12, ske) + Self.handshake(14, Data())))
                    sent = r.read(timeout: 2); done.signal(); c.cancel()
                }
            }
            c.start(queue: DispatchQueue(label: "fake.host"))
        }
        fake.start(queue: DispatchQueue(label: "fake.listener")); defer { fake.cancel() }
        guard ready.wait(timeout: .now() + 5) == .success, let port = fake.port else { throw NetError.timedOut(.connecting) }
        let viewerError = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var err: Error?
        Task {
            do { let ch = try await ViewerChannel.open(to: .hostPort(host: "127.0.0.1", port: port), id: pid(0xA1), secret: secret(0x11), readyTimeout: 3); ch.close() }
            catch { err = error }
            viewerError.signal()
        }
        _ = done.wait(timeout: .now() + 5); _ = viewerError.wait(timeout: .now() + 5)
        return (sent, err)
    }
    func testViewerRejectsInvalidPublicValuesOnEveryCurve() throws {
        for c in Self.curves {
            let control = try viewerReaction(to: c.valid(), curve: c.id)
            XCTAssertEqual(control.sent?.type, 22, "\(c.name): 正しい公開値では見る側が ClientKeyExchange を送る")
            for (label, point) in c.bad {
                let r = try viewerReaction(to: point, curve: c.id)
                XCTAssertTrue(Self.isIllegalParameterAlert(r.sent), "\(c.name) \(label): 見る側が illegal_parameter で断る")
                XCTAssertNotNil(r.viewer, "\(c.name) \(label): 見る側は開けない")
            }
        }
    }
}
