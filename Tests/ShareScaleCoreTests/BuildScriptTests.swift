import XCTest
import ShareScaleEngine
import ShareScaleHostCore
import ShareScaleProtocol
@testable import ShareScaleCore

/// 組み立てのスクリプト（`scripts/lib/sharescale-version.sh`・`scripts/lib/sharescale-build.sh`・`scripts/build-sharescale.sh`）。
/// **スクリプトはすべて一時の HOME で動かし、PATH の先頭に必ず失敗する偽の `swift` を置く**（利用者のホームに書かない・組み立てない。点検 H）
final class BuildScriptTests: TempDirTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 一時の HOME（`<dir>/home`）と、必ず失敗する偽の `swift` を先頭に置いた PATH
    var home: URL { dir.appendingPathComponent("home", isDirectory: true) }
    var environment: [String: String] {
        let bin = dir.appendingPathComponent("fakebin", isDirectory: true)
        if !FileManager.default.fileExists(atPath: bin.appendingPathComponent("swift").path) {
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("swift").path, contents: Data("#!/bin/sh\necho \"fake swift $*\" >&2\nexit 97\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        return ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    }

    /// bash で `script` を動かす（`$1` はリポジトリの根。一時の HOME）
    func bash(_ script: String, _ args: [String] = [], home: String? = nil) -> ChildProcess.Result {
        var env = environment
        if let home { env["HOME"] = home }
        return ChildProcess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", script, "_", root.path] + args, timeout: 30, environment: env)
    }

    /// 共通の関数を `dir` の VERSION で呼ぶ（標準出力に「版 数 コミット」）
    func version(in dir: URL) -> ChildProcess.Result {
        bash(". \"$1/scripts/lib/sharescale-version.sh\" && sharescale_version \"$2\" && echo \"$SHARESCALE_VERSION $SHARESCALE_BUNDLE_VERSION $SHARESCALE_COMMIT\"", [dir.path])
    }

    func testSharedVersionFunctionMatchesAppVersion() throws {
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        let v = try XCTUnwrap(AppVersion(text))
        let r = version(in: root)
        XCTAssertEqual(r.status, 0)
        let parts = r.output.split(separator: " ")
        guard hasCount(parts, 3, r.output) else { return }
        XCTAssertEqual(String(parts[0]), v.shortString); XCTAssertEqual(String(parts[1]), String(v.bundleVersion), "CFBundleVersion = x×10000+y×100+z")
        // BUILD_INFO があればそれ（git の無い tarball）
        try Data("2.3.4\n".utf8).write(to: dir.appendingPathComponent("VERSION"))
        try Data("abc1234\n".utf8).write(to: dir.appendingPathComponent("BUILD_INFO"))
        XCTAssertEqual(version(in: dir).output, "2.3.4 20304 abc1234\n")
        for (text, expected) in [("abc1234-dirty", "abc1234-dirty"), ("ABC1234", "unknown"), ("abc</string>", "unknown"), ("abc12", "unknown")] {
            try Data((text + "\n").utf8).write(to: dir.appendingPathComponent("BUILD_INFO"))
            XCTAssertEqual(version(in: dir).output, "2.3.4 20304 \(expected)\n", "BUILD_INFO は 7〜40 文字の小文字の 16 進（任意で -dirty）だけ: \(text)")
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("BUILD_INFO"))
        XCTAssertEqual(version(in: dir).output, "2.3.4 20304 unknown\n", "git も BUILD_INFO も無ければ unknown")
        // 形の違う VERSION は断る（先頭の 0・100 以上・4 つ）
        for bad in ["1.02.3", "1.100.0", "1.2.3.4", "1.2"] {
            try Data(bad.utf8).write(to: dir.appendingPathComponent("VERSION"))
            XCTAssertNotEqual(version(in: dir).status, 0, bad)
        }
        // 組み立てのスクリプトは共通の関数を使う（版の計算・CLT の不具合の時だけの再試行・アイコン・パスとアーキテクチャの確かめ。計画 2e-1）
        for script in ["build-host-app.sh", "build-sharescale.sh"] {
            let s = try String(contentsOf: root.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
            XCTAssertTrue(s.contains(". scripts/lib/sharescale-version.sh\nsharescale_version \"$PWD\" || exit 1\n"), script)
            XCTAssertTrue(s.contains(". scripts/lib/sharescale-build.sh\n"), script)
            XCTAssertTrue(s.contains("sharescale_check_paths "), "組み立てた場所のパスが実行体に無いことを確かめる: \(script)")
            XCTAssertTrue(s.contains("sharescale_check_single_arch "), "アーキテクチャが 1 つであることを確かめる: \(script)")
        }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("scripts/build-sharescale.sh"), encoding: .utf8).contains("sharescale_install_copy \"$APP\" || exit 1"),
                      "--install は守りのある関数だけを通す")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/build-sharescale-app.sh").path), "仮の名前は build-sharescale.sh に置き換えた")
    }

    /// 引数の形の誤りは組み立てる前に断る（64）。--dev と --install は一緒に使えない（組み立て・~/Applications への書き込みは起きない）
    func testBuildScriptRejectsBadArguments() {
        for args in [["--bogus"], ["--dev", "--install"], ["install"]] {
            let r = bash("exec \"$1/scripts/build-sharescale.sh\" \"$2\" ${3:+\"$3\"}", args)
            XCTAssertEqual(r.status, 64, "\(args): \(r.output)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [], [], "一時の HOME にも何も作らない")
    }

    /// 共通の関数: CLT の不具合の時だけ native でやり直す・パスとアーキテクチャの確かめ（swift は偽の関数。組み立てはしない）
    func testSharedBuildFunctions() throws {
        let lib = ". \"$1/scripts/lib/sharescale-build.sh\"; "
        // 既定が CLT の不具合の印で失敗したら 1 回だけ --build-system native でやり直す
        let retry = bash(lib + #"swift() { echo "swift $*"; if [ "$4" = --product ]; then echo "error: SessionFailedError: spec ':wrapper.xcdatamodel' already registered from x"; return 1; fi; }; sharescale_swift_build ShareScale"#)
        XCTAssertEqual(retry.status, 0, retry.output)
        XCTAssertTrue(retry.output.contains("swift build -c release --product ShareScale\n"), retry.output)
        XCTAssertTrue(retry.output.contains("swift build -c release --build-system native --product ShareScale\n"), retry.output)
        // コンパイルの誤りなどではやり直さない（2 回走らない。点検 R）
        let compile = bash(lib + #"swift() { echo "swift $*"; echo "error: cannot find 'x' in scope"; return 1; }; sharescale_swift_build ShareScale"#)
        XCTAssertNotEqual(compile.status, 0)
        XCTAssertEqual(compile.output.components(separatedBy: "swift build").count - 1, 1, compile.output)
        let once = bash(lib + #"swift() { echo "swift $*"; }; sharescale_swift_build ShareScale"#)
        XCTAssertEqual(once.output, "swift build -c release --product ShareScale\n", "既定で通ればやり直さない")
        // パスの確かめ
        let bin = dir.appendingPathComponent("bin")
        try Data("abc\u{0}/Users/somebody/src/ShareScale/Sources/x.swift\u{0}def".utf8).write(to: bin)
        XCTAssertNotEqual(bash(lib + "sharescale_check_paths \"$2\" /Users/somebody/src/ShareScale", [bin.path]).status, 0)
        XCTAssertEqual(bash(lib + "sharescale_check_paths \"$2\" /Users/other/ShareScale", [bin.path]).status, 0)
        XCTAssertNotEqual(bash(lib + "sharescale_check_paths \"$2\" /Users/other/ShareScale", [dir.appendingPathComponent("none").path]).status, 0,
                          "strings で読めなければ失敗にする（隠さない。再点検 軽微 9）")
        // アーキテクチャが 1 つであること（universal の /usr/bin/true は断り、1 つに絞ったものは通す）
        XCTAssertNotEqual(bash(lib + "sharescale_check_single_arch /usr/bin/true").status, 0)
        let thin = dir.appendingPathComponent("thin")
        XCTAssertEqual(runTool("/usr/bin/lipo", ["/usr/bin/true", "-thin", "arm64e", "-output", thin.path]), 0)
        XCTAssertEqual(bash(lib + "sharescale_check_single_arch \"$2\"", [thin.path]).status, 0)
    }

    // ---- 予備の手順（sharescale_install_copy）。一時の HOME の中だけ ----

    /// `/usr/bin/true` を実行体にした小さなアプリを作り、簡易署名する
    func makeApp(_ url: URL, identifier: String = AppIdentifiers.app, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: url.appendingPathComponent("Contents/MacOS/ShareScale").path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "ShareScale", "CFBundlePackageType": "APPL", "CFBundleVersion": "10100"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/Resources/marker.txt"))
        XCTAssertEqual(runTool("/usr/bin/codesign", ["--force", "-s", "-", "--timestamp=none", url.path]), 0)
    }
    func install(_ app: URL, home: String? = nil) -> ChildProcess.Result {
        bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_install_copy \"$2\"", [app.path], home: home)
    }
    var dest: URL { home.appendingPathComponent("Applications/ShareScale.app") }
    var state: URL { home.appendingPathComponent("Library/Application Support/ShareScale/app-state.json") }
    func marker() -> String? { try? String(contentsOf: dest.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) }
    func writeState() throws {
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
    }

    func testInstallCopyGuardsAndClearsTheRecord() throws {
        _ = environment
        let one = dir.appendingPathComponent("one/ShareScale.app"), two = dir.appendingPathComponent("two/ShareScale.app")
        try makeApp(one, marker: "one"); try makeApp(two, marker: "two")
        // 置く: ~/Applications を 700 で作り、記録を消す（消さない変異はここで捕まる）
        try writeState()
        var r = install(one)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(marker(), "one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "引き渡しの記録（app-state.json）を消す")
        var st = stat()
        XCTAssertEqual(lstat(dest.deletingLastPathComponent().path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        // 入れ直す: 一時的な名前に写して確かめてから入れ替え、旧版と一時的なものは残らない
        try writeState()
        r = install(two)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(marker(), "two")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), ["ShareScale.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        // 写したものの署名を確かめられない → 置かない（今の複製は元のまま、記録も消さない）
        try Data("broken".utf8).write(to: one.appendingPathComponent("Contents/Resources/marker.txt"))
        try writeState()
        r = install(one)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(marker(), "two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), ["ShareScale.app"], "一時的なものを片付ける")
        // 既存の複製が別のアプリ → 断る（消さない）
        try FileManager.default.removeItem(at: dest)
        try makeApp(dest, identifier: "com.example.Other", marker: "other")
        r = install(two)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(marker(), "other", "別のアプリは消さない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        // 既存の複製がリンク → 断る
        try FileManager.default.removeItem(at: dest)
        symlink(two.path, dest.path)
        XCTAssertNotEqual(install(two).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.appendingPathComponent("Contents/Info.plist").path), "リンク先を消さない")
        unlink(dest.path)
        // ~/Applications がリンク → 断る
        let apps = dest.deletingLastPathComponent()
        try FileManager.default.removeItem(at: apps)
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        symlink(elsewhere.path, apps.path)
        XCTAssertNotEqual(install(two).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "リンク先に置かない")
        // ~/Applications にほかの人が書ける（777）・書き込みを許す ACL → 置かない（Swift 側の prepareFolder と同じ条件。再点検 中 1）
        unlink(apps.path)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: false)
        chmod(apps.path, 0o777)
        XCTAssertNotEqual(install(two).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), [], "置かない")
        chmod(apps.path, 0o700)
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone allow add_file,delete_child", apps.path]), 0)
        XCTAssertNotEqual(install(two).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), [])
        XCTAssertEqual(runTool("/bin/chmod", ["-N", apps.path]), 0)
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone deny delete", apps.path]), 0)
        XCTAssertEqual(install(two).status, 0, "拒否だけの ACL なら置く")
        XCTAssertEqual(runTool("/bin/chmod", ["-N", apps.path]), 0)
        // 途中で止まった時の戻し方: 退避した旧版を元の名前に戻し、一時的なものを消す（再点検 軽微 2）
        let oldName = apps.appendingPathComponent(".ShareScale-old-1-1"), tmpName = apps.appendingPathComponent(".ShareScale-install-1-1")
        try FileManager.default.moveItem(at: dest, to: oldName)
        try FileManager.default.createDirectory(at: tmpName, withIntermediateDirectories: true)
        let rollback = bash(". \"$1/scripts/lib/sharescale-build.sh\"; SHARESCALE_OLD=\"$2\"; SHARESCALE_TMP=\"$3\"; SHARESCALE_DEST=\"$4\"; sharescale_install_rollback",
                            [oldName.path, tmpName.path, dest.path])
        XCTAssertEqual(rollback.status, 0)
        XCTAssertEqual(marker(), "two", "旧版が元の名前に戻る")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["ShareScale.app"], "一時的なものは消える")
        // HOME が空・無い → 断る
        XCTAssertNotEqual(install(two, home: "").status, 0)
        XCTAssertNotEqual(install(two, home: dir.appendingPathComponent("no-such-home").path).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("no-such-home").path))
    }

    // ---- 入れ終えた後に、組み立て用のフォルダの ShareScale.app を残さない（計画 2h）。一時の HOME の中だけ ----

    /// 標準エラーも出力に含める（理由の文を見るため）
    func removeBuilt(_ app: URL, home: String? = nil) -> ChildProcess.Result {
        bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_remove_built \"$2\" 2>&1", [app.path], home: home)
    }
    /// 終わったプロセスの pid（もう動いていない番号）
    func deadPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run(); p.waitUntilExit()
        return p.processIdentifier
    }

    func testRemoveBuiltAppAfterInstall() throws {
        _ = environment
        let fm = FileManager.default
        let build = dir.appendingPathComponent("build", isDirectory: true)
        let built = build.appendingPathComponent("ShareScale.app")
        try makeApp(built, marker: "built")
        // 入れてから消す（スクリプトと同じ順）: 複製は残り、組み立て用のフォルダには何も残らない
        var r = bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_install_copy \"$2\" || exit 1; sharescale_remove_built \"$2\"", [built.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(marker(), "built", "複製はそのまま")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: build.path), [], "ShareScale.app も一時的な名前のものも残らない")
        XCTAssertTrue(r.output.contains("ビルド用の \(built.path) は削除しました"), "消した時だけ「削除しました」: \(r.output)")
        // 無ければ何もしない（0）。「削除しました」とも出さない（点検 2h）
        r = removeBuilt(built)
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.output, "", "何もしなかった時は何も出さない")
        // 入れられなかった時（署名を確かめられない）は、消すところまで進まない（スクリプトは `sharescale_install_copy … || exit 1` の後で消す）
        try makeApp(built, marker: "second")
        try Data("broken".utf8).write(to: built.appendingPathComponent("Contents/Resources/marker.txt"))
        r = bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_install_copy \"$2\" || exit 1; sharescale_remove_built \"$2\"", [built.path])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fm.fileExists(atPath: built.path), "入れられなかった時は残す")
        XCTAssertEqual(marker(), "built")
        try fm.removeItem(at: built)
        // 名前が ShareScale.app でない・別のアプリ・リンク・フォルダでないものは消さない（1）
        let other = build.appendingPathComponent("Other.app")
        try makeApp(other, marker: "other")
        XCTAssertNotEqual(removeBuilt(other).status, 0)
        XCTAssertTrue(fm.fileExists(atPath: other.path), "名前が違うものは消さない")
        try makeApp(built, identifier: "com.example.Other", marker: "x")
        XCTAssertNotEqual(removeBuilt(built).status, 0)
        XCTAssertTrue(fm.fileExists(atPath: built.path), "別のアプリは消さない")
        try fm.removeItem(at: built)
        symlink(other.path, built.path)
        XCTAssertNotEqual(removeBuilt(built).status, 0)
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("Contents/Info.plist").path), "リンク先を消さない")
        var st = stat()
        XCTAssertEqual(lstat(built.path, &st), 0, "リンクもそのまま")
        unlink(built.path)
        try Data("x".utf8).write(to: built)
        XCTAssertNotEqual(removeBuilt(built).status, 0)
        XCTAssertTrue(fm.fileExists(atPath: built.path), "フォルダでないものは消さない")
        try fm.removeItem(at: built)
        // 入れた複製そのものを指された時は消さない（OUT に ~/Applications を指した時。0）。「削除しました」とも出さない
        r = removeBuilt(dest)
        XCTAssertEqual(r.status, 0); XCTAssertEqual(r.output, "", "何もしなかった時は何も出さない")
        XCTAssertEqual(marker(), "built", "入れた複製を消さない")
        // 末尾の / は、いくつ付けても同じ
        for slashes in ["/", "///"] {
            try makeApp(built, marker: "third")
            XCTAssertEqual(bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_remove_built \"$2\(slashes)\"", [built.path]).status, 0, slashes)
            XCTAssertFalse(fm.fileExists(atPath: built.path), slashes)
        }
        XCTAssertNotEqual(bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_remove_built \"$2///\"", [other.path]).status, 0)
        XCTAssertTrue(fm.fileExists(atPath: other.path), "末尾に / を重ねても、名前が違うものは消さない")
        // 移せない時（フォルダに書けない）は 1 を返し、元の名前のまま、中身ごと残す（先に名前を変えてから消すので、移せなければ中身に触れない。
        // じかに rm -rf すると、中身だけが消えた壊れたアプリが ShareScale.app の名前で残る）
        try makeApp(built, marker: "fourth")
        chmod(build.path, 0o555)
        r = removeBuilt(built)
        chmod(build.path, 0o755)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: build.path).sorted(), ["Other.app", "ShareScale.app"])
        XCTAssertTrue(fm.fileExists(atPath: built.appendingPathComponent("Contents/Info.plist").path), "中身が残っている")
        XCTAssertTrue(fm.fileExists(atPath: built.appendingPathComponent("Contents/MacOS/ShareScale").path))
        XCTAssertEqual(runTool("/usr/bin/codesign", ["--verify", "--strict", built.path]), 0, "壊れていない")
        XCTAssertFalse(r.output.contains("削除しました"), r.output)
        // 消しきれなかった時（rm が失敗）は 1 を返し、残った隠しフォルダの名前を出す（偽の rm）
        let failingRm = fakeTools("rm-fails", ["rm": "exit 1"])
        var env = environment
        env["PATH"] = failingRm + ":" + (env["PATH"] ?? "")
        r = ChildProcess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_remove_built \"$2\" 2>&1", "_", root.path, built.path],
                             timeout: 30, environment: env)
        XCTAssertNotEqual(r.status, 0)
        let hidden = try fm.contentsOfDirectory(atPath: build.path).filter { $0.hasPrefix(".ShareScale-built-") }
        guard hasCount(hidden, 1, r.output) else { return }
        XCTAssertTrue(r.output.contains(build.appendingPathComponent(hidden[0]).path), "残ったものの名前を出す: \(r.output)")
        XCTAssertFalse(fm.fileExists(atPath: built.path), "ShareScale.app の名前では残らない")
        try fm.removeItem(at: build.appendingPathComponent(hidden[0]))
        // スクリプトは、入れ終えた後にだけ消す（--install なしの組み立て・--dev は `exit 0` で先に終わる）
        let s = try String(contentsOf: root.appendingPathComponent("scripts/build-sharescale.sh"), encoding: .utf8)
        let plain = try XCTUnwrap(s.range(of: "if [ \"$INSTALL\" = 0 ]; then"))
        let install = try XCTUnwrap(s.range(of: "sharescale_install_copy \"$APP\" || exit 1\n"))
        let remove = try XCTUnwrap(s.range(of: "\nsharescale_remove_built \"$APP\" || echo \"注意: "))
        XCTAssertTrue(plain.upperBound <= install.lowerBound && install.upperBound <= remove.lowerBound, "--install の時だけ、置き終えた後に消す")
        XCTAssertEqual(s.components(separatedBy: "\nsharescale_remove_built ").count - 1, 1, "消すのは 1 か所だけ")
        XCTAssertFalse(s.contains("は削除しました"), "「削除しました」は、実際に消した時に関数が出す（スクリプトは出さない）")
        XCTAssertTrue(s[plain.upperBound..<install.lowerBound].contains("  exit 0\nfi\n"), "--install でなければ、消す前に終わる")
    }

    // 前の後片付けが途中で止まって残したもの（`.ShareScale-built-<pid>-<乱数>`）を、組み立ての始めに片付ける（点検 2h）
    func testCleanBuiltLeftoversRemovesOnlyDeadOnesOfTheExactShape() throws {
        _ = environment
        let fm = FileManager.default
        let build = dir.appendingPathComponent("build", isDirectory: true)
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        func folder(_ name: String, in parent: URL? = nil) throws -> URL {
            let u = (parent ?? build).appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: u.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("Contents/Info.plist"))
            return u
        }
        let dead = deadPID(), live = getpid()
        let stale = try folder(".ShareScale-built-\(dead)-123")
        let inUse = try folder(".ShareScale-built-\(live)-456")
        let odd = try ["x", "\(dead)", "\(dead)-12a", "\(dead)-1-2", "abc-1"].map { try folder(".ShareScale-built-\($0)") }
        let similar = try folder(".ShareScale-install-\(dead)-1")
        let nested = try folder(".ShareScale-built-\(dead)-9", in: try folder("deeper"))
        let target = try folder("link-target", in: dir)
        let link = build.appendingPathComponent(".ShareScale-built-\(dead)-77")
        symlink(target.path, link.path)
        let file = build.appendingPathComponent(".ShareScale-built-\(dead)-88")
        try Data("x".utf8).write(to: file)
        let r = bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_clean_built_leftovers \"$2\" 2>&1", [build.path])
        XCTAssertEqual(r.status, 0, r.output); XCTAssertEqual(r.output, "")
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "pid が動いていない残りは消す")
        XCTAssertTrue(fm.fileExists(atPath: inUse.path), "pid が動いているものは触らない")
        for u in odd + [similar, nested, target] { XCTAssertTrue(fm.fileExists(atPath: u.appendingPathComponent("Contents/Info.plist").path), "型が違う・直下でないものは触らない: \(u.lastPathComponent)") }
        var st = stat()
        XCTAssertEqual(lstat(link.path, &st), 0, "リンクは消さない（たどらない）")
        XCTAssertTrue(fm.fileExists(atPath: file.path), "フォルダでないものは触らない")
        // フォルダが無い・空でも失敗しない
        XCTAssertEqual(bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_clean_built_leftovers \"$2\"", [dir.appendingPathComponent("no-such").path]).status, 0)
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(bash(". \"$1/scripts/lib/sharescale-build.sh\"; sharescale_clean_built_leftovers \"$2\"", [empty.path]).status, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: empty.path), [])
    }

    // ---- スクリプトを始めから終わりまで動かす（計画 2h）。リポジトリの写し（スクリプト・VERSION・アイコン）を一時フォルダに作り、
    //      `swift build` の代わりに /usr/bin/true を実行体として置く偽の swift を使う（組み立てない。一時の HOME の中だけ） ----

    /// 一時フォルダのリポジトリの写し（`scripts/build-sharescale.sh`・`scripts/build-host-app.sh`・`scripts/lib/`・`VERSION`・アイコン）
    func makeRepoCopy() throws -> URL {
        let fm = FileManager.default
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for f in ["scripts/build-sharescale.sh", "scripts/build-host-app.sh", "scripts/lib", "assets/icon", "VERSION"] {
            try fm.copyItem(at: root.appendingPathComponent(f), to: repo.appendingPathComponent(f))
        }
        return repo
    }
    /// 偽の swift（`swift build … --product <名前>` で `.build/release/<名前>` に、アーキテクチャを 1 つに絞った /usr/bin/true を置く）を先頭に置いた PATH と一時の HOME
    func workingSwiftEnvironment() -> [String: String] {
        var env = environment
        let bin = fakeTools("swift-ok", ["swift": """
            product=""
            while [ $# -gt 0 ]; do if [ "$1" = --product ]; then product=$2; fi; shift; done
            [ -n "$product" ] || exit 96
            /bin/mkdir -p .build/release || exit 1
            /usr/bin/lipo /usr/bin/true -thin arm64e -output ".build/release/$product" || exit 1
            echo "fake swift built $product"
            """])
        env["PATH"] = bin + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
    func runBuild(_ repo: URL, _ args: [String]) -> ChildProcess.Result {
        ChildProcess.run(repo.appendingPathComponent("scripts/build-sharescale.sh"), args, timeout: 120, environment: workingSwiftEnvironment())
    }
    func plist(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func testBuildScriptEndToEndKeepsOrRemovesTheBuiltApp() throws {
        let fm = FileManager.default
        let repo = try makeRepoCopy()
        let built = repo.appendingPathComponent("build/ShareScale.app")
        let hostInside = built.appendingPathComponent("Contents/Library/LoginItems/ShareScale Host.app")
        // --install なし（Homebrew の formula が使う形）: build/ShareScale.app を残す。HOME には何も置かない
        var r = runBuild(repo, [])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(fm.fileExists(atPath: built.appendingPathComponent("Contents/MacOS/ShareScale").path), r.output)
        XCTAssertTrue(fm.fileExists(atPath: hostInside.appendingPathComponent("Contents/MacOS/ShareScaleHost").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.path), "--install なしでは ~/Applications に置かない")
        XCTAssertEqual(try plist(built.appendingPathComponent("Contents/Info.plist"))["CFBundleIdentifier"] as? String, AppIdentifiers.app)
        XCTAssertNil(try plist(built.appendingPathComponent("Contents/Info.plist"))[AppIdentifiers.developmentBuildKey])
        // 言語の宣言（計画 2h）: ShareScale.app と中の ShareScale Host.app の両方に、日本語と英語（開発の言語は英語）。
        // 宣言が無いと、日本語の環境でも標準のメニューが英語で出る
        for (name, bundle) in [("ShareScale.app", built), ("ShareScale Host.app", hostInside)] {
            let info = try plist(bundle.appendingPathComponent("Contents/Info.plist"))
            XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en", name)
            XCTAssertEqual(info["CFBundleLocalizations"] as? [String], ["en", "ja"], name)
            let b = try XCTUnwrap(Bundle(url: bundle), name)
            XCTAssertEqual(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["ja-JP", "en-JP"]), ["ja"], "日本語の環境では日本語: \(name)")
            XCTAssertEqual(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["en-US"]), ["en"], "英語の環境では英語: \(name)")
            XCTAssertEqual(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["fr-FR"]).first.map { $0 == "ja" }, false,
                           "日本語でも英語でもない環境では日本語にしない: \(name)")
            XCTAssertEqual(b.developmentLocalization, "en", name)
        }
        XCTAssertEqual(try plist(hostInside.appendingPathComponent("Contents/Info.plist"))["CFBundleIdentifier"] as? String, AppIdentifiers.host)
        XCTAssertEqual(try plist(hostInside.appendingPathComponent("Contents/Info.plist"))["LSUIElement"] as? Bool, true, "ほかの項目はそのまま")
        // アプリ自身の文言の言語（`HostLanguage.detect`。`AppLanguage` も同じ関数）は、組み立てたバンドルの宣言から macOS が選ぶ言語と同じ（計画 2h の点検）
        for (name, bundle) in [("ShareScale.app", built), ("ShareScale Host.app", hostInside)] {
            let b = try XCTUnwrap(Bundle(url: bundle), name)
            for list in [["ja-JP", "en-JP"], ["en-US"], ["fr-FR", "ja-JP"], ["fr-FR", "ja-JP", "en-US"], ["fr-FR", "en-GB", "ja-JP"], ["fr-FR"], ["zh-Hans", "ko"], []] {
                XCTAssertEqual(Bundle.preferredLocalizations(from: b.localizations, forPreferences: list).first, HostLanguage.detect(list) == .ja ? "ja" : "en", "\(name) \(list)")
            }
        }
        XCTAssertEqual(HostLanguage.detect(["fr-FR", "ja-JP"]), .ja, "日英以外 → 日本語 の並びは、標準のメニューと同じく日本語")
        // --dev: build/ から動く形で残す（印が入る）。~/Applications には置かない
        r = runBuild(repo, ["--dev"])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(try plist(built.appendingPathComponent("Contents/Info.plist"))[AppIdentifiers.developmentBuildKey] as? Bool, true)
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        // --install: ~/Applications/ShareScale.app（一時の HOME）に置き、build/ShareScale.app を残さない。
        // 前の後片付けの残り（pid が動いていないもの）も、組み立ての始めに片付ける（点検 2h）
        let stale = repo.appendingPathComponent("build/.ShareScale-built-\(deadPID())-1/Contents", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try writeState()
        r = runBuild(repo, ["--install"])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Contents/MacOS/ShareScale").path), r.output)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Contents/Library/LoginItems/ShareScale Host.app/Contents/MacOS/ShareScaleHost").path))
        XCTAssertNil(try plist(dest.appendingPathComponent("Contents/Info.plist"))[AppIdentifiers.developmentBuildKey], "入れるのは配布用の形")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: repo.appendingPathComponent("build").path), [], "build/ShareScale.app も一時的な名前のものも残らない: \(r.output)")
        XCTAssertFalse(fm.fileExists(atPath: state.path), "引き渡しの記録を消す（今までどおり）")
        XCTAssertEqual(leftovers(), [], "~/Applications に一時的なものを残さない")
        XCTAssertEqual(runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", dest.path]), 0, "入れた複製の署名は壊れていない")
        XCTAssertTrue(r.output.contains("ビルド用の build/ShareScale.app は削除しました"), r.output)
        // 入れられなかった時（~/Applications にほかの人が書ける）は、build/ShareScale.app を残して失敗で終わる（巻き戻しは今までどおり）
        chmod(dest.deletingLastPathComponent().path, 0o777)
        r = runBuild(repo, ["--install"])
        chmod(dest.deletingLastPathComponent().path, 0o700)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fm.fileExists(atPath: built.path), "入れられなかった時は build/ShareScale.app を残す")
        XCTAssertEqual(leftovers(), [])
    }

    // ---- 予備の手順の競り合い・中断・持ち主（最終の点検 軽微 1〜4）。偽の mv・rm・stat を PATH の先頭に置く ----

    /// 偽の道具を置いたフォルダ（PATH の先頭に足す）
    func fakeTools(_ name: String, _ tools: [String: String]) -> String {
        let bin = dir.appendingPathComponent("fake-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (tool, body) in tools {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(tool).path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return bin.path
    }
    /// `lib` のライブラリで sharescale_install_copy を動かす（PATH の先頭に `prefix`）。
    /// 新しいプロセスグループで、INT・TERM・HUP を既定の扱いに戻してから bash を動かす（偽の道具はそのグループにだけ送る。試験の本体に届かない）
    func install(_ app: URL, prefix: String, lib: URL? = nil) -> ChildProcess.Result {
        var env = environment
        env["PATH"] = prefix + ":" + (env["PATH"] ?? "")
        let libPath = lib?.path ?? root.appendingPathComponent("scripts/lib/sharescale-build.sh").path
        return ChildProcess.run(URL(fileURLWithPath: "/usr/bin/perl"),
                                ["-e", "setpgrp(0, 0); $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP); exec @ARGV",
                                 "/bin/bash", "-c", ". \"$1\"; sharescale_install_copy \"$2\"", "_", libPath, app.path],
                                timeout: 60, environment: env)
    }
    /// 自分のプロセスグループ（先頭が親の bash の時だけ）にシグナルを送る偽の道具の一節
    func signalGroup(_ signal: String) -> String {
        """
        pg=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')
        if [ "$pg" = "$PPID" ]; then kill -\(signal) -"$pg"; else echo "not isolated" >&2; exit 1; fi
        """
    }
    /// ~/Applications の中の一時的なもの
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(".ShareScale-") }.sorted()
    }

    func testInstallCopyRaceInterruptionAndOwner() throws {
        _ = environment
        let one = dir.appendingPathComponent("one/ShareScale.app"), two = dir.appendingPathComponent("two/ShareScale.app")
        try makeApp(one, marker: "one"); try makeApp(two, marker: "two")
        XCTAssertEqual(install(one).status, 0)
        // rename(2): 行き先に空でないフォルダがあれば失敗し、中へ入れない（BSD の mv は中へ入れる。軽微 1）
        let a = dir.appendingPathComponent("ra"), b = dir.appendingPathComponent("rb")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("inside"), withIntermediateDirectories: true)
        let lib = ". \"$1/scripts/lib/sharescale-build.sh\"; "
        XCTAssertNotEqual(bash(lib + "sharescale_rename \"$2\" \"$3\"", [a.path, b.path]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("ra").path), "中へ入れない")
        XCTAssertEqual(bash(lib + "sharescale_rename \"$2\" \"$3\"", [a.path, dir.appendingPathComponent("rc").path]).status, 0)

        // (a) 旧版を退避した後に元の名前が現れた → 上書きせずにやめる（旧版は退避のまま残り、一時的なものは片付ける）
        try writeState()
        let appear = fakeTools("appear", ["mv": """
            /bin/mv "$@" || exit 1
            case "$2" in *.ShareScale-old-*) /bin/mkdir -p "$(dirname "$2")/ShareScale.app" ;; esac
            """])
        XCTAssertNotEqual(install(two, prefix: appear).status, 0)
        XCTAssertNil(marker(), "現れたもの（空のフォルダ）を上書きしない")
        XCTAssertEqual(leftovers().filter { $0.hasPrefix(".ShareScale-install-") }, [], "一時的なものは片付ける")
        XCTAssertEqual(leftovers().filter { $0.hasPrefix(".ShareScale-old-") }.count, 1, "旧版は残す（消さない）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "記録は消さない")
        // 片付けて、もう一度 one を置く
        for n in leftovers() { try FileManager.default.removeItem(at: dest.deletingLastPathComponent().appendingPathComponent(n)) }
        try FileManager.default.removeItem(at: dest)
        XCTAssertEqual(install(one).status, 0)

        // (c) 旧版を退避した直後に INT → trap が旧版を元の名前に戻し、一時的なものを消して 130 で終わる（記録は消さない）
        try writeState()
        let interrupt = { (signal: String) in
            self.fakeTools("interrupt-\(signal)", ["mv": """
                /bin/mv "$@" || exit 1
                case "$2" in *.ShareScale-old-*) \(self.signalGroup(signal)) ;; esac
                """])
        }
        var r = install(two, prefix: interrupt("INT"))
        XCTAssertEqual(r.status, 130, "INT は 130")
        XCTAssertEqual(marker(), "one", "旧版が元の名前に戻る")
        XCTAssertEqual(leftovers(), [], "一時的なものは消える")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        r = install(two, prefix: interrupt("HUP"))
        XCTAssertEqual(r.status, 129, "HUP は 129"); XCTAssertEqual(marker(), "one")
        // trap を外した写しでは、同じ中断で旧版が戻らない（試験が trap を見ていることの確かめ）
        let mutated = dir.appendingPathComponent("no-trap.sh")
        let original = try String(contentsOf: root.appendingPathComponent("scripts/lib/sharescale-build.sh"), encoding: .utf8)
        let stripped = original.components(separatedBy: "\n").filter { !$0.contains("trap 'sharescale_install_interrupted") }.joined(separator: "\n")
        XCTAssertNotEqual(stripped, original)
        try Data(stripped.utf8).write(to: mutated)
        _ = install(two, prefix: interrupt("INT"), lib: mutated)
        XCTAssertNil(marker(), "trap が無ければ、中断で ShareScale.app が無くなる")
        for n in leftovers() where n.hasPrefix(".ShareScale-old-") {
            try FileManager.default.moveItem(at: dest.deletingLastPathComponent().appendingPathComponent(n), to: dest)
        }
        for n in leftovers() { try FileManager.default.removeItem(at: dest.deletingLastPathComponent().appendingPathComponent(n)) }
        XCTAssertEqual(marker(), "one")

        // (4) 置き終えた後（旧版を消す時）に TERM → 完了の処理（旧版と記録を消す）をして 143 で終わる
        try writeState()
        let flag = dir.appendingPathComponent("rm-once").path
        let late = fakeTools("late", ["rm": """
            if [ ! -e "\(flag)" ]; then /usr/bin/touch "\(flag)"; \(signalGroup("TERM")); fi
            exec /bin/rm "$@"
            """])
        r = install(two, prefix: late)
        XCTAssertEqual(r.status, 143, "TERM は 143")
        XCTAssertEqual(marker(), "two", "新版は置いたまま")
        XCTAssertEqual(leftovers(), [], "旧版を消す")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "完了の処理で記録も消す")

        // (b) HOME の持ち主が自分でなければ置かない（偽の stat）
        try writeState()
        let otherOwner = fakeTools("owner", ["stat": """
            if [ "$1" = -f ] && [ "$2" = %u ] && [ "$3" = "$HOME" ]; then echo 0; exit 0; fi
            exec /usr/bin/stat "$@"
            """])
        XCTAssertNotEqual(install(one, prefix: otherOwner).status, 0)
        XCTAssertEqual(marker(), "two", "置かない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        // ACL を読み取れなければ置かない（偽の ls。軽微 2）
        let noACL = fakeTools("ls", ["ls": "exit 1"])
        XCTAssertNotEqual(install(one, prefix: noACL).status, 0)
        XCTAssertEqual(marker(), "two")
    }
}
