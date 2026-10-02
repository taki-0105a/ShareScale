import Darwin
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 付帯情報（`<id>.meta`）の保管（仕様「保管」「解除」）
final class SecretStoreMetaTests: XCTestCase {
    var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }
    func store() -> SecretStore { SecretStore(base: base, role: .host, machine: "MAC-1") }
    var hostDir: String { base.appendingPathComponent("pairings/host").path }
    func path(_ id: PairingID, _ ext: String) -> String { hostDir + "/" + id.hex + "." + ext }
    func stat(_ p: String) -> Darwin.stat { var st = Darwin.stat(); lstat(p, &st); return st }

    func testSaveAndLoadMeta() throws {
        let s = store()
        try s.saveMeta(pid(1), Data(#"{"format":1}"#.utf8))
        let r = s.loadMetas()
        XCTAssertEqual(r.metas, [pid(1): Data(#"{"format":1}"#.utf8)])
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(stat(path(pid(1), "meta")).st_mode & 0o777, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: hostDir).contains { $0.hasSuffix(".tmp") }, "一時ファイルを残さない")
        XCTAssertEqual(s.loadAll().pairings, [], ".meta はペアリングとして読まない")
    }
    func testMetaUpdateDoesNotRewriteTheKey() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        let before = stat(path(pid(1), "key"))
        try s.saveMeta(pid(1), Data("a".utf8)); try s.saveMeta(pid(1), Data("b".utf8))
        let after = stat(path(pid(1), "key"))
        XCTAssertEqual(before.st_ino, after.st_ino, "秘密のファイルは書き直さない")
        XCTAssertEqual(s.loadMetas().metas[pid(1)], Data("b".utf8))
    }
    func testDeleteRemovesKeyThenMeta() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        try s.saveMeta(pid(1), Data("x".utf8))
        try s.delete(pid(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(pid(1), "key")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(pid(1), "meta")))
        try s.delete(pid(1))   // 2 回目も失敗しない
    }
    func testDeleteMetaKeepsTheKey() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        try s.saveMeta(pid(1), Data("x".utf8))
        try s.deleteMeta(pid(1))
        try s.deleteMeta(pid(1))   // 無くても失敗しない
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(pid(1), "meta")))
        XCTAssertEqual(s.loadAll().pairings.map(\.id), [pid(1)])
    }
    func testUnsafeMetaFilesAreNotUsed() throws {
        let s = store()
        try s.saveMeta(pid(1), Data("x".utf8))
        chmod(path(pid(1), "meta"), 0o644)
        try "y".write(toFile: base.appendingPathComponent("elsewhere").path, atomically: true, encoding: .utf8)
        XCTAssertEqual(symlink(base.appendingPathComponent("elsewhere").path, path(pid(2), "meta")), 0)
        try "z".write(toFile: hostDir + "/not-an-id.meta", atomically: true, encoding: .utf8)
        let r = s.loadMetas()
        XCTAssertEqual(r.metas, [:])
        XCTAssertEqual(Set(r.problems.map(\.reason)), [.loosePermissions, .notRegularFile, .idMismatch])
    }
    func testMetaSizeAndPairingLimit() throws {
        let s = store()
        XCTAssertThrowsError(try s.saveMeta(pid(1), Data(count: 4097)))
        for i in 0..<32 { try s.save(StoredPairing(id: pid(UInt8(i + 1)), secret: secret(1))) }
        XCTAssertNoThrow(try s.saveMeta(pid(1), Data("x".utf8)), ".meta は 32 件の上限に数えない")
    }
}
