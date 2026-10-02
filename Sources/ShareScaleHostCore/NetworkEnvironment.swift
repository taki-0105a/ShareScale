import Darwin
import Foundation
import Network
import ShareScaleProtocol

/// インターフェースの 1 つのアドレス（`getifaddrs` から）
public struct InterfaceAddress: Equatable, Sendable {
    public var name: String
    public var address: ShareScaleProtocol.IPAddress
    public var prefix: Int
    public init(name: String, address: ShareScaleProtocol.IPAddress, prefix: Int) { self.name = name; self.address = address; self.prefix = prefix }
}

public enum InterfaceAddresses {
    /// この Mac のインターフェースの IPv4・IPv6 のアドレスとプレフィックス長（読み取りだけ）
    public static func read() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [InterfaceAddress] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, let nm = p.pointee.ifa_netmask else { continue }
            let name = String(cString: p.pointee.ifa_name)
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                if let ip = ShareScaleProtocol.IPAddress(bytes: a) { out.append(InterfaceAddress(name: name, address: ip, prefix: prefixLength(m))) }
            case AF_INET6:
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                let m = nm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                if let ip = ShareScaleProtocol.IPAddress(bytes: a) { out.append(InterfaceAddress(name: name, address: ip, prefix: prefixLength(m))) }
            default: continue
            }
        }
        return out
    }

    /// 網のマスクの先頭から続く 1 のビットの数
    static func prefixLength(_ mask: [UInt8]) -> Int {
        var n = 0
        for b in mask {
            if b == 0xff { n += 8; continue }
            n += (~b).leadingZeroBitCount   // 例 0b1110_0000 → ~ は 0b0001_1111 → 3
            break
        }
        return n
    }
}

/// Tailscale のインターフェースの見つけ方の結果（仕様「受け付けるネットワーク」）
public enum TailscaleDetection: Equatable, Sendable {
    case none
    /// 100.64.0.0/10 の IPv4 だけを持つ utun（tailnet で IPv6 が無効。診断で案内する。100.64/10 は CGNAT なども使うので Tailscale とは決めない）
    case ipv4Only(interface: String, v4: ShareScaleProtocol.IPAddress)
    /// 100.64.0.0/10 の IPv4 と fd7a:115c:a1e0::/48 の IPv6 を両方持つ utun
    case found(interface: String, v4: ShareScaleProtocol.IPAddress, v6: ShareScaleProtocol.IPAddress)
}

/// 受け側をどこに結び付けるか
public enum ListenBinding: Equatable, Sendable {
    case anyInterface                // 全経路（既定）
    case interface(String)           // `requiredInterface` で Tailscale の utun に
    case localAddress(ShareScaleProtocol.IPAddress)     // utun の `NWInterface` が得られない時は、Tailscale の IPv4 アドレス（`requiredLocalEndpoint`）に
    case unavailable                 // 「Tailscale 経由だけ」で Tailscale が見つからない（受け付けない。全経路には戻さない）
}

/// ネットワークの様子（`NetworkMonitor` が作る）
public struct NetworkSnapshot: Equatable, Sendable {
    public var tailscale: TailscaleDetection = .none
    /// 「同じネットワークのグローバル」の範囲（Wi‑Fi・有線から。`LocalNetworks.make`）
    public var localNetworks: [IPNetwork] = []
    /// Wi‑Fi・有線のプライベート IPv4（候補アドレスが作れない時の予備）
    public var lanIPv4: [ShareScaleProtocol.IPAddress] = []
    /// `NWPathMonitor` の `availableInterfaces` に出たインターフェースの名前
    public var interfaceNames: Set<String> = []
    public init() {}
}

/// ネットワークの純粋な判定（インターフェースの一覧を渡して試す）
public enum NetworkEnvironment {
    static let tailscaleV4 = IPNetwork("100.64.0.0/10")!, tailscaleV6 = IPNetwork("fd7a:115c:a1e0::/48")!
    static let private10 = IPNetwork("10.0.0.0/8")!, private172 = IPNetwork("172.16.0.0/12")!, private192 = IPNetwork("192.168.0.0/16")!

    /// Tailscale のインターフェース = 100.64.0.0/10 の IPv4 と fd7a:115c:a1e0::/48 の IPv6 を両方持つ utun（名前の順で最初のもの）
    public static func detectTailscale(_ addresses: [InterfaceAddress]) -> TailscaleDetection {
        let byName = Dictionary(grouping: addresses.filter { $0.name.hasPrefix("utun") }, by: \.name)
        var v4Only: TailscaleDetection = .none
        for name in byName.keys.sorted() {
            let list = byName[name]!
            guard let v4 = list.first(where: { tailscaleV4.contains($0.address) })?.address else { continue }
            if let v6 = list.first(where: { tailscaleV6.contains($0.address) })?.address { return .found(interface: name, v4: v4, v6: v6) }
            if case .none = v4Only { v4Only = .ipv4Only(interface: name, v4: v4) }
        }
        return v4Only
    }

    /// インターフェースの一覧と種類（`NWPathMonitor` から。名前 → 種類）からネットワークの様子を作る
    public static func snapshot(addresses: [InterfaceAddress], kinds: [String: LocalNetworks.InterfaceKind]) -> NetworkSnapshot {
        var s = NetworkSnapshot()
        s.tailscale = detectTailscale(addresses)
        let lan = addresses.filter { kinds[$0.name] == .wifi || kinds[$0.name] == .wiredEthernet }
        s.localNetworks = LocalNetworks.make(lan.map { LocalInterface(kind: kinds[$0.name]!, address: $0.address, prefix: $0.prefix) })
        s.lanIPv4 = lan.map(\.address).filter { a in a.isV4 && [private10, private172, private192].contains { $0.contains(a) } }
        s.interfaceNames = Set(kinds.keys)
        return s
    }

    public static func binding(tailscaleOnly: Bool, snapshot: NetworkSnapshot) -> ListenBinding {
        guard tailscaleOnly else { return .anyInterface }
        guard case let .found(name, v4, _) = snapshot.tailscale else { return .unavailable }
        return snapshot.interfaceNames.contains(name) ? .interface(name) : .localAddress(v4)
    }

    /// 候補アドレス（接続コードの `a`・`status` の `addrs.a`。仕様「接続コード」）。
    /// 既定: `<LocalHostName>.local` と Tailscale の IPv4（IPv6 が無効の tailnet で IPv4 だけの utun も、既定では候補に入れる。
    /// 受け付けは送り元の分類で決まり、100.64/10 は既定で受け付けるため）。どちらも無ければ Wi‑Fi・有線のプライベート IPv4（最大 2 件）。
    /// 「Tailscale 経由だけ」: Tailscale のインターフェース（両方のアドレスを持つ utun）の IPv4 だけ（無ければ空）。
    /// 規則（`CandidateAddress.isValid`）に合わないものは入れない。最大 8 件
    public static func candidates(localHostName: String?, snapshot: NetworkSnapshot, tailscaleOnly: Bool) -> [String] {
        var out: [String] = []
        let tsV4: ShareScaleProtocol.IPAddress? = {
            switch snapshot.tailscale {
            case let .found(_, v4, _): return v4
            case let .ipv4Only(_, v4): return tailscaleOnly ? nil : v4
            case .none: return nil
            }
        }()
        if !tailscaleOnly, let n = localHostName, !n.isEmpty { out.append(n + ".local") }
        if let v4 = tsV4 { out.append(v4.text) }
        out = out.filter(CandidateAddress.isValid)
        if !tailscaleOnly && out.isEmpty { out = snapshot.lanIPv4.prefix(2).map(\.text).filter(CandidateAddress.isValid) }
        return Array(out.prefix(Limits.maxCandidateAddresses))
    }
}

/// `NWPathMonitor` を包み、変化のたびに `getifaddrs` から様子を作り直して、変わった時だけ知らせる。
/// 可変の状態（`monitor`・`interfaces`・`kinds`・`current`・`updates`・`notifiedOnce`）は `lock` で守る。通知は自分のキューから呼ぶ
public final class NetworkMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sharescale.host.network")
    private let readAddresses: @Sendable () -> [InterfaceAddress]
    private let onChange: @Sendable (NetworkSnapshot) -> Void
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var interfaces: [String: NWInterface] = [:]
    private var kinds: [String: LocalNetworks.InterfaceKind] = [:]
    private var current = NetworkSnapshot()
    private var updates = 0
    private var notifiedOnce = false

    /// - `readAddresses`: インターフェースのアドレスの読み方（試験で差し替える）
    /// - `onChange`: 様子が変わった時（最初の 1 回を含む）
    public init(readAddresses: @escaping @Sendable () -> [InterfaceAddress] = { InterfaceAddresses.read() },
                onChange: @escaping @Sendable (NetworkSnapshot) -> Void) {
        self.readAddresses = readAddresses; self.onChange = onChange
    }
    deinit { monitor?.cancel() }

    public func start() {
        let m: NWPathMonitor? = lock.withLock {
            guard monitor == nil else { return nil }
            let m = NWPathMonitor(); monitor = m; return m
        }
        guard let m else { return }
        m.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        m.start(queue: queue)
    }
    public func stop() {
        let m: NWPathMonitor? = lock.withLock { defer { monitor = nil }; return monitor }
        m?.cancel()
    }
    /// 今の様子を作り直す（スリープからの復帰など、経路の変化の通知が来ない時に呼ぶ）
    public func refresh() { queue.async { [weak self] in self?.rebuild() } }

    public var snapshot: NetworkSnapshot { lock.withLock { current } }
    public var isRunning: Bool { lock.withLock { monitor != nil } }
    /// 経路の変化を受けた回数（診断・試験用）
    public var pathUpdates: Int { lock.withLock { updates } }
    /// `requiredInterface` に渡すインターフェース
    public func interface(named name: String) -> NWInterface? { lock.withLock { interfaces[name] } }

    private func pathChanged(_ path: NWPath) {
        var ifs: [String: NWInterface] = [:], ks: [String: LocalNetworks.InterfaceKind] = [:]
        for i in path.availableInterfaces {
            ifs[i.name] = i
            ks[i.name] = i.type == .wifi ? .wifi : i.type == .wiredEthernet ? .wiredEthernet : .other
        }
        let running: Bool = lock.withLock {
            guard monitor != nil else { return false }
            interfaces = ifs; kinds = ks; updates += 1
            return true
        }
        if running { rebuild() }
    }
    private func rebuild() {
        let ks = lock.withLock { kinds }
        let s = NetworkEnvironment.snapshot(addresses: readAddresses(), kinds: ks)
        let changed: Bool = lock.withLock {
            guard monitor != nil, s != current || !notifiedOnce else { return false }
            current = s; notifiedOnce = true
            return true
        }
        if changed { onChange(s) }
    }
}
