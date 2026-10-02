import Darwin
import XCTest
@testable import ShareScaleNet

/// 共通のファイルの守り方（`ProtectedFiles`。`SecretStore`・host-control・engine.json が使う）
final class ProtectedFilesTests: XCTestCase {
    var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("spf-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { chmod(base.path, 0o700); try? FileManager.default.removeItem(at: base) }
    func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o777 }

    func testPrepareFoldersCreates700AndRefusesLooseOrForeign() throws {
        let inner = base.appendingPathComponent("a/b", isDirectory: true)
        XCTAssertNil(ProtectedFiles.prepareFolders([base, base.appendingPathComponent("a"), inner]))
        XCTAssertEqual(mode(base.path), 0o700); XCTAssertEqual(mode(inner.path), 0o700)
        XCTAssertNil(ProtectedFiles.prepareFolders([base, inner]), "2 回目も成功（EEXIST は成功）")
        chmod(inner.path, 0o750)
        XCTAssertEqual(ProtectedFiles.prepareFolders([base, inner])?.reason, .folderLoosePermissions)
        chmod(inner.path, 0o700)
        let file = base.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(ProtectedFiles.prepareFolders([file])?.reason, .folderNotDirectory)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)
        XCTAssertEqual(ProtectedFiles.prepareFolders([link])?.reason, .folderNotDirectory, "リンクはたどらない")
    }

    func testReadFileChecksTheOpenedFile() throws {
        XCTAssertNil(ProtectedFiles.prepareFolders([base]))
        let ok = base.appendingPathComponent("ok")
        XCTAssertEqual(ProtectedFiles.writeReplacing(ok, temporaryName: ".ok.tmp", bytes: Array("hello".utf8), durable: true), 0)
        XCTAssertEqual(mode(ok.path), 0o600)
        XCTAssertEqual(try ProtectedFiles.readFile(ok, limit: 16).get(), Data("hello".utf8))
        XCTAssertEqual(ProtectedFiles.readFile(ok, limit: 4), .failure(.tooLarge))
        chmod(ok.path, 0o640)
        XCTAssertEqual(ProtectedFiles.readFile(ok, limit: 16), .failure(.loosePermissions))
        chmod(ok.path, 0o600)
        let hard = base.appendingPathComponent("hard")
        XCTAssertEqual(link(ok.path, hard.path), 0)
        XCTAssertEqual(ProtectedFiles.readFile(ok, limit: 16), .failure(.multipleLinks))
        unlink(hard.path)
        let sym = base.appendingPathComponent("sym")
        XCTAssertEqual(symlink(ok.path, sym.path), 0)
        XCTAssertEqual(ProtectedFiles.readFile(sym, limit: 16), .failure(.notRegularFile), "リンクはたどらない")
        let empty = base.appendingPathComponent("empty")
        XCTAssertEqual(ProtectedFiles.writeReplacing(empty, temporaryName: ".empty.tmp", bytes: [], durable: false), 0)
        XCTAssertEqual(ProtectedFiles.readFile(empty, limit: 16), .failure(.unreadable), "空のファイルは使わない")
        XCTAssertEqual(ProtectedFiles.readFile(base.appendingPathComponent("missing"), limit: 16), .failure(.unreadable))
        XCTAssertEqual(ProtectedFiles.readFile(base, limit: 16), .failure(.notRegularFile))
    }

    func testWriteReplacingLeavesNoTemporaryAndRefusesExistingTemporary() throws {
        XCTAssertNil(ProtectedFiles.prepareFolders([base]))
        let f = base.appendingPathComponent("f")
        XCTAssertEqual(ProtectedFiles.writeReplacing(f, temporaryName: ".f.1.tmp", bytes: Array("a".utf8), durable: true), 0)
        XCTAssertEqual(ProtectedFiles.writeReplacing(f, temporaryName: ".f.2.tmp", bytes: Array("b".utf8), durable: false), 0, "置き換え")
        XCTAssertEqual(try ProtectedFiles.readFile(f, limit: 16).get(), Data("b".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["f"], "一時ファイルを残さない")
        try Data("x".utf8).write(to: base.appendingPathComponent(".f.3.tmp"))
        XCTAssertEqual(ProtectedFiles.writeReplacing(f, temporaryName: ".f.3.tmp", bytes: Array("c".utf8), durable: true), EEXIST, "同じ一時ファイルがあれば失敗（O_EXCL）")
        XCTAssertEqual(try ProtectedFiles.readFile(f, limit: 16).get(), Data("b".utf8), "失敗しても元のファイルはそのまま")
        XCTAssertEqual(ProtectedFiles.writeReplacing(base.appendingPathComponent("none/f"), temporaryName: ".f.tmp", bytes: [], durable: true), ENOENT)
    }

    func testRemoveStaleTemporariesKeepsOwnAndLivingAndUnknownNames() throws {
        XCTAssertNil(ProtectedFiles.prepareFolders([base]))
        let dead = "999999"   // macOS の pid の上限は 99998 なので、動いているプロセスではない
        for n in [".t.\(dead).tmp", ".t.\(getpid()).tmp", ".t.1.tmp", ".t.x.tmp", "other"] { try Data("x".utf8).write(to: base.appendingPathComponent(n)) }
        // 名前が `.t.<pid>.tmp` なら pid（読めなければ nil）、ほかは形が違う
        ProtectedFiles.removeStaleTemporaries(in: base) { name in
            guard name.hasPrefix(".t."), name.hasSuffix(".tmp") else { return nil }
            return .some(pid_t(name.dropFirst(3).dropLast(4)))
        }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: base.path))
        XCTAssertEqual(left, [".t.\(getpid()).tmp", ".t.1.tmp", "other"], "自分・動いているプロセス（launchd）・形の違う名前は残し、落ちたプロセスのものと pid の読めないものは消す")
        XCTAssertTrue(ProtectedFiles.isAlive(getpid())); XCTAssertTrue(ProtectedFiles.isAlive(1))
        XCTAssertFalse(ProtectedFiles.isAlive(999_999)); XCTAssertFalse(ProtectedFiles.isAlive(0)); XCTAssertFalse(ProtectedFiles.isAlive(-1))
    }
}
