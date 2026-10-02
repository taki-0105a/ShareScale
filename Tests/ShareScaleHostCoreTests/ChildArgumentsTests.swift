import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleProtocol

/// `--apply-once`・`--probe` の引数の形と版・CDHash の照合（実際の適用はしない）
final class ChildArgumentsTests: XCTestCase {
    let h = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    let VIRT = "00000000-0000-0000-0000-00000000000A"

    func testRoundTrip() {
        XCTAssertEqual(ChildArguments.parse([]), .resident)
        XCTAssertEqual(ChildArguments.parse(ChildArguments.probe(version: 10100, cdhash: h)), .probe(version: 10100, cdhash: h))
        XCTAssertEqual(ChildArguments.parse(ChildArguments.applyOnce(uuid: VIRT, factor: 2, version: 10100, cdhash: h)),
                       .applyOnce(uuid: VIRT, factor: 2, version: 10100, cdhash: h))
        XCTAssertEqual(ChildArguments.probe(version: 0, cdhash: "0"), ["--probe", "--version", "0", "--cdhash", "0"], "この形は以後の版で変えない")
        XCTAssertEqual(ChildArguments.applyOnce(uuid: "U", factor: 1, version: 0, cdhash: "0"), ["--apply-once", "U", "1", "--version", "0", "--cdhash", "0"])
    }
    func testMalformedArgumentsAreRejected() {
        for args in [["--probe"], ["--probe", "--version", "1"], ["--probe", "--cdhash", h, "--version", "1"], ["--probe", "--version", "-1", "--cdhash", h],
                     ["--probe", "--version", "1", "--cdhash", "xyz"], ["--probe", "--version", "1", "--cdhash", h, "extra"],
                     ["--apply-once", VIRT, "2"], ["--apply-once", VIRT, "0", "--version", "1", "--cdhash", h], ["--apply-once", VIRT, "5", "--version", "1", "--cdhash", h],
                     ["--apply-once", "", "2", "--version", "1", "--cdhash", h], ["--apply-once", VIRT, "x", "--version", "1", "--cdhash", h],
                     ["--help"], ["status"], ["-psn_0_1", "status"], ["--apply-once", VIRT, "2", "--version", "1", "--cdhash", ""]] as [[String]] {
            XCTAssertNil(ChildArguments.parse(args), args.joined(separator: " "))
        }
        XCTAssertEqual(ChildArguments.usageExitCode, 64)
    }
    // Finder・LaunchServices・AppKit が付ける `-` の引数は無視する（自分の引数は `--` で始まるものだけ）
    func testLaunchServicesArgumentsAreIgnoredForTheResident() {
        XCTAssertEqual(ChildArguments.parse(["-psn_0_1234567"]), .resident)
        XCTAssertEqual(ChildArguments.parse(["-NSDocumentRevisionsDebugMode", "YES"]), .resident)
        XCTAssertEqual(ChildArguments.parse(["-AppleLanguages", "(ja)", "-psn_0_1"]), .resident)
        XCTAssertEqual(ChildArguments.parse(["-psn_0_1", "-NSDocumentRevisionsDebugMode", "YES"]), .resident)
        XCTAssertEqual(ChildArguments.parse(["-NSDocumentRevisionsDebugMode", "YES", "-psn_0_1"]), .resident, "`-Key value` の値は飛ばす")
        XCTAssertNil(ChildArguments.parse(["status"]), "裸の語は形の誤り（使い方を出して 64）")
        XCTAssertNil(ChildArguments.parse(["-psn_0_1", "status"]))
        XCTAssertEqual(ChildArguments.parse(["-psn_0_1", "--probe", "--version", "1", "--cdhash", h]), .probe(version: 1, cdhash: h), "最初の `--` から読む")
        XCTAssertNil(ChildArguments.parse(["-psn_0_1", "--probe"]), "`--` から後の形は厳密")
    }
    func testVersionAndCDHashMustBothMatch() {
        let own = SelfIdentity(version: 10100, cdhash: h)
        XCTAssertTrue(ChildArguments.matchesSelf(version: 10100, cdhash: h, own: own))
        XCTAssertTrue(ChildArguments.matchesSelf(version: 10100, cdhash: h.uppercased(), own: own), "大文字小文字は区別しない")
        XCTAssertFalse(ChildArguments.matchesSelf(version: 10101, cdhash: h, own: own), "版が違う → 75")
        XCTAssertFalse(ChildArguments.matchesSelf(version: 10100, cdhash: "0" + h.dropFirst(), own: own), "同じ版でも CDHash が違う（brew reinstall）→ 75")
    }
    func testCommandForTheProviderPassesVersionAndCDHash() {
        let cmd = ChildArguments.command(executable: URL(fileURLWithPath: "/x/ShareScaleHost"), version: 7, cdhash: h)
        XCTAssertEqual(cmd.executable.path, "/x/ShareScaleHost")
        XCTAssertEqual(cmd.probeArguments, ["--probe", "--version", "7", "--cdhash", h])
        XCTAssertEqual(cmd.applyArguments(VIRT, 2), ["--apply-once", VIRT, "2", "--version", "7", "--cdhash", h])
        XCTAssertEqual(cmd.environment, ["LANG": "C"], "環境は最小限（PATH も渡さない）")
    }
    func testSelfIdentityFallbacksAndOwnCodeHash() {
        XCTAssertNil(SelfIdentity.bundleVersion(nil)); XCTAssertNil(SelfIdentity.bundleVersion([:]))
        XCTAssertEqual(SelfIdentity.bundleVersion(["CFBundleVersion": " 10100 "]), 10100)
        XCTAssertNil(SelfIdentity.bundleVersion(["CFBundleVersion": "1.1.0"]), "数でなければ nil（組み立てのスクリプトは数を書く）")
        // 試験の実行体（xctest）は署名されているので CDHash が読める。40 文字（SHA-1）か 64 文字（SHA-256）の小文字 hex
        let own = SelfIdentity.current()
        XCTAssertEqual(own.version, SelfIdentity.bundleVersion() ?? 0, "試験では xctest の CFBundleVersion。バンドルの外の実行体では 0")
        XCTAssertTrue([40, 64].contains(own.cdhash.count), own.cdhash)
        XCTAssertTrue(ChildArguments.isHex(own.cdhash)); XCTAssertEqual(own.cdhash, own.cdhash.lowercased())
        XCTAssertTrue(ChildArguments.matchesSelf(version: own.version, cdhash: own.cdhash, own: own), "親と子が同じ実行体なら照合は通る")
    }
    /// リポジトリの `VERSION` は `x.y.z`（各 0〜99）で、`CFBundleVersion` は x×10000+y×100+z（組み立てのスクリプトと同じ計算）
    func testVersionFileIsWellFormed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        let v = try XCTUnwrap(AppVersion(text), "VERSION: \(text)")
        XCTAssertEqual(v.bundleVersion, v.major * 10000 + v.minor * 100 + v.patch)
        XCTAssertEqual(v.shortString, text.trimmingCharacters(in: .whitespacesAndNewlines))
        // 組み立てのスクリプトの計算（shell）と同じ値になること
        let sh = ChildProcess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", "IFS=. read -r a b c < '\(root.appendingPathComponent("VERSION").path)'; echo $((10#$a*10000+10#$b*100+10#$c))"], timeout: 5)
        XCTAssertEqual(sh.output.trimmingCharacters(in: .whitespacesAndNewlines), String(v.bundleVersion))
    }
}

/// Host の設定（辞書との出し入れ。利用者の環境設定には書かない）
final class HostPreferencesTests: XCTestCase {
    func testDefaultsAndRoundTrip() {
        let d = HostPreferences()
        XCTAssertFalse(d.tailscaleOnly); XCTAssertFalse(d.allowGlobal); XCTAssertEqual(d.port, 47651)
        var p = HostPreferences(); p.tailscaleOnly = true; p.allowGlobal = true; p.port = 5000
        XCTAssertEqual(HostPreferences(dictionary: p.dictionary), p)
        XCTAssertEqual(p.dictionary.keys.sorted(), ["allowGlobal", "menuBarNoticeShown", "port", "tailscaleOnly"])
    }
    func testBadValuesFallBackToDefaults() {
        let p = HostPreferences(dictionary: ["tailscaleOnly": "yes", "allowGlobal": 1, "port": 70000, "other": true])
        XCTAssertEqual(p, HostPreferences())
        XCTAssertEqual(HostPreferences(dictionary: ["port": 0]).port, 47651)
        XCTAssertEqual(HostPreferences(dictionary: ["port": 65535]).port, 65535)
    }
}
