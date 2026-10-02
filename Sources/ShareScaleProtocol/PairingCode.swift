import Foundation

/// 接続コード `sharescale1:` ＋ base64url（パディングなし）の JSON {"v","id","k","p","a","x"}
public struct PairingCode: Equatable, Sendable {
    public static let prefix = "sharescale1:"
    public let id: PairingID
    public let secret: Bytes32
    public let port: Int
    public let addresses: [String]
    public let expiresAt: Int64   // UNIX 秒（見る側は拒否に使わない）

    /// 見る側の検査を通るものだけ作れる: 通信口は 1〜65535、候補アドレスは 1〜8 件で
    /// それぞれ `CandidateAddress.isValid`、書き出した全体が 1 KiB 以内
    public init?(id: PairingID, secret: Bytes32, port: Int, addresses: [String], expiresAt: Int64) {
        guard Limits.portRange.contains(port), CandidateAddress.isValidList(addresses) else { return nil }
        self.id = id; self.secret = secret; self.port = port; self.addresses = addresses; self.expiresAt = expiresAt
        guard encoded().utf8.count <= Limits.pairingCodeMaxBytes else { return nil }
    }

    public enum Invalid: Error, Equatable, Sendable {
        case tooLarge, notSharescale, badEncoding, badJSON, unknownOrMissingKey, badVersion
        case badID, badSecret, badPort, badAddresses, badExpiry
    }

    public func encoded() -> String {
        let json = JSONWriter.write(.object([
            ("v", .integer(1)), ("id", .string(id.hex)), ("k", .string(secret.base64URL)),
            ("p", .integer(Int64(port))), ("a", .array(addresses.map { .string($0) })), ("x", .integer(expiresAt)),
        ]))
        return Self.prefix + Base64URL.encode(Data(json.utf8))
    }

    /// 見る側の検査。前後の空白は除いてから読む
    public static func decode(_ input: String) throws -> PairingCode {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Limits.pairingCodeMaxBytes else { throw Invalid.tooLarge }
        guard text.hasPrefix(prefix) else { throw Invalid.notSharescale }
        guard let body = Base64URL.decode(String(text.dropFirst(prefix.count))) else { throw Invalid.badEncoding }
        guard let parsed = try? StrictJSON.parse(body), parsed.members() != nil else { throw Invalid.badJSON }
        guard let m = parsed.exactKeys(["v", "id", "k", "p", "a", "x"]) else { throw Invalid.unknownOrMissingKey }
        guard case .integer(1)? = m["v"] else { throw Invalid.badVersion }
        guard case let .string(hex)? = m["id"], let id = PairingID(hex: hex) else { throw Invalid.badID }
        guard case let .string(k)? = m["k"], let secret = Bytes32(base64URL: k) else { throw Invalid.badSecret }
        guard case let .integer(p)? = m["p"], let port = Int(exactly: p), Limits.portRange.contains(port) else { throw Invalid.badPort }
        guard case let .array(items)? = m["a"] else { throw Invalid.badAddresses }
        var addrs: [String] = []
        for item in items {
            guard case let .string(a) = item else { throw Invalid.badAddresses }
            addrs.append(a)
        }
        guard CandidateAddress.isValidList(addrs) else { throw Invalid.badAddresses }
        guard case let .integer(x)? = m["x"] else { throw Invalid.badExpiry }
        // 読んだ字句は 1 KiB 以内なので、書き直した形（空白なし・エスケープなし）も 1 KiB 以内に収まる。
        // 今の init? の規則のうち上で確かめていないのは大きさだけなので、失敗は .tooLarge とする。
        // 注意: init? に規則を足した時は、ここより前に同じ確認と理由を足すこと（足さないと理由の表示がずれる）
        guard let code = PairingCode(id: id, secret: secret, port: port, addresses: addrs, expiresAt: x) else { throw Invalid.tooLarge }
        return code
    }

    /// 見る側の注意: 自分の時計で期限を 10 分以上過ぎているか（拒否はしない）
    public func probablyExpired(now: Int64) -> Bool {
        let (limit, overflow) = now.subtractingReportingOverflow(600)
        return !overflow && limit >= expiresAt   // 10 分以上過ぎている（どんな x でもあふれない）
    }
}
