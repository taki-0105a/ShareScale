import CryptoKit
import Foundation

/// 接続相手の確定（ペアリングID と TLS セッションの結び付け）
public enum Binding: Sendable {
    static let bindInfo = Data("ShareScale bind v1".utf8)
    static let proofLabel = Data("ShareScale-bind-v1".utf8)
    /// TLS エクスポーターのラベル（RFC 5705。登録外なので EXPERIMENTAL で始める）
    public static let exporterLabel = "EXPERIMENTAL-ShareScale-bind-v1"
    /// TLS エクスポーターから取り出す長さ（取り出した値は `Bytes32` にして渡す）
    public static let ekmLength = Bytes32.count

    /// bindKey = HKDF-SHA256(ikm: 秘密, salt: なし, info: "ShareScale bind v1", 32 バイト)
    static func bindKey(secret: Bytes32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret.data), info: bindInfo, outputByteCount: 32)
    }

    /// id は 32 文字の小文字 16 進の UTF-8 として入れる
    static func message(id: PairingID, ekm: Bytes32) -> Data {
        proofLabel + Data([0]) + Data(id.hex.utf8) + Data([0]) + ekm.data
    }

    /// proof = HMAC-SHA256(bindKey, "ShareScale-bind-v1" ‖ 0x00 ‖ id ‖ 0x00 ‖ ekm)（32 バイト）
    public static func proof(secret: Bytes32, id: PairingID, ekm: Bytes32) -> Bytes32 {
        let mac = HMAC<SHA256>.authenticationCode(for: message(id: id, ekm: ekm), using: bindKey(secret: secret))
        return Bytes32(Data(mac))!   // HMAC-SHA256 は常に 32 バイト
    }

    /// 定数時間で照合する
    public static func verify(proof: Bytes32, secret: Bytes32, id: PairingID, ekm: Bytes32) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof.data, authenticating: message(id: id, ekm: ekm), using: bindKey(secret: secret))
    }
}

/// 名乗りの約束（c = SHA-256(r_v)）
public enum Commitment: Sendable {
    public static func make(_ r: Bytes32) -> Bytes32 { Bytes32(Data(SHA256.hash(data: r.data)))! }   // SHA-256 は常に 32 バイト

    /// 定数時間で照合する（`Bytes32` の `==`）
    public static func matches(commitment: Bytes32, reveal r: Bytes32) -> Bool { make(r) == commitment }
}

/// 確認番号 = HKDF-SHA256(ikm: ekm, salt: なし, info: "ShareScale-sas-v1" ‖ 0x00 ‖ r_v ‖ r_h, 4 バイト) を
/// ビッグエンディアンの 32 ビット整数とみなし 1,000,000 で割った余り
public enum ConfirmationCode: Sendable {
    static let info = Data("ShareScale-sas-v1".utf8)

    public static func derive(ekm: Bytes32, viewerRandom rv: Bytes32, hostRandom rh: Bytes32) -> Int {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ekm.data), info: info + Data([0]) + rv.data + rh.data, outputByteCount: 4)
        let n = key.withUnsafeBytes { raw in raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return Int(n % 1_000_000)
    }

    /// 先頭 0 埋めの 6 桁を 3 桁ずつ空けて（例 "012 345"）
    /// - Precondition: `n` は 0〜999999（`derive` の結果だけを渡す）
    public static func format(_ n: Int) -> String {
        precondition((0..<1_000_000).contains(n))
        let s = String(format: "%06d", n)
        return String(s.prefix(3)) + " " + String(s.suffix(3))
    }
}

/// 長さが同じなら、中身によらず同じ手間で比べる
func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
