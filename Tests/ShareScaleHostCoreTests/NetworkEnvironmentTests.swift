import XCTest
@testable import ShareScaleHostCore
import ShareScaleProtocol

/// ネットワークの純粋な判定（インターフェースの一覧を渡して試す）と、NWPathMonitor の包みの起動と停止
final class NetworkEnvironmentTests: XCTestCase {
    func a(_ name: String, _ addr: String, _ prefix: Int) -> InterfaceAddress { InterfaceAddress(name: name, address: ip(addr), prefix: prefix) }
    let tailscale = [InterfaceAddress(name: "utun4", address: ip("100.101.1.2"), prefix: 32),
                     InterfaceAddress(name: "utun4", address: ip("fd7a:115c:a1e0::1234"), prefix: 128)]

    func testDetectsTailscaleOnlyWithBothAddressesOnAUtun() {
        XCTAssertEqual(NetworkEnvironment.detectTailscale(tailscale), .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1234")))
        XCTAssertEqual(NetworkEnvironment.detectTailscale([a("utun2", "100.70.0.1", 32)]), .ipv4Only(interface: "utun2", v4: ip("100.70.0.1")),
                       "IPv4 だけ（tailnet の IPv6 が無効）は Tailscale と決めず、診断で案内する")
        XCTAssertEqual(NetworkEnvironment.detectTailscale([a("en0", "100.70.0.1", 10), a("en0", "fd7a:115c:a1e0::1", 64)]), .none, "utun だけ")
        XCTAssertEqual(NetworkEnvironment.detectTailscale([a("utun3", "10.0.0.1", 32)]), .none)
        XCTAssertEqual(NetworkEnvironment.detectTailscale([a("utun1", "100.70.0.1", 32)] + tailscale),
                       .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1234")), "両方を持つものを選ぶ")
    }
    func testSnapshotBuildsLocalNetworksFromWifiAndWiredOnly() {
        let addrs = [a("en0", "192.168.1.20", 24), a("en0", "2001:db8:1:2::20", 64), a("en1", "2001:db8:9:9::1", 48),
                     a("en5", "10.0.0.9", 8), a("utun4", "2001:db8:7::1", 64), a("lo0", "127.0.0.1", 8)] + tailscale
        let s = NetworkEnvironment.snapshot(addresses: addrs, kinds: ["en0": .wifi, "en1": .wiredEthernet, "en5": .wiredEthernet, "utun4": .other, "lo0": .other])
        XCTAssertEqual(s.localNetworks, [IPNetwork("192.168.1.0/24")!, IPNetwork("2001:db8:1:2::/64")!],
                       "Wi‑Fi・有線だけ。IPv6 は /64 以上、IPv4 は /16 以上（/48 と /8 は作らない）")
        XCTAssertEqual(s.lanIPv4, [ip("192.168.1.20"), ip("10.0.0.9")])
        XCTAssertEqual(s.interfaceNames, ["en0", "en1", "en5", "utun4", "lo0"])
        XCTAssertEqual(s.tailscale, .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1234")))
    }
    func testBinding() {
        var s = NetworkSnapshot()
        XCTAssertEqual(NetworkEnvironment.binding(tailscaleOnly: false, snapshot: s), .anyInterface)
        XCTAssertEqual(NetworkEnvironment.binding(tailscaleOnly: true, snapshot: s), .unavailable, "見つからなければ受け付けない（全経路に戻さない）")
        s.tailscale = .ipv4Only(interface: "utun2", v4: ip("100.70.0.1"))
        XCTAssertEqual(NetworkEnvironment.binding(tailscaleOnly: true, snapshot: s), .unavailable)
        s.tailscale = .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1234"))
        XCTAssertEqual(NetworkEnvironment.binding(tailscaleOnly: true, snapshot: s), .localAddress(ip("100.101.1.2")),
                       "utun の NWInterface が得られない時は Tailscale の IPv4 アドレスに結び付ける")
        s.interfaceNames = ["utun4"]
        XCTAssertEqual(NetworkEnvironment.binding(tailscaleOnly: true, snapshot: s), .interface("utun4"))
    }
    func testCandidates() {
        var s = NetworkSnapshot()
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: "Studio", snapshot: s, tailscaleOnly: false), ["Studio.local"])
        s.tailscale = .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1234"))
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: "Studio", snapshot: s, tailscaleOnly: false), ["Studio.local", "100.101.1.2"])
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: "Studio", snapshot: s, tailscaleOnly: true), ["100.101.1.2"], "Tailscale 経由だけでは .local を入れない")
        s.tailscale = .none
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: "Studio", snapshot: s, tailscaleOnly: true), [])
        s.lanIPv4 = [ip("192.168.1.20"), ip("10.0.0.9"), ip("10.0.0.10")]
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: nil, snapshot: s, tailscaleOnly: false), ["192.168.1.20", "10.0.0.9"], "名前が無ければ LAN の IPv4（2 件まで）")
        XCTAssertEqual(NetworkEnvironment.candidates(localHostName: "bad_name", snapshot: s, tailscaleOnly: false), ["192.168.1.20", "10.0.0.9"],
                       "規則に合わない名前は入れない")
    }
    func testPrefixLengthAndReadingThisMac() {
        XCTAssertEqual(InterfaceAddresses.prefixLength([255, 255, 255, 0]), 24)
        XCTAssertEqual(InterfaceAddresses.prefixLength([255, 255, 240, 0]), 20)
        XCTAssertEqual(InterfaceAddresses.prefixLength([UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8)), 64)
        XCTAssertTrue(InterfaceAddresses.read().contains(InterfaceAddress(name: "lo0", address: ip("127.0.0.1"), prefix: 8)), "読み取りだけ")
    }
}

final class NetworkMonitorTests: XCTestCase {
    func testStartsNotifiesOnChangeAndStops() async {
        let addrs = Locked<[InterfaceAddress]>([])
        let seen = Locked<[NetworkSnapshot]>([])
        let m = NetworkMonitor(readAddresses: { addrs.value }, onChange: { s in seen.update { $0.append(s) } })
        m.start(); m.start()
        await waitFor(3) { seen.value.count >= 1 }
        XCTAssertGreaterThanOrEqual(seen.value.count, 1, "最初の写し（経路の変化が続けて届けば 2 回以上のこともある）")
        XCTAssertEqual(seen.value.last?.tailscale, TailscaleDetection.none)
        XCTAssertTrue(m.isRunning)
        let found = TailscaleDetection.found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1"))
        addrs.value = [InterfaceAddress(name: "utun4", address: ip("100.101.1.2"), prefix: 32),
                       InterfaceAddress(name: "utun4", address: ip("fd7a:115c:a1e0::1"), prefix: 128)]
        m.refresh()
        await waitFor(3) { seen.value.last?.tailscale == found }
        XCTAssertEqual(seen.value.last?.tailscale, found)
        let n = seen.value.count
        m.refresh()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(seen.value.count, n, "変わらなければ知らせない")
        m.stop()
        XCTAssertFalse(m.isRunning)
        addrs.value = []
        m.refresh()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(seen.value.count, n, "止めた後は知らせない")
    }
}
