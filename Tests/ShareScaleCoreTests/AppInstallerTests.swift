import Darwin
import Security
import XCTest
@testable import ShareScaleCore

/// 複製と置き換え（仕様「Homebrew 側が開かれた時」の表・「置き換えの手順」・「複製が起動した時」）。
/// 実物の `~/Applications` には書かない（一時フォルダをホームとして使う）。アプリは起動しない（`/usr/bin/true` を入れた小さなバンドルを簡易署名するだけ）
final class AppInstallerTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    func facts(_ v: Int?, _ h: String?, id: String? = "io.github.taki-0105a.ShareScale") -> BundleFacts { BundleFacts(identifier: id, version: v, cdhash: h) }
    func copy(_ b: BundleFacts, symlink: Bool = false, mine: Bool = true) -> CopyFacts { CopyFacts(isSymlink: symlink, ownerIsMe: mine, bundle: b) }

    func testInstallPlanTable() {
        let own = facts(10200, "bb")
        XCTAssertEqual(Handoff.plan(copy: nil, own: own), .create, "無い → 作る")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "bb"), symlink: true), own: own), .abort(.symlink), "リンク → 中止")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "bb"), mine: false), own: own), .abort(.notOwner), "本人以外 → 中止")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "bb", id: "com.example.Other")), own: own), .abort(.wrongIdentifier), "識別子が違う → 中止")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "bb", id: nil)), own: own), .abort(.wrongIdentifier), "Info.plist を読めない → 中止")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(nil, "bb")), own: own), .abort(.unreadableVersion))
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10100, "aa")), own: own), .replace, "Homebrew 側が新しい → 置き換える")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "aa")), own: own), .replace, "同じ版で CDHash が違う（reinstall・予備の手順の後）→ 置き換える")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, nil)), own: own), .replace, "複製の署名を読めない → 置き換える")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10200, "bb")), own: own), .openCopy, "同じ → 開いて終了")
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10300, "cc")), own: own), .openCopy, "Homebrew 側が古い → 置き換えずに開く")
        XCTAssertTrue(CopyProblem.notOwner.message.contains("ほかのユーザ"))
        // 自分の署名を読めなければ、複製を確かめられないので何もしない（仮の値を使わない。点検 K）
        XCTAssertEqual(Handoff.plan(copy: nil, own: facts(10200, nil)), .abort(.unsigned))
        XCTAssertEqual(Handoff.plan(copy: copy(facts(10100, "aa")), own: facts(10200, nil)), .abort(.unsigned))
        XCTAssertTrue(CopyProblem.unsigned.message.contains("Homebrew でインストールし直して"))
    }

    func testCopyLaunchDecisions() {
        let own = facts(10100, "aa")
        let recorded = AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app")
        let cellar = "/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app"
        var checked: [String] = []
        func present(_ f: BundleFacts, _ real: String = cellar) -> Handoff.SourceFacts { .present(realPath: real, facts: f) }
        func decide(_ state: AppState, _ source: Handoff.SourceFacts?, safety: HandoffSafety.Problem? = nil) -> Handoff.CopyLaunch {
            Handoff.copyLaunch(state: state, source: source, own: own) { real in checked.append(real); return safety }
        }
        XCTAssertEqual(decide(AppState(), present(facts(10200, "bb"))), .nothing, "複製元の記録が無い（予備の手順で入れた）→ 確かめない")
        XCTAssertEqual(decide(recorded, .missing), .askUninstall, "複製元が消えた → 取り除きますか？")
        XCTAssertEqual(decide(recorded, present(facts(10200, "bb"))), .handoff(AppState.Attempt(build: 10200, cdhash: "bb"), realPath: cellar),
                       "新しい → 条件を確かめた実体のパスを開く（点検 D）")
        XCTAssertEqual(decide(recorded, present(facts(10100, "bb"))), .handoff(AppState.Attempt(build: 10100, cdhash: "bb"), realPath: cellar), "同じ版で CDHash が違う → 引き渡す")
        XCTAssertEqual(decide(recorded, present(facts(10100, "aa"))), .nothing, "同じ → 何もしない")
        XCTAssertEqual(decide(recorded, present(facts(10000, "bb"))), .nothing, "古い → 何もしない")
        XCTAssertEqual(checked, [cellar, cellar], "条件（バンドルの中を歩く）は引き渡す時だけ、解決した実体のパスで確かめる")
        var tried = recorded; tried.attemptedHandoff = AppState.Attempt(build: 10200, cdhash: "bb")
        XCTAssertEqual(decide(tried, present(facts(10200, "bb"))), .alreadyAttempted, "同じ版と CDHash への引き渡しは 1 回だけ")
        XCTAssertEqual(decide(tried, present(facts(10200, "cc"))), .handoff(AppState.Attempt(build: 10200, cdhash: "cc"), realPath: cellar), "違うものなら試みる")
        XCTAssertEqual(decide(recorded, present(facts(10200, "bb")), safety: .wrongOwner("/opt/homebrew/Cellar")), .unsafe(.wrongOwner("/opt/homebrew/Cellar")),
                       "条件を満たさなければ開かない（診断に理由）")
        XCTAssertEqual(decide(recorded, present(facts(nil, nil, id: nil))), .unreadable)
        XCTAssertEqual(decide(recorded, present(facts(10200, nil))), .unreadable, "複製元の署名を読めなければ引き渡さない（点検 K）")
        XCTAssertEqual(decide(recorded, .unreadable("EACCES")), .unreadable)
        let before = checked.count
        XCTAssertEqual(decide(recorded, present(facts(10200, "bb"), "/Users/x/evil/ShareScale.app")), .notHomebrew,
                       "記録の場所が差し替えられて、実体が Homebrew の形でなければ開かない（点検 D）")
        XCTAssertEqual(checked.count, before, "形でなければ条件も確かめない")
        XCTAssertEqual(Handoff.readSource(dir.appendingPathComponent("gone/ShareScale.app").path), .missing)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("file").path, contents: Data())
        XCTAssertEqual(Handoff.readSource(dir.appendingPathComponent("file/ShareScale.app").path), .missing, "ENOTDIR も消えたものとして扱う")
        guard case .failure(let e) = AppLocation.resolve(dir.appendingPathComponent("gone").path) else { return XCTFail("無いものは解決できない") }
        XCTAssertEqual(e.code, .ENOENT, "理由を errno に頼らずに受け取る（点検 T）")
    }

    // ---- 一時フォルダの中の小さなバンドル ----

    /// `/usr/bin/true` を実行体にした小さなバンドルを作り、簡易署名する（版と印で CDHash を変える）。
    /// 中に同じ形の小さな Host（`Contents/Library/LoginItems/ShareScale Host.app`）を入れ、中を先に署名する（組み立てのスクリプトと同じ順）
    func makeBundle(_ url: URL, version: Int, marker: String, identifier: String = AppIdentifiers.app, nested: Bool = true) throws -> BundleFacts {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        if nested {
            _ = try makeBundle(url.appendingPathComponent("Contents/Library/LoginItems/ShareScale Host.app"), version: version, marker: marker,
                               identifier: AppIdentifiers.host, nested: false)
        }
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: url.appendingPathComponent("Contents/MacOS/ShareScale").path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "ShareScale", "CFBundlePackageType": "APPL",
                                   "CFBundleVersion": String(version)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/Resources/marker.txt"))
        XCTAssertEqual(runTool("/usr/bin/codesign", ["--force", "-s", "-", "--timestamp=none", url.path]), 0, "簡易署名")
        return BundleFacts.read(url)
    }

    func testInstallCreatesReplacesAndKeepsTheCopyOnFailure() async throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let paths = AppPaths(home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let v1 = try makeBundle(dir.appendingPathComponent("v1/ShareScale.app"), version: 10100, marker: "one")
        let v2 = try makeBundle(dir.appendingPathComponent("v2/ShareScale.app"), version: 10200, marker: "two")
        XCTAssertEqual(v1.identifier, AppIdentifiers.app); XCTAssertEqual(v1.version, 10100)
        let h1 = try XCTUnwrap(v1.cdhash), h2 = try XCTUnwrap(v2.cdhash)
        XCTAssertNotEqual(h1, h2)
        // 置き場所は APFS（RENAME_SWAP を使える。仕様「実装計画で扱う事項」）
        var fs = statfs()
        XCTAssertEqual(statfs(dir.path, &fs), 0)
        XCTAssertEqual(withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }, "apfs")

        let terminated = Locked(0)
        let copyAlwaysPresent = Locked(true)
        let copyURL = paths.copy
        func ports(terminate: Bool = true, tamper: String? = nil) -> InstallerPorts {
            InstallerPorts(terminateRunningCopy: { _, timeout in
                XCTAssertEqual(timeout, 5); terminated.update { $0 += 1 }; return terminate
            }, verify: { url, id, h in
                if FileManager.default.fileExists(atPath: copyURL.path) == false { copyAlwaysPresent.value = false }
                return CodeSignature.verify(url, identifier: id, cdhash: h)
            }, copyItem: { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                if let t = tamper { try Data("changed".utf8).write(to: to.appendingPathComponent(t)) }
            })
        }
        // 無い → 作る（~/Applications も 700 で作る）
        var r = await AppInstaller.install(.create, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h1, ports: ports())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(BundleFacts.read(paths.copy), v1)
        XCTAssertEqual(terminated.value, 0, "作る時は終了を頼まない")
        var st = stat()
        XCTAssertEqual(lstat(paths.applications.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.applications.path), ["ShareScale.app"], "一時的なものは残らない")
        copyAlwaysPresent.value = true   // 作る時はまだ無い。ここから置き換えの間ずっと置かれていることを見る
        // 新しい版 → 動いている複製に終了を頼み、RENAME_SWAP で入れ替える（途中で複製が無くならない）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v2/ShareScale.app"), copy: paths.copy, ownCDHash: h2, ports: ports())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(BundleFacts.read(paths.copy), v2)
        XCTAssertEqual(CodeSignature.verify(paths.copy, identifier: AppIdentifiers.app, cdhash: h2), errSecSuccess)
        XCTAssertEqual(terminated.value, 1)
        XCTAssertTrue(copyAlwaysPresent.value, "署名を確かめる時点でも複製は元のまま置かれている")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.applications.path), ["ShareScale.app"], "旧版は一時的な名前に移ってから消える")
        // 複製の途中で壊れた → 署名が一致せず置かない（複製は元のまま・一時的なものは片付ける）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h1,
                                       ports: ports(tamper: "Contents/Resources/marker.txt"))
        guard case let .failure(.verifyFailed(status)) = r else { return XCTFail("\(r)") }
        XCTAssertNotEqual(status, errSecSuccess)
        // 中の Host が壊れた時も断る（kSecCSCheckNestedCode）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h1,
                                       ports: ports(tamper: "Contents/Library/LoginItems/ShareScale Host.app/Contents/Resources/marker.txt"))
        guard case .failure(.verifyFailed) = r else { return XCTFail("中の Host の改ざん: \(r)") }
        XCTAssertEqual(BundleFacts.read(paths.copy), v2, "複製は元のまま")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.applications.path), ["ShareScale.app"])
        // 別のアプリの CDHash を要件にした時も断る（出どころではなく「元と同じ」ことの確かめ）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h2, ports: ports())
        guard case .failure(.verifyFailed) = r else { return XCTFail("\(r)") }
        // 複製が終わらない → 中止（複製しない）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h1, ports: ports(terminate: false))
        XCTAssertEqual(r.failureValue, .copyStillRunning)
        XCTAssertEqual(BundleFacts.read(paths.copy), v2)
        // 落ちたプロセスの一時的なもの（pid が生きていない）は次の入れ替えで消す
        try FileManager.default.createDirectory(at: paths.applications.appendingPathComponent(".ShareScale-install-999999-1/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.applications.appendingPathComponent(".ShareScale-old-999999-2/Contents"), withIntermediateDirectories: true)   // 予備の手順の退避（再点検 軽微 2）
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: paths.copy, ownCDHash: h1, ports: ports())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.applications.path), ["ShareScale.app"])
        XCTAssertEqual(BundleFacts.read(paths.copy), v1, "同じ版で CDHash が違うもの・古いものへの置き換えも同じ手順")
        // ~/Applications がリンク・ほかの人が書ける（777）・書き込みを許す ACL → 使わない（点検 E）
        let other = AppPaths(home: dir.appendingPathComponent("home2", isDirectory: true))
        try FileManager.default.createDirectory(at: other.home, withIntermediateDirectories: true)
        symlink(dir.path, other.applications.path)
        r = await AppInstaller.install(.create, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: other.copy, ownCDHash: h1, ports: ports())
        XCTAssertEqual(r.failureValue, .applicationsFolder("not a directory"))
        unlink(other.applications.path)
        try FileManager.default.createDirectory(at: other.applications, withIntermediateDirectories: false)
        chmod(other.applications.path, 0o777)
        r = await AppInstaller.install(.create, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: other.copy, ownCDHash: h1, ports: ports())
        XCTAssertEqual(r.failureValue, .applicationsFolder("writable by group or others"))
        chmod(other.applications.path, 0o755)
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone deny delete", other.applications.path]), 0)
        r = await AppInstaller.install(.create, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: other.copy, ownCDHash: h1, ports: ports())
        XCTAssertNoThrow(try r.get(), "拒否の ACL は書き込みを許さないので使える")
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone allow add_file,delete_child", other.applications.path]), 0)
        r = await AppInstaller.install(.replace, source: dir.appendingPathComponent("v1/ShareScale.app"), copy: other.copy, ownCDHash: h1, ports: ports())
        XCTAssertEqual(r.failureValue, .applicationsFolder("an ACL allows others to write"))
        XCTAssertTrue(AppInstaller.Failure.applicationsFolder("x").message.contains("ほかの人が書き込めない"))
        XCTAssertEqual(runTool("/bin/chmod", ["-N", other.applications.path]), 0)   // 片付けのため（削除を拒む ACL を外す）
        // 複製の様子の読み取り（リンクはたどらない）
        XCTAssertEqual(CopyFacts.read(paths.copy), CopyFacts(isSymlink: false, ownerIsMe: true, bundle: v1))
        symlink(paths.copy.path, dir.appendingPathComponent("link.app").path)
        XCTAssertEqual(CopyFacts.read(dir.appendingPathComponent("link.app"))?.isSymlink, true)
        XCTAssertNil(CopyFacts.read(dir.appendingPathComponent("none.app")))
        XCTAssertEqual(Handoff.readSource(dir.appendingPathComponent("link.app").path),
                       .present(realPath: try XCTUnwrap(AppLocation.realPath(paths.copy.path)), facts: v1), "複製元は 1 回だけリンクを解決して読む（opt/sharescale はリンク）")
    }
}

extension Result {
    var failureValue: Failure? { if case let .failure(f) = self { return f }; return nil }
}
