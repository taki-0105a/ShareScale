import XCTest
@testable import ShareScaleEngine

final class EngineStateTests: TempDirTestCase {
    func testMissingFileGivesDefaultsWithoutProblem() {
        let r = stateFile.load()
        XCTAssertEqual(r.state, EngineState()); XCTAssertNil(r.problem)
        XCTAssertEqual(r.state.mode, .x1, "既定は 1x")
    }
    func testRoundTripAllFields() throws {
        var s = EngineState()
        s.mode = .x2; s.paused = true; s.learned = [PHYS, HOT]
        s.learnCandidate = LearnCandidate(ids: [PHYS], since: 12.5, boot: 1700)
        s.lastError = "apply failed"; s.setBy = EngineState.SetRecord(by: "ab", at: 1_700_000_000)
        try stateFile.save(s)
        XCTAssertEqual(stateFile.load().state, s)
        XCTAssertNil(stateFile.load().problem)
    }
    func testFileIs600AndNoTemporaryIsLeft() throws {
        try stateFile.save(EngineState())
        let attrs = try FileManager.default.attributesOfItem(atPath: stateFile.url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["engine.json"])
    }
    func testCreatesFolderAs700() throws {
        let f = EngineStateFile(url: dir.appendingPathComponent("ShareScale/engine.json"))
        try f.save(EngineState())
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ShareScale").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
    }
    func testLooseOwnFolderIsTightened() throws {
        let sub = dir.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try EngineStateFile(url: sub.appendingPathComponent("engine.json")).save(EngineState())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sub.path)[.posixPermissions] as? Int, 0o700)
    }
    func testBrokenFileGivesDefaultsAndProblem() throws {
        for bad in ["{", #"{"format":2,"mode":"1x","paused":false,"learned":[]}"#, #"{"format":1,"mode":"3x","paused":false,"learned":[]}"#,
                    #"{"format":1,"mode":"1x","paused":1,"learned":[]}"#] {
            try bad.write(to: stateFile.url, atomically: true, encoding: .utf8)
            chmod(stateFile.url.path, 0o600)
            let r = stateFile.load()
            XCTAssertEqual(r.state, EngineState(), bad); XCTAssertNotNil(r.problem, bad)
        }
    }
    func testSymlinkAndWritableByOthersAreRefused() throws {
        let real = dir.appendingPathComponent("real.json")
        var s = EngineState(); s.mode = .x2
        try EngineStateFile(url: real).save(s)
        try FileManager.default.createSymbolicLink(at: stateFile.url, withDestinationURL: real)
        XCTAssertEqual(stateFile.load().state.mode, .x1, "リンクはたどらない")
        XCTAssertNotNil(stateFile.load().problem)
        try FileManager.default.removeItem(at: stateFile.url)
        try stateFile.save(s)
        chmod(stateFile.url.path, 0o620)
        XCTAssertEqual(stateFile.load().state.mode, .x1, "ほかの人が書き込めるファイルは使わない")
        XCTAssertNotNil(stateFile.load().problem)
        chmod(stateFile.url.path, 0o640)
        XCTAssertEqual(stateFile.load().state.mode, .x1, "グループが読めるだけでも使わない（秘密と同じ 600 の規則）")
        XCTAssertNotNil(stateFile.load().problem)
        try FileManager.default.removeItem(at: stateFile.url)
        try FileManager.default.createSymbolicLink(at: stateFile.url, withDestinationURL: dir.appendingPathComponent("missing.json"))
        XCTAssertNotNil(stateFile.load().problem, "宙ぶらりんのリンクは「無い」ではなく問題")
    }
    func testLearnedIsCappedAt16() throws {
        var s = EngineState(); s.learned = (0..<20).map { String(format: "ID%02d", $0) }
        try stateFile.save(s)
        XCTAssertEqual(stateFile.load().state.learned, (4..<20).map { String(format: "ID%02d", $0) })
    }
}
