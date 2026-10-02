import Foundation

/// 送り元の分類。受け付けるか（M2）と、締め出し・同時接続でのまとめ方（H4）を 1 つの表で決める（上から順に最初に当てはまるもの）
public enum SourceClass: String, Equatable, Sendable {
    case loopback, privateV4, linkLocal, sharedCGNAT, uniqueLocal, sameNetworkGlobal, otherGlobal
}

public struct SourceDecision: Equatable, Sendable {
    public let sourceClass: SourceClass
    public let accepted: Bool
    /// 締め出し・同時接続の表のキー
    public let bucket: String
}

public enum SourceClassifier: Sendable {
    // 決まった字句から作る（正しいことは試験で確かめる）
    static let loopbackV4 = IPNetwork("127.0.0.0/8")!, loopbackV6 = IPNetwork("::1/128")!
    static let private10 = IPNetwork("10.0.0.0/8")!, private172 = IPNetwork("172.16.0.0/12")!, private192 = IPNetwork("192.168.0.0/16")!
    static let linkLocalV4 = IPNetwork("169.254.0.0/16")!, linkLocalV6 = IPNetwork("fe80::/10")!
    static let tailscaleV4 = IPNetwork("100.64.0.0/10")!, ula = IPNetwork("fc00::/7")!
    static let tailscaleV6 = IPNetwork("fd7a:115c:a1e0::/48")!

    /// `localNetworks` は Host の Wi‑Fi・有線のインターフェースから作った範囲（`LocalNetworks.make` で作る）
    public static func classify(_ a: IPAddress, localNetworks: [IPNetwork], allowGlobal: Bool) -> SourceDecision {
        // IPv4-mapped は IPAddress を作った時点で IPv4 に直っている（バイトから作った値でも）
        let host = a.text + (a.isV4 ? "/32" : "/128")
        func d(_ c: SourceClass, _ ok: Bool, _ bucket: String? = nil) -> SourceDecision {
            SourceDecision(sourceClass: c, accepted: ok, bucket: bucket ?? host)
        }
        if loopbackV4.contains(a) || loopbackV6.contains(a) { return d(.loopback, true) }
        if private10.contains(a) || private172.contains(a) || private192.contains(a) { return d(.privateV4, true) }
        if linkLocalV4.contains(a) || linkLocalV6.contains(a) { return d(.linkLocal, true) }
        if tailscaleV4.contains(a) { return d(.sharedCGNAT, true) }
        if ula.contains(a) { return d(.uniqueLocal, true) }
        if localNetworks.contains(where: { $0.contains(a) }) { return d(.sameNetworkGlobal, true) }
        if a.isV4 { return d(.otherGlobal, allowGlobal) }
        // IPv6 のグローバルは /64 でまとめる（先頭 8 バイトを残して 0 にしても IPv4-mapped の形にはならない）
        let masked = IPNetwork(a, prefix: 64).map { $0.address.text + "/64" }
        return d(.otherGlobal, allowGlobal, masked)
    }
}

/// Host のインターフェースの 1 つのアドレス（`LocalNetworks.make` に渡す）
public struct LocalInterface: Equatable, Sendable {
    public let kind: LocalNetworks.InterfaceKind
    public let address: IPAddress
    public let prefix: Int
    public init(kind: LocalNetworks.InterfaceKind, address: IPAddress, prefix: Int) {
        self.kind = kind; self.address = address; self.prefix = prefix
    }
}

/// 「同じネットワークのグローバル」の範囲を作る（Wi‑Fi・有線だけ。IPv6 は /64 以上、IPv4 は /16 以上の時だけ）
public enum LocalNetworks: Sendable {
    public enum InterfaceKind: Equatable, Sendable { case wifi, wiredEthernet, other }

    public static func make(_ interfaces: [LocalInterface]) -> [IPNetwork] {
        var out: [IPNetwork] = []
        for i in interfaces where i.kind != .other {
            guard i.prefix >= (i.address.isV4 ? 16 : 64), let n = IPNetwork(i.address, prefix: i.prefix), !out.contains(n) else { continue }
            out.append(n)
        }
        return out
    }
}
