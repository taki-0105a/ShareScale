import XCTest
@testable import ShareScaleHostCore
import ShareScaleProtocol

/// 記録（一時フォルダに書く。時計は差し替える）
final class HostLogTests: TempDirTestCase {
    let mono = Locked<TimeInterval>(1000)
    var logDir: URL { dir.appendingPathComponent("Logs/ShareScale", isDirectory: true) }
    func make(_ edit: (inout HostLog.Settings) -> Void = { _ in }, directory: URL?? = nil) -> HostLog {
        var s = HostLog.Settings(); edit(&s)
        let mono = mono
        return HostLog(directory: directory ?? logDir, settings: s, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) }, now: { mono.value })
    }
    var fileText: String { (try? String(contentsOf: logDir.appendingPathComponent("host.log"), encoding: .utf8)) ?? "" }
    func mode(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1 }

    func testAppendsStampedLinesWithStrictPermissions() {
        let log = make()
        log.write("host started"); log.write("listener: listening on port 47651")
        let lines = fileText.split(separator: "\n")
        guard hasCount(lines, 2) else { return }
        XCTAssertTrue(lines[0].hasSuffix(" host started"), String(lines[0]))
        XCTAssertTrue(lines[0].hasPrefix("20"), "ISO 8601 の時刻で始まる")
        XCTAssertEqual(mode(logDir), 0o700); XCTAssertEqual(mode(logDir.appendingPathComponent("host.log")), 0o600)
        XCTAssertNil(log.problem)
    }
    func testLineIsClippedAndControlsRemoved() {
        let log = make()
        log.write("name \"Evil\u{202E}\nsecond line\" " + String(repeating: "あ", count: 200))
        let lines = fileText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        guard hasCount(lines, 1, "改行を含む文字列も 1 行") else { return }
        XCTAssertLessThanOrEqual(lines[0].utf8.count, 256)
        XCTAssertFalse(lines[0].contains("\u{202E}"))
    }
    func testRotatesKeepingOneGeneration() {
        let log = make { $0.maxFileBytes = 300 }
        for i in 0..<20 { log.write("line \(i) " + String(repeating: "x", count: 40)) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logDir.path).sorted()) ?? []
        XCTAssertEqual(names, ["host.log", "host.log.1"])
        XCTAssertLessThanOrEqual(fileText.utf8.count, 300)
        XCTAssertTrue(fileText.contains("line 19"))
    }
    func testLooseFolderIsTightened() throws {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        make().write("x")
        XCTAssertEqual(mode(logDir), 0o700)
    }
    func testSymlinkedLogFileIsRefused() throws {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: logDir.appendingPathComponent("host.log"), withDestinationURL: dir.appendingPathComponent("elsewhere"))
        let log = make()
        log.write("x")
        XCTAssertNotNil(log.problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("elsewhere").path), "リンクの先に書かない")
    }
    // 同じ送り元・同じ理由は 1 分に 1 行。続いた件数は 1 分が過ぎてから 1 行で書く
    func testFailuresAreCoalescedPerSourceAndReasonPerMinute() {
        let log = make()
        for _ in 0..<5 { log.noteFailure(source: "10.0.0.5", reason: "not paired (proof)") }
        log.noteFailure(source: "10.0.0.6", reason: "not paired (proof)")
        XCTAssertEqual(fileText.split(separator: "\n").count, 2)
        log.flush()
        XCTAssertEqual(fileText.split(separator: "\n").count, 2, "1 分たつまでは書かない")
        mono.value += 60
        log.flush()
        XCTAssertTrue(fileText.contains("not paired (proof) from 10.0.0.5 (4 more in the last minute)"), fileText)
        XCTAssertFalse(fileText.contains("10.0.0.6 (0 more"), "続きが無ければ書かない")
        log.noteFailure(source: "10.0.0.5", reason: "not paired (proof)")
        XCTAssertEqual(fileText.split(separator: "\n").filter { $0.hasSuffix("not paired (proof) from 10.0.0.5") }.count, 2, "次の 1 分はまた 1 行目から")
    }
    // `log` の応答: 倍率の維持の行とその見る側自身の行、拒否の集計の 1 行だけ（送り元・ほかの見る側は含めない）
    func testRecentForIncludesOnlyEngineOwnLinesAndARejectionCount() {
        let log = make()
        log.write("check: applied 1x in 0.40s (was 1920x997@2x)", topic: .engine)
        log.write("set 1x", topic: .pairing(pid(1)))
        log.write("set 2x", topic: .pairing(pid(2)))
        log.write("pairing requested by \"Other\" from 192.168.1.9 (privateV4)")
        log.noteFailure(source: "192.168.1.66", reason: "rejected (lockedOut)")
        log.noteFailure(source: "192.168.1.67", reason: "not paired (proof)")
        let r = log.recent(for: pid(1))
        guard hasCount(r, 3, r.joined(separator: "\n")) else { return }
        XCTAssertTrue(r[0].hasSuffix("check: applied 1x in 0.40s (was 1920x997@2x)"))
        XCTAssertTrue(r[1].hasSuffix("set 1x"))
        XCTAssertTrue(r[2].hasSuffix("rejected 2 connections in the last minute"))
        XCTAssertFalse(r.joined().contains("192.168."))
        mono.value += 61
        XCTAssertEqual(log.recent(for: pid(1)).count, 2, "集計は直近 1 分だけ")
    }
    func testRecentIsLimitedTo50LinesAnd16KiB() throws {
        let log = make()
        for i in 0..<80 { log.write("line \(i) " + String(repeating: "\"", count: 200), topic: .engine) }
        let r = log.recent(for: pid(1))
        XCTAssertLessThanOrEqual(r.count, 50)
        XCTAssertTrue(r.last?.contains("line 79") == true)
        let encoded = Response.log(r).encoded()
        XCTAssertLessThanOrEqual(encoded.count, 16 * 1024)
        XCTAssertEqual(try Response.decode(encoded.dropLast(), expecting: .log), .log(r), "見る側の検査を通る")
    }
    // 多くの送り元からの失敗が、倍率の維持の行を押し出さない（記憶の中の記録は 2 本の輪）
    func testFailuresFromManySourcesDoNotEvictEngineLines() {
        let log = make()
        log.write("startup: applied 1x in 0.40s (was 1920x997@2x)", topic: .engine)
        for i in 0..<600 { log.noteFailure(source: "10.0.\(i / 256).\(i % 256)", reason: "TLS handshake failed") }
        let r = log.recent(for: pid(1))
        guard hasCount(r, 2, r.joined(separator: "\n")) else { return }
        XCTAssertTrue(r[0].hasSuffix("startup: applied 1x in 0.40s (was 1920x997@2x)"))
        XCTAssertEqual(log.recentAll(1000).count, 501, "そのほかの輪は 500 行まで")
        XCTAssertTrue(log.recentAll(1000).first?.hasSuffix("(was 1920x997@2x)") == true, "書いた順に並ぶ")
    }
    var logSize: Int { (try? FileManager.default.attributesOfItem(atPath: logDir.appendingPathComponent("host.log").path)[.size] as? Int) ?? -1 }
    // 切り替えの名前の変更に失敗したら（`host.log.1` がフォルダ）、消してから開き直して続け、理由を診断に残す。後で切り替えに成功したら消す
    func testRotationFailureDiscardsAndContinues() throws {
        let log = make { $0.maxFileBytes = 200 }
        log.write("first")
        let gen1 = logDir.appendingPathComponent("host.log.1")
        try FileManager.default.createDirectory(at: gen1, withIntermediateDirectories: false)
        for i in 0..<10 { log.write("line \(i) " + String(repeating: "x", count: 40)) }
        XCTAssertTrue(log.problem?.contains("the log was discarded") == true, log.problem ?? "nil")
        XCTAssertLessThanOrEqual(logSize, 200 + 100, "大きくなり続けない（上限＋1 行）")
        XCTAssertTrue(fileText.contains("line 9"), "捨てた後も書き続ける")
        try FileManager.default.removeItem(at: gen1)
        for i in 10..<20 { log.write("line \(i) " + String(repeating: "x", count: 40)) }
        XCTAssertNil(log.problem, "切り替えに成功したら理由を消す")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gen1.path))
    }
    // 切り替えにも捨てるのにも失敗したら（フォルダが書けない）、ファイルへの書き込みを止める。記憶の中の記録は続く
    func testRotationAndDiscardFailureStopsFileLogging() throws {
        let log = make { $0.maxFileBytes = 200 }
        log.write("first", topic: .engine)
        chmod(logDir.path, 0o500)
        defer { chmod(logDir.path, 0o700) }
        for i in 0..<10 { log.write("line \(i) " + String(repeating: "x", count: 40), topic: .engine) }
        XCTAssertTrue(log.problem?.contains("could not rotate or discard") == true, log.problem ?? "nil")
        XCTAssertTrue(log.problem?.contains("file logging stopped") == true, log.problem ?? "nil")
        XCTAssertLessThanOrEqual(logSize, 200 + 100, "大きくなり続けない（上限＋1 行）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDir.appendingPathComponent("host.log.1").path))
        XCTAssertEqual(log.recent(for: pid(1)).count, 11, "記憶の中の輪は続ける")
    }
    func testMemoryOnlyWhenNoDirectory() {
        let log = make(directory: .some(nil))
        log.write("x", topic: .engine)
        XCTAssertEqual(log.recent(for: pid(1)).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDir.path))
    }
}
