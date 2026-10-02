import XCTest
@testable import ShareScaleProtocol

/// 境界の値
final class BoundaryTests: XCTestCase {
    func testNameNFCByScalars() {
        // Swift の == は正準等価で比べるので、スカラー列で比べる
        XCTAssertEqual(NameRules.validate("Cafe\u{301}").map { Array($0.unicodeScalars) }, Array("Caf\u{E9}".unicodeScalars))
    }
    func testNameByteBoundary() {
        XCTAssertNotNil(NameRules.validate(String(repeating: "あ", count: 42) + "ab"), "128 バイト")
        XCTAssertNil(NameRules.validate(String(repeating: "あ", count: 42) + "abc"), "129 バイト")
        XCTAssertNil(NameRules.validate("   "), "空白だけ")
        XCTAssertNil(NameRules.validate("\u{3000}"), "全角の空白だけ")
    }
    func c(_ s: String) -> SourceDecision { SourceClassifier.classify(IPAddress(s)!, localNetworks: [], allowGlobal: false) }
    func testClassBoundaries() {
        XCTAssertEqual(c("fc00::1").sourceClass, .uniqueLocal)
        XCTAssertEqual(c("fbff::1").sourceClass, .otherGlobal)
        XCTAssertEqual(c("fe00::1").sourceClass, .otherGlobal)
        XCTAssertEqual(c("172.15.255.255").sourceClass, .otherGlobal)
        XCTAssertEqual(c("172.16.0.0").sourceClass, .privateV4)
        XCTAssertEqual(c("100.64.0.1").sourceClass, .sharedCGNAT)
        XCTAssertTrue(isTailscaleAddress(IPAddress("100.64.0.1")!))
        XCTAssertEqual(c("febf::1").sourceClass, .linkLocal)
        XCTAssertEqual(c("fec0::1").sourceClass, .otherGlobal)
    }
    func testSameNetworkGlobalBuckets() {
        let v6 = LocalNetworks.make([LocalInterface(kind: .wifi, address: IPAddress("2001:db8:1:2::10")!, prefix: 64)])
        let d6 = SourceClassifier.classify(IPAddress("2001:db8:1:2::99")!, localNetworks: v6, allowGlobal: false)
        XCTAssertEqual(d6.bucket, "2001:db8:1:2::99/128", "同じネットワークはアドレスごと（/64 で全員を締め出さない）")
        let v4 = LocalNetworks.make([LocalInterface(kind: .wiredEthernet, address: IPAddress("133.1.2.3")!, prefix: 16)])
        let d4 = SourceClassifier.classify(IPAddress("133.1.9.9")!, localNetworks: v4, allowGlobal: false)
        XCTAssertEqual(d4.sourceClass, .sameNetworkGlobal)
        XCTAssertTrue(d4.accepted)
        XCTAssertEqual(d4.bucket, "133.1.9.9/32")
    }
    func testMappedBytesAreNormalizedInClassify() {
        let mapped = IPAddress(bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 7])!
        let d = SourceClassifier.classify(mapped, localNetworks: [], allowGlobal: false)
        XCTAssertEqual(d.sourceClass, .privateV4)
        XCTAssertEqual(d.bucket, "192.168.1.7/32")
        XCTAssertTrue(isTailscaleAddress(IPAddress(bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 100, 100, 1, 1])!))
    }
    func testLeadingZeroIPv4Rejected() {
        XCTAssertNil(IPAddress("010.1.1.1"), "8 進として読む実装との食い違いを防ぐ")
        XCTAssertNil(IPAddress("10.01.1.1"))
        XCTAssertFalse(CandidateAddress.isValid("010.1.1.1"))
        XCTAssertNotNil(IPAddress("10.0.1.1"))
        XCTAssertNotNil(IPAddress("0.0.0.0"))
    }
    func testPairingCodeSizeBoundary() throws {
        let base = PairingCode(id: .sample, secret: .counting, port: 1, addresses: ["a.local"], expiresAt: 0)!
        let code = base.encoded()
        let pad1024 = code + String(repeating: " ", count: 1024 - code.utf8.count)
        XCTAssertNoThrow(try PairingCode.decode(pad1024), "前後の空白は除いてから数える")
        let long = "sharescale1:" + String(repeating: "A", count: 1024 - 12)
        XCTAssertThrowsError(try PairingCode.decode(long)) { XCTAssertNotEqual($0 as? PairingCode.Invalid, .tooLarge, "ちょうど 1024 バイトは大きさでは断らない") }
        XCTAssertThrowsError(try PairingCode.decode(long + "A")) { XCTAssertEqual($0 as? PairingCode.Invalid, .tooLarge, "1025 バイト") }
    }
    func testCheckSymbolsAbove31() throws {
        // 検査の値が 32〜36（記号 * ~ $ = U）になるキーを探して、往復と 1 文字の誤りの検出を確かめる
        var found = Set<Character>()
        var secret = Data(repeating: 0, count: 32)
        var n: UInt8 = 0
        while found.count < 5 && n < 250 {
            secret[31] = n; n += 1
            let key = ManualEntry.encodeKey(id: .sample, secret: Bytes32(secret)!)
            guard let check = key.last else { return XCTFail("キーが空") }
            guard "*~$=U".contains(check) else { continue }
            found.insert(check)
            XCTAssertEqual(try ManualEntry.decodeKey(key).secret.data, secret)
            XCTAssertEqual(try ManualEntry.decodeKey(key.lowercased()).secret.data, secret, "記号の u も読める")
            var wrong = Array(key); wrong[77] = wrong[77] == "*" ? "~" : "*"
            XCTAssertThrowsError(try ManualEntry.decodeKey(String(wrong)))
        }
        XCTAssertEqual(found, Set("*~$=U"), "5 つの記号すべてを試せた")
    }
    func testRevealLength() {
        func open(_ r: Data) -> Request? {
            let d = Data(#"{"v":1,"op":"reveal","r":"\#(Base64URL.encode(r))"}"#.utf8)
            guard case let .ready(_, body) = RequestReader.open(d, first: false) else { return nil }
            return RequestReader.request(body, first: false)
        }
        XCTAssertNil(open(Data(repeating: 1, count: 31)))
        XCTAssertNil(open(Data(repeating: 1, count: 33)))
        XCTAssertEqual(open(Data(repeating: 1, count: 32)), .reveal(random: .filled(1)))
    }
    func testNegativeSetByRejected() {
        let s = StatusPayload(name: "x", model: "y", paused: false, session: true, mode: .oneX, virtualDisplay: nil, ambiguous: false,
                              lastError: nil, setBy: .init(byYou: false, at: 5), port: 1, addresses: ["a.local"])!
        let text = String(decoding: Response.status(s).encoded().dropLast(), as: UTF8.self).replacingOccurrences(of: #""at":5"#, with: #""at":-5"#)
        XCTAssertThrowsError(try Response.decode(Data(text.utf8), expecting: .status))
    }
    func testRequestSizeBoundary() {
        let fill = String(repeating: "a", count: Limits.requestMaxBytes)
        XCTAssertEqual(LineFraming.extract(Data((String(fill.dropLast()) + "\n").utf8), limit: Limits.requestMaxBytes),
                       .line(Data(String(fill.dropLast()).utf8)), "改行を含めてちょうど 4 KiB")
        XCTAssertEqual(LineFraming.extract(Data((fill + "\n").utf8), limit: Limits.requestMaxBytes), .reject(.tooLarge))
    }
}
