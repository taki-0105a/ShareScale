import XCTest
@testable import ShareScaleProtocol

final class AddressTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(IPAddress("192.168.1.5"), IPAddress(bytes: [192, 168, 1, 5]))
        XCTAssertEqual(IPAddress("::ffff:100.64.1.2"), IPAddress(bytes: [100, 64, 1, 2]), "IPv4-mapped は IPv4 に直す")
        XCTAssertEqual(IPAddress("fe80::1%en0")?.text, "fe80::1", "ゾーンを除く")
        XCTAssertEqual(IPAddress("fd7a:115c:a1e0::1")?.text, "fd7a:115c:a1e0::1")
        XCTAssertEqual(IPAddress("FD7A::1")?.text, "fd7a::1", "IPAddress は大文字も読み、書き直した形は小文字")
        for bad in ["", "1.2.3", "256.1.1.1", "1.2.3.4.5", "example.com", "::g", "１.2.3.4", " 1.2.3.4",
                    "fe80::1%en_0", "fe80::1%en 0", "fe80::1%%en0", "fe80::1%ｅｎ0", "[fd7a::1]", "+1.2.3.4", "fd7a::1/64"] {
            XCTAssertNil(IPAddress(bad), bad)
        }
    }
    func testNetworkContains() {
        let n = IPNetwork("100.64.0.0/10")!
        XCTAssertTrue(n.contains(IPAddress("100.64.0.0")!))
        XCTAssertTrue(n.contains(IPAddress("100.127.255.255")!))
        XCTAssertFalse(n.contains(IPAddress("100.63.255.255")!))
        XCTAssertFalse(n.contains(IPAddress("100.128.0.0")!))
        XCTAssertFalse(n.contains(IPAddress("fd7a::1")!), "別の種類は含まない")
        XCTAssertTrue(IPNetwork("fd7a:115c:a1e0::/48")!.contains(IPAddress("fd7a:115c:a1e0:ab12::1")!))
        XCTAssertNil(IPNetwork("10.0.0.0/33"))
        XCTAssertEqual(IPNetwork("192.168.1.77/24"), IPNetwork("192.168.1.0/24"), "範囲の先頭に切りそろえる")
        XCTAssertEqual(IPNetwork("10.1.2.3/0")?.address, IPAddress(bytes: [0, 0, 0, 0]))
        XCTAssertTrue(IPNetwork("0.0.0.0/0")!.contains(IPAddress("8.8.8.8")!))
    }
    func testHostnamesAndCandidates() {
        XCTAssertTrue(CandidateAddress.isValid("Office-Mac-Studio.local"))
        XCTAssertTrue(CandidateAddress.isValid("100.101.77.7"))
        XCTAssertTrue(CandidateAddress.isValid("fd7a:115c:a1e0::1"))
        for bad in ["", "-bad.local", "bad-.local", "a..b", "[fd7a::1]", "fe80::1%en0", "a b", "日本.local", "999.1.1.1", "1.2.3",
                    String(repeating: "a", count: 64) + ".local", String(repeating: "a.", count: 127) + "ab"] {
            XCTAssertFalse(CandidateAddress.isValid(bad), bad)
        }
    }
    func testTailscale() {
        XCTAssertTrue(isTailscaleAddress(IPAddress("100.101.77.7")!))
        XCTAssertTrue(isTailscaleAddress(IPAddress("::ffff:100.101.77.7")!))
        XCTAssertTrue(isTailscaleAddress(IPAddress("fd7a:115c:a1e0::5")!))
        XCTAssertFalse(isTailscaleAddress(IPAddress("fd7b::5")!))
        XCTAssertFalse(isTailscaleAddress(IPAddress("192.168.1.1")!))
    }
}

final class SourceClassifierTests: XCTestCase {
    func c(_ s: String, local: [IPNetwork] = [], global: Bool = false) -> SourceDecision {
        SourceClassifier.classify(IPAddress(s)!, localNetworks: local, allowGlobal: global)
    }
    func testTable() {
        XCTAssertEqual(c("127.0.0.1").sourceClass, .loopback)
        XCTAssertEqual(c("::1").sourceClass, .loopback)
        XCTAssertEqual(c("10.1.2.3").sourceClass, .privateV4)
        XCTAssertEqual(c("172.31.0.1").sourceClass, .privateV4)
        XCTAssertEqual(c("172.32.0.1").sourceClass, .otherGlobal)
        XCTAssertEqual(c("169.254.9.9").sourceClass, .linkLocal)
        XCTAssertEqual(c("fe80::abcd").sourceClass, .linkLocal)
        XCTAssertEqual(c("100.101.77.7").sourceClass, .sharedCGNAT)
        XCTAssertEqual(c("::ffff:192.168.0.9").sourceClass, .privateV4, "IPv4-mapped は IPv4 として")
        XCTAssertEqual(c("fd7a:115c:a1e0::9").sourceClass, .uniqueLocal)
        XCTAssertEqual(c("8.8.8.8").sourceClass, .otherGlobal)
    }
    func testAcceptance() {
        XCTAssertTrue(c("192.168.1.9").accepted)
        XCTAssertFalse(c("8.8.8.8").accepted, "グローバルは既定で断る")
        XCTAssertTrue(c("8.8.8.8", global: true).accepted)
        let home = LocalNetworks.make([LocalInterface(kind: .wifi, address: IPAddress("2001:db8:1:2::10")!, prefix: 64)])
        XCTAssertEqual(c("2001:db8:1:2::99", local: home).sourceClass, .sameNetworkGlobal)
        XCTAssertTrue(c("2001:db8:1:2::99", local: home).accepted)
        XCTAssertFalse(c("2001:db8:1:3::99", local: home).accepted)
    }
    func testBucketsArePerAddressExceptOtherGlobalV6() {
        XCTAssertEqual(c("fe80::1").bucket, "fe80::1/128", "リンクローカルはアドレスごと（fe80::/64 で全員を締め出さない）")
        XCTAssertEqual(c("fd7a:115c:a1e0::1").bucket, "fd7a:115c:a1e0::1/128", "tailnet もアドレスごと")
        XCTAssertEqual(c("::ffff:10.0.0.5").bucket, "10.0.0.5/32", "IPv4-mapped は IPv4 でまとめる")
        XCTAssertEqual(c("2001:db8:1:2:3:4:5:6").bucket, "2001:db8:1:2::/64")
        XCTAssertEqual(c("8.8.4.4").bucket, "8.8.4.4/32")
    }
    func testLocalNetworksRestrictions() {
        let nets = LocalNetworks.make([
            LocalInterface(kind: .wifi, address: IPAddress("2001:db8:1:2::10")!, prefix: 64),
            LocalInterface(kind: .wiredEthernet, address: IPAddress("133.1.2.3")!, prefix: 16),
            LocalInterface(kind: .other, address: IPAddress("2001:db8::1")!, prefix: 64),              // VPN（utun）からは作らない
            LocalInterface(kind: .wifi, address: IPAddress("2001:db8:5::1")!, prefix: 48),              // /64 より広い
            LocalInterface(kind: .wiredEthernet, address: IPAddress("150.1.2.3")!, prefix: 8),         // /16 より広い
            LocalInterface(kind: .wifi, address: IPAddress("2001:db8:1:2::11")!, prefix: 64),         // 重複
        ])
        XCTAssertEqual(nets, [IPNetwork("2001:db8:1:2::10/64")!, IPNetwork("133.1.2.3/16")!])
    }
}
