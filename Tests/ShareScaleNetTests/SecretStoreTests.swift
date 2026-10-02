import Darwin
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

final class SecretStoreTests: XCTestCase {
    var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sss-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        chmod(base.appendingPathComponent("pairings/host").path, 0o700)
        try? FileManager.default.removeItem(at: base)
    }
    func store(_ role: PairingRole = .host, machine: String = "MAC-1") -> SecretStore { SecretStore(base: base, role: role, machine: machine) }
    func mode(_ path: String) -> mode_t { var st = stat(); lstat(path, &st); return st.st_mode & 0o777 }
    var hostDir: String { base.appendingPathComponent("pairings/host").path }
    func keyPath(_ id: PairingID) -> String { hostDir + "/" + id.hex + ".key" }

    func testSaveAndLoadWithStrictPermissions() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        let r = s.loadAll()
        XCTAssertEqual(r.pairings, [StoredPairing(id: pid(1), secret: secret(9))])
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(mode(keyPath(pid(1))), 0o600)
        for d in [base.path, base.appendingPathComponent("pairings").path, hostDir] { XCTAssertEqual(mode(d), 0o700, d) }
        let excluded = try base.appendingPathComponent("pairings").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "pairings/ はバックアップの対象から外す")
        let text = try String(contentsOfFile: keyPath(pid(1)))
        XCTAssertTrue(text.contains("\"role\":\"host\"") && text.contains("\"machine\":\"MAC-1\"") && text.contains("\"format\":1"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: hostDir).contains { $0.hasSuffix(".tmp") }, "一時ファイルを残さない")
    }
    var viewerDir: String { base.appendingPathComponent("pairings/viewer").path }
    func testRolesAreSeparated() throws {
        try store(.host).save(StoredPairing(id: pid(1), secret: secret(9)))
        XCTAssertEqual(store(.viewer).loadAll().pairings, [], "見る側は host/ を読まない")
    }
    func testHardLinkIsNotUsed() throws {
        try store(.host).save(StoredPairing(id: pid(1), secret: secret(9)))
        _ = store(.viewer).loadAll()
        XCTAssertEqual(link(keyPath(pid(1)), viewerDir + "/" + pid(1).hex + ".key"), 0)
        let r = store(.viewer).loadAll()
        XCTAssertEqual(r.pairings, [])
        XCTAssertEqual(r.problems.map(\.reason), [.multipleLinks], "ハードリンクは使わない")
    }
    func testFileOfTheOtherRoleIsNotUsed() throws {
        // host の役のファイルを viewer/ に写しても使わない
        try store(.host).save(StoredPairing(id: pid(1), secret: secret(9)))
        _ = store(.viewer).loadAll()
        try FileManager.default.copyItem(atPath: keyPath(pid(1)), toPath: viewerDir + "/" + pid(1).hex + ".key")
        XCTAssertEqual(store(.viewer).loadAll().problems.map(\.reason), [.roleMismatch])
    }
    func testMachineMustMatch() throws {
        try store().save(StoredPairing(id: pid(1), secret: secret(9)))
        XCTAssertEqual(store(machine: "MAC-2").loadAll().problems.map(\.reason), [.otherMachine], "移行アシスタントで写ったペアリングは使わない")
    }
    func testIDMustMatchTheFileName() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        XCTAssertEqual(rename(keyPath(pid(1)), keyPath(pid(2))), 0)
        XCTAssertEqual(s.loadAll().problems.map(\.reason), [.idMismatch])
    }
    func testUnsafeFilesAreSkippedNotFatal() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        try s.save(StoredPairing(id: pid(2), secret: secret(2)))
        try s.save(StoredPairing(id: pid(3), secret: secret(3)))
        chmod(keyPath(pid(1)), 0o644)                                                   // 緩い権限
        try "not json\n".write(toFile: keyPath(pid(2)), atomically: false, encoding: .utf8)  // 壊れた中身（書き込みで権限は 600 のまま）
        unlink(keyPath(pid(3))); symlink("/etc/hosts", keyPath(pid(3)))               // シンボリックリンク
        try s.save(StoredPairing(id: pid(4), secret: secret(4)))
        let r = s.loadAll()
        XCTAssertEqual(r.pairings, [StoredPairing(id: pid(4), secret: secret(4))], "使えるものだけを使い、止まらない")
        XCTAssertEqual(Set(r.problems.map(\.reason)), [.loosePermissions, .badFormat, .notRegularFile])
    }
    func testKeyCountIncludesUnreadableKeys() throws {
        let s = store()
        XCTAssertEqual(s.keyCount(), 0)
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        try s.save(StoredPairing(id: pid(2), secret: secret(2)))
        chmod(keyPath(pid(2)), 0o644)
        XCTAssertEqual(s.keyCount(), 2, "読めない .key も数える（save の上限と同じ数え方）")
        XCTAssertEqual(s.loadAll().pairings.count, 1)
        chmod(hostDir, 0o755)
        XCTAssertNil(s.keyCount(), "フォルダが使えなければ nil")
        chmod(hostDir, 0o700)
    }
    func testTooLargeFileIsSkipped() throws {
        let s = store(); _ = s.loadAll()
        let fd = open(keyPath(pid(5)), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        _ = [UInt8](repeating: 0x20, count: 5000).withUnsafeBytes { write(fd, $0.baseAddress, 5000) }; close(fd)
        XCTAssertEqual(s.loadAll().problems.map(\.reason), [.tooLarge])
    }
    func testLooseFolderIsNotUsed() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(9)))
        chmod(hostDir, 0o755)
        let r = s.loadAll()
        XCTAssertEqual(r.pairings, [])
        XCTAssertEqual(r.problems.map(\.reason), [.folderLoosePermissions])
        XCTAssertThrowsError(try s.save(StoredPairing(id: pid(2), secret: secret(2))))
    }
    func testReplace() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        try s.save(StoredPairing(id: pid(1), secret: secret(2)))   // 名乗りの承認で取り替える
        XCTAssertEqual(s.loadAll().pairings, [StoredPairing(id: pid(1), secret: secret(2))])
    }
    func testDelete() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        try s.delete(pid(1))
        XCTAssertEqual(s.loadAll().pairings, [])
        XCTAssertNoThrow(try s.delete(pid(1)), "無いものの削除は成功扱い")
    }
    func testLimitOf32() throws {
        let s = store()
        for n in 1...32 { try s.save(StoredPairing(id: pid(UInt8(n)), secret: secret(1))) }
        XCTAssertThrowsError(try s.save(StoredPairing(id: pid(33), secret: secret(1)))) { XCTAssertEqual($0 as? SecretStoreError, .limitReached) }
        XCTAssertNoThrow(try s.save(StoredPairing(id: pid(1), secret: secret(2))), "上限でも取り替えはできる")
    }
    // ---- 点検で足した性質 ----
    func inode(_ path: String) -> ino_t { var st = stat(); lstat(path, &st); return st.st_ino }

    func testReplacingALooseFileMakesANew600File() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        chmod(keyPath(pid(1)), 0o644)
        let before = inode(keyPath(pid(1)))
        try s.save(StoredPairing(id: pid(1), secret: secret(2)))
        XCTAssertEqual(mode(keyPath(pid(1))), 0o600, "取り替えた後は 600")
        XCTAssertNotEqual(inode(keyPath(pid(1))), before, "直接上書きせず、新しいファイルと入れ替える")
        XCTAssertEqual(s.loadAll().pairings, [StoredPairing(id: pid(1), secret: secret(2))])
    }
    /// 終わったプロセスの番号（使い回されていないことも確かめる）
    func deadPID() throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        let n = p.processIdentifier
        guard kill(n, 0) != 0, errno == ESRCH else { throw XCTSkip("終わったプロセスの番号がすぐ使い回された") }
        return n
    }
    func testStaleTempFilesOfEndedProcessesAreRemoved() throws {
        let s = store(); _ = s.loadAll()
        let dead = try deadPID()
        func plant() -> [String] {
            let names = [".\(pid(1).hex).\(dead).456.tmp", ".\(pid(2).hex).\(dead).1.tmp"]
            for n in names { XCTAssertTrue(FileManager.default.createFile(atPath: hostDir + "/" + n, contents: Data("secret".utf8), attributes: [.posixPermissions: 0o600])) }
            return names
        }
        let keep = ".notes.tmp"   // 形の違うものは消さない
        XCTAssertTrue(FileManager.default.createFile(atPath: hostDir + "/" + keep, contents: Data(), attributes: [.posixPermissions: 0o600]))
        var planted = plant()
        _ = s.loadAll()
        var names = try FileManager.default.contentsOfDirectory(atPath: hostDir)
        XCTAssertTrue(planted.allSatisfy { !names.contains($0) }, "読み込みで、落ちたプロセスの一時ファイルを消す")
        XCTAssertTrue(names.contains(keep))
        planted = plant()
        try s.save(StoredPairing(id: pid(3), secret: secret(3)))
        names = try FileManager.default.contentsOfDirectory(atPath: hostDir)
        XCTAssertTrue(planted.allSatisfy { !names.contains($0) }, "保存でも消す")
        XCTAssertEqual(s.loadAll().pairings, [StoredPairing(id: pid(3), secret: secret(3))])
    }
    func testTempFilesOfLiveProcessesAreKept() throws {
        let s = store(); _ = s.loadAll()
        // 自分のプロセスと、動いているほかのプロセス（launchd。kill は EPERM で存在だけ分かる）の一時ファイル
        let live = [".\(pid(1).hex).\(getpid()).7.tmp", ".\(pid(2).hex).1.7.tmp"]
        for n in live { XCTAssertTrue(FileManager.default.createFile(atPath: hostDir + "/" + n, contents: Data(), attributes: [.posixPermissions: 0o600])) }
        _ = s.loadAll()
        try s.save(StoredPairing(id: pid(3), secret: secret(3)))
        let names = try FileManager.default.contentsOfDirectory(atPath: hostDir)
        XCTAssertTrue(live.allSatisfy(names.contains), "書き込み中かもしれないものは消さない")
    }

    // ---- 同時の使用（点検で再現したもの）----
    func testTwoStoresOfTheSameRoleNeverBreakASave() throws {
        let s1 = store(), s2 = store()
        _ = s1.loadAll()
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            let s = worker % 2 == 0 ? s1 : s2
            for n in 0..<60 {
                if worker < 2 {
                    do { try s.save(StoredPairing(id: pid(UInt8(1 + (n % 8))), secret: secret(UInt8(n % 200)))) } catch { failures.add() }
                } else {
                    if !s.loadAll().problems.isEmpty { failures.add() }
                }
            }
        }
        XCTAssertEqual(failures.value, 0, "同じ役割の 2 つのインスタンスで、保存も読み込みも失敗しない")
    }
    func testFirstUseFromBothRolesAtOnce() throws {
        for round in 0..<40 {
            let root = base.appendingPathComponent("round-\(round)", isDirectory: true)
            XCTAssertEqual(mkdir(base.path, 0o700) == 0 || errno == EEXIST, true)
            let stores = [SecretStore(base: root, role: .host, machine: "MAC-1"), SecretStore(base: root, role: .viewer, machine: "MAC-1")]
            let problems = Counter()
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                let r = stores[i].loadAll()
                if !r.problems.isEmpty { problems.add() }
            }
            XCTAssertEqual(problems.value, 0, "空の置き場所で host と viewer を同時に読んでも失敗しない（\(round) 回目）")
            if problems.value > 0 { break }
        }
    }
    func testProblemNamesTheFolderThatFailed() throws {
        let s = store()
        _ = s.loadAll()
        chmod(base.appendingPathComponent("pairings").path, 0o755)
        defer { chmod(base.appendingPathComponent("pairings").path, 0o700) }
        let r = s.loadAll()
        XCTAssertEqual(r.problems, [StoreProblem(name: base.appendingPathComponent("pairings", isDirectory: true).path, reason: .folderLoosePermissions)])
    }
    func testBackupExclusionIsAppliedToExistingFolders() throws {
        // 印の無いフォルダを先に作っておく（前の版で作った・別の道具で写した、など）。700 で正しい
        let dir = base.appendingPathComponent("pairings", isDirectory: true).path
        for d in [base.path, dir, hostDir] { XCTAssertEqual(mkdir(d, 0o700), 0, d) }
        // 印（Time Machine の付いて回る除外の拡張属性）を直接見る。URL の値は URL ごとに覚えられるため
        func excluded() -> Bool { getxattr(dir, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        XCTAssertFalse(excluded())
        XCTAssertEqual(store().loadAll().problems, [])
        XCTAssertTrue(excluded(), "既存のフォルダにも付ける")
        XCTAssertEqual(try URL(fileURLWithPath: dir, isDirectory: true).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func testDeleteChecksFoldersFirst() throws {
        let s = store()
        try s.save(StoredPairing(id: pid(1), secret: secret(1)))
        chmod(hostDir, 0o755)
        XCTAssertThrowsError(try s.delete(pid(1))) { XCTAssertEqual($0 as? SecretStoreError, .folder(.folderLoosePermissions)) }
        XCTAssertEqual(access(keyPath(pid(1)), F_OK), 0, "確かめられないフォルダでは消さない")
    }
    func testWriteFailureReportsTheRenameErrno() throws {
        let s = store(); _ = s.loadAll()
        XCTAssertEqual(mkdir(keyPath(pid(1)), 0o700), 0)   // 入れ替え先がフォルダ → rename が EISDIR
        XCTAssertEqual(creat(keyPath(pid(1)) + "/x", 0o600) >= 0, true)
        XCTAssertThrowsError(try s.save(StoredPairing(id: pid(1), secret: secret(1)))) {
            guard case let .writeFailed(e)? = $0 as? SecretStoreError else { return XCTFail("\($0)") }
            XCTAssertTrue([EISDIR, ENOTEMPTY, EEXIST].contains(e), "rename の errno（\(e)）")
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: hostDir).contains { $0.hasSuffix(".tmp") }, "失敗しても一時ファイルを残さない")
    }

    // ---- 所有者の確認 ----
    func testHardLinkToRootOwnedFileIsWrongOwner() throws {
        let s = store(); _ = s.loadAll()
        // sudo なしで作れる、root の持ち物のファイルへのハードリンク（同じボリュームにあるもの）
        let candidates = ["/private/etc/hosts", "/private/etc/ssh/ssh_config", "/private/var/db/.AppleSetupDone"]
        guard let target = candidates.first(where: { var st = stat(); return lstat($0, &st) == 0 && st.st_uid == 0 && (st.st_mode & S_IFMT) == S_IFREG
                                                                   && st.st_mode & 0o004 != 0 && link($0, keyPath(pid(1))) == 0 }) else {
            throw XCTSkip("一時フォルダと同じボリュームに、ハードリンクを作れる root のファイルが見つからない")
        }
        defer { unlink(keyPath(pid(1))) }
        XCTAssertEqual(s.loadAll().problems.map(\.reason), [.wrongOwner], "\(target) へのリンク")
    }
    func testRootOwnedBaseFolderIsWrongOwner() throws {
        // 既存の root のフォルダ（書き込めない場所。何も作らない）
        let rootOwned = SecretStore(base: URL(fileURLWithPath: "/usr/share", isDirectory: true), role: .host, machine: "MAC-1")
        XCTAssertEqual(rootOwned.loadAll().problems.map(\.reason), [.folderWrongOwner])
        XCTAssertThrowsError(try rootOwned.save(StoredPairing(id: pid(1), secret: secret(1)))) { XCTAssertEqual($0 as? SecretStoreError, .folder(.folderWrongOwner)) }
        XCTAssertThrowsError(try rootOwned.delete(pid(1))) { XCTAssertEqual($0 as? SecretStoreError, .folder(.folderWrongOwner)) }
    }
    func testUncreatableBaseUnderARootFolderIsUnavailable() throws {
        // root のフォルダの下の存在しない名前（作れない）
        let missing = URL(fileURLWithPath: "/Library/ShareScale-test-\(UUID().uuidString)", isDirectory: true)
        let underRoot = SecretStore(base: missing, role: .host, machine: "MAC-1")
        XCTAssertEqual(underRoot.loadAll().problems.map(\.reason), [.folderUnavailable])
        XCTAssertThrowsError(try underRoot.save(StoredPairing(id: pid(1), secret: secret(1)))) { XCTAssertEqual($0 as? SecretStoreError, .folder(.folderUnavailable)) }
        XCTAssertNotEqual(access(missing.path, F_OK), 0)
    }

    func testMachineIdentity() {
        let u = MachineIdentity.platformUUID()
        XCTAssertNotNil(u)
        XCTAssertNotNil(u.flatMap(UUID.init(uuidString:)), "IOPlatformUUID は UUID の形")
    }
}
