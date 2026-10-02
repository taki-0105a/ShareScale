import Foundation
import ShareScaleHostCore
import ShareScaleProtocol

/// この Mac 自身（`.local` の名前とインターフェースのアドレス）。候補アドレスがこの Mac 自身を指しているかの判定に使う。
///
/// 同じ Mac の中で ShareScale と ShareScale Host を動かすと、接続コードの候補（`<LocalHostName>.local` と自分の Tailscale の 100.x）は
/// 自分の utun のアドレスに向かい、macOS では接続が受理されるのに通信が進まない（実機確認 2026-09-30。試作で確認済みの現象）。
/// そこで `Connector` は、候補のどれかがこの Mac 自身を指していれば 127.0.0.1 でつなぐ（`Connector.Candidates.plan`）。
/// 判定は文字列の比較と、読み取ったアドレスの一覧だけで行う（名前解決はしない）
public struct LocalIdentity: Equatable, Sendable {
    /// `LocalHostName`（`.local` の前の部分）。読めなければ nil
    public var localHostName: String?
    /// この Mac のインターフェースのアドレス（`getifaddrs`）
    public var addresses: Set<IPAddress>

    public init(localHostName: String?, addresses: Set<IPAddress>) {
        self.localHostName = localHostName; self.addresses = addresses
    }

    /// 今のこの Mac（`SCDynamicStoreCopyLocalHostName` と `getifaddrs`。読み取りだけ）
    public static func current() -> LocalIdentity {
        LocalIdentity(localHostName: SystemNames.localHostName(), addresses: Set(InterfaceAddresses.read().map(\.address)))
    }

    /// 何も分からない（どの候補もこの Mac 自身とは見なさない）
    public static let none = LocalIdentity(localHostName: nil, addresses: [])

    /// 候補がこの Mac 自身を指しているか。
    /// - ホスト名: `<LocalHostName>.local` と大文字小文字を区別せずに一致する時だけ（名前解決はしない）
    /// - IP: この Mac のインターフェースのアドレスのどれかと一致する時。ただしループバック（127.0.0.0/8・::1）は除く（そのままつながるので足さない）
    public func pointsToSelf(_ candidate: String) -> Bool {
        if let ip = IPAddress(candidate) { return !Self.isLoopback(ip) && addresses.contains(ip) }
        guard let n = localHostName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return false }
        return candidate.lowercased() == (n + ".local").lowercased()
    }

    /// ループバック（127.0.0.0/8・::1）か
    public static func isLoopback(_ ip: IPAddress) -> Bool {
        ip.isV4 ? ip.bytes[0] == 127 : ip.bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// 同じ Mac の中の Host につなぐ時に使うアドレス（`CandidateAddress.isValid` を通る）
    public static let loopback = "127.0.0.1"
}
