import XCTest
@testable import ShareScaleProtocol

/// でたらめな入力で落ちないことと、読めたものについて成り立つ性質（決まった種で再現できる。乱数は自前の `TestLCG` だけを使う）
final class FuzzTests: XCTestCase {
    static let auth = Auth(id: .sample, proof: .filled(2))
    static let status = StatusPayload(name: "Studio", model: "Mac Studio", paused: false, session: true, mode: .twoX,
                                      virtualDisplay: .init(resolution: "1920x997", scaling: .oneX, source: .signature),
                                      ambiguous: false, lastError: "x", setBy: .init(byYou: true, at: 5),
                                      port: 47651, addresses: ["a.local", "100.64.0.1", "fd7a:115c:a1e0::1"])!
    static let code = PairingCode(id: .sample, secret: .counting, port: 47651,
                                  addresses: ["a.local", "100.64.0.1", "fd7a:115c:a1e0::1"], expiresAt: 1)!

    static func line(_ d: Data?) -> String { String(decoding: d!.dropLast(), as: UTF8.self) }

    /// 変異の元（指示・応答・接続コードとその中身の JSON・手入力）
    static let seeds: [String] = {
        let c = Bytes32.filled(1)
        let requests: [Request] = [.hello(name: "Mac", commitment: c), .status, .set(.twoX), .log, .unpair]
        let responses: [Response] = [.helloChallenge(hostRandom: c), .paired(newSecret: c), .status(status), .log(["a", "b"]), .ok,
                                     .error(.unsupportedVersion), .error(.busy)]
        return requests.map { line($0.encodedAsFirst(auth: auth)) }
            + [line(Request.reveal(random: c).encodedAsReveal())]
            + responses.map { line($0.encoded()) }
            + [code.encoded(), String(decoding: Base64URL.decode(String(code.encoded().dropFirst(PairingCode.prefix.count)))!, as: UTF8.self)]
            + [ManualEntry.encodeKey(id: .sample, secret: .counting), "[fd7a:115c:a1e0::1]:47651", "Studio.local:5000", "100.101.77.7"]
    }()

    /// 1 文字の変異に使う文字
    static let alphabet = Array("{}[]\":,\\0123456789-.eEtruefalsnx ab\u{0}\u{1F}é😀\u{FEFF}\r\n/_=*~$UIO%")
    /// ひとまとまりで挿入するもの（エスケープは途中で切れると意味が無いので、まとめて入れる）
    static let units = [#"\u0000"#, #"\ud800"#, #"\udc00"#, #"\ud83d\ude00"#, "é", #"\u00e9"#, #"\""#, #"\\"#, #"\n"#, #"\u2028"#,
                        "\u{0}", "0x", "%en0", "::", "..", "::ffff:", "FD7A", #""v":1,"#, #","op":"log""#]

    static func mutate(_ seed: String, _ rng: inout TestLCG) -> String {
        var chars = Array(seed)
        for _ in 0..<rng.inRange(1...4) {
            switch rng.below(4) {
            case 0 where !chars.isEmpty: chars.remove(at: rng.below(chars.count))
            case 1 where !chars.isEmpty: chars[rng.below(chars.count)] = rng.pick(alphabet)
            case 2: chars.insert(contentsOf: Array(rng.pick(units)), at: rng.inRange(0...chars.count))
            default: chars.insert(rng.pick(alphabet), at: rng.inRange(0...chars.count))
            }
        }
        return String(chars)
    }

    /// 読めた接続コードの性質（候補アドレスは決まった文字だけ・書き出し直すと同じに読める）。読めた時 true
    func checkPairingCode(_ input: String) -> Bool {
        guard let code = try? PairingCode.decode(input) else { return false }
        _ = code.probablyExpired(now: 1_790_000_000)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        for a in code.addresses {
            XCTAssertTrue(a.allSatisfy(allowed.contains), "候補アドレスに決まった文字以外: \(a.debugDescription)")
        }
        XCTAssertEqual(try PairingCode.decode(code.encoded()), code, "書き出し直すと同じに読める")
        return true
    }

    func testParsersNeverCrashAndReadValuesAreConsistent() throws {
        var rng = TestLCG(seed: 20260924)
        let addressCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        var seen = (codes: 0, requests: 0, responses: 0, addresses: 0)
        for i in 0..<10_000 {
            let text = Self.mutate(Self.seeds[i % Self.seeds.count], &rng)
            let data = Data(text.utf8)
            _ = try? StrictJSON.parse(data)

            // 接続コード（そのままと、中身の JSON を包んだものの両方）
            for input in [text, PairingCode.prefix + Base64URL.encode(data)] where checkPairingCode(input) { seen.codes += 1 }

            // 指示: 読めたものは、書き出し直して読み直すと同じになる
            for first in [true, false] {
                guard case let .ready(auth, body) = RequestReader.open(data, first: first),
                      let request = RequestReader.request(body, first: first) else { continue }
                seen.requests += 1
                let again = first ? request.encodedAsFirst(auth: auth!) : request.encodedAsReveal()
                guard let again, case let .ready(auth2, body2) = RequestReader.open(again.dropLast(), first: first) else {
                    XCTFail("書き出し直せない: \(text.debugDescription)"); continue
                }
                XCTAssertEqual(auth2, auth)
                XCTAssertEqual(RequestReader.request(body2, first: first), request)
            }

            // 応答: 読めたものは、書き出し直すと読み取りを通る
            for e in [Response.Expectation.hello, .reveal, .status, .set, .log, .unpair] {
                guard let response = try? Response.decode(data, expecting: e) else { continue }
                seen.responses += 1
                let again = response.encoded()
                XCTAssertLessThanOrEqual(again.count, Limits.responseMaxBytes)
                XCTAssertNoThrow(try Response.decode(again.dropLast(), expecting: e), "書き出し直すと読めない: \(text.debugDescription)")
            }

            // アドレス: 読めた IP は書き直した形で読み直せ、候補アドレスとして通る。手入力で読めたホストも候補アドレスとして通る
            if let ip = IPAddress(text) {
                XCTAssertEqual(IPAddress(ip.text), ip)
                XCTAssertTrue(CandidateAddress.isValid(ip.text))
            }
            if CandidateAddress.isValid(text) { XCTAssertTrue(text.allSatisfy(addressCharacters.contains), text.debugDescription) }
            if let parsed = try? ManualEntry.parseAddress(text) {
                seen.addresses += 1
                XCTAssertTrue(CandidateAddress.isValid(parsed.host), "手入力のホストが候補アドレスの規則に合わない: \(parsed.host)")
                XCTAssertTrue(Limits.portRange.contains(parsed.port))
            }

            _ = try? ManualEntry.decodeKey(text)
            _ = NameRules.validate(text); _ = NameRules.sanitize(text)
            _ = LineFraming.extract(data, limit: 64)
        }
        // 性質を確かめる対象が実際にあったこと（この種では、指示・応答・手入力のアドレスがそれぞれ 80 件以上読める）
        XCTAssertGreaterThan(seen.requests, 50)
        XCTAssertGreaterThan(seen.responses, 50); XCTAssertGreaterThan(seen.addresses, 50)

        // 接続コードの中身の JSON だけを変異させて、読めるものを多く試す
        let json = Self.seeds.first { $0.hasPrefix(#"{"v":1,"id""#) }!
        for _ in 0..<5_000 where checkPairingCode(PairingCode.prefix + Base64URL.encode(Data(Self.mutate(json, &rng).utf8))) {
            seen.codes += 1
        }
        XCTAssertGreaterThan(seen.codes, 150)

        var raw = TestLCG(seed: 7)
        for _ in 0..<2_000 {
            let bytes = Data(raw.bytes(raw.inRange(0...200)))
            _ = try? StrictJSON.parse(bytes)
            _ = RequestReader.open(bytes, first: true)
            _ = try? Response.decode(bytes, expecting: .status)
            _ = LineFraming.extract(bytes, limit: 100)
        }
    }
}
