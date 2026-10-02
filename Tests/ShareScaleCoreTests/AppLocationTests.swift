import Darwin
import XCTest
@testable import ShareScaleCore

/// 置き場所の判定と引き渡しの条件（仕様「`~/Applications` への複製と引き渡し」「引き渡しの条件」）
final class AppLocationTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    func testClassifiesHomebrewCopyDevelopmentAndElsewhere() {
        let home = "/Users/taro"
        func role(_ p: String, dev: Bool = false) -> AppRole { AppLocation.classify(bundlePath: p, home: home, isDevelopmentBuild: dev) }
        guard case let .homebrew(h) = role("/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app") else { return XCTFail("Homebrew 側") }
        XCTAssertEqual(h.prefix, "/opt/homebrew"); XCTAssertEqual(h.optPath, "/opt/homebrew/opt/sharescale/ShareScale.app", "複製元は版に依らない場所")
        guard case let .homebrew(i) = role("/usr/local/Cellar/sharescale/1.2.0_1/ShareScale.app/", dev: true) else { return XCTFail("Intel の prefix") }
        XCTAssertEqual(i.optPath, "/usr/local/opt/sharescale/ShareScale.app")
        XCTAssertEqual(role("/Users/taro/Applications/ShareScale.app"), .copy)
        XCTAssertEqual(role("/Users/taro/Applications/ShareScale.app", dev: true), .copy, "複製は開発の印より先")
        XCTAssertEqual(role("/Users/taro/src/ShareScale/build/ShareScale.app", dev: true), .development)
        for other in ["/Users/taro/src/ShareScale/build/ShareScale.app",          // 組み立てたまま
                      "/opt/homebrew/opt/sharescale/ShareScale.app",             // 実体のパスでない（リンクを解決していない）
                      "/opt/homebrew/Cellar/sharescale/ShareScale.app",          // 版のフォルダが無い
                      "/opt/homebrew/Cellar/sharescale/1.2.0/x/ShareScale.app",  // 深すぎる
                      "/opt/homebrew/Cellar/sharescale/../ShareScale.app",
                      "/opt/homebrew/Cellar/other/1.0/ShareScale.app",
                      "/Users/x/homebrew/Cellar/sharescale/1.2.0/ShareScale.app", // 認めない prefix
                      "/Applications/ShareScale.app",
                      "/Users/taro/Applications/Other/ShareScale.app",
                      "/Users/jiro/Applications/ShareScale.app"] {
            XCTAssertEqual(role(other), .elsewhere, other)
        }
        XCTAssertTrue(AppRole.copy.runsViewer); XCTAssertTrue(AppRole.development.runsViewer); XCTAssertFalse(AppRole.elsewhere.runsViewer)
        XCTAssertTrue(AppRole.copy.canUninstall); XCTAssertFalse(AppRole.development.canUninstall, "取り除きは複製だけ")
        XCTAssertTrue(AppRole.development.canRegisterLoginItem, "開発の組み立ては注意を添えて登録できる")
        XCTAssertFalse(AppRole.homebrew(h).canRegisterLoginItem)
        XCTAssertTrue(AppLocation.isDevelopmentBuild(["ShareScaleDevelopmentBuild": true]))
        XCTAssertFalse(AppLocation.isDevelopmentBuild(["ShareScaleDevelopmentBuild": "true"]), "真偽値の時だけ")
        XCTAssertFalse(AppLocation.isDevelopmentBuild(nil))
        XCTAssertTrue(AppLocation.elsewhereGuidance(copy: CopySnapshot(facts: nil, realPath: nil), home: home, ownVersion: nil).detail.contains("open \"$(brew --prefix)/opt/sharescale/ShareScale.app\""),
                      "複製がまだ無ければ Homebrew から入れたアプリを案内する（仕様「実装計画で扱う事項」）")
        let paths = AppPaths(home: URL(fileURLWithPath: home))
        XCTAssertEqual(paths.appState.path, "/Users/taro/Library/Application Support/ShareScale/app-state.json")
        XCTAssertEqual(paths.preferenceFiles.map(\.lastPathComponent), ["io.github.taki-0105a.ShareScale.plist", "io.github.taki-0105a.ShareScale.Host.plist"])
        XCTAssertEqual(paths.savedState.lastPathComponent, "io.github.taki-0105a.ShareScale.savedState")
    }

    /// 偽のファイルの情報（パス → 情報、フォルダ → 名前）
    struct FakeFacts: FileFactsReader {
        var facts: [String: FileFacts]
        var children: [String: [String]]
        func facts(_ path: String) -> FileFacts? { facts[path] }
        func children(_ path: String) -> [String]? { children[path] }
    }

    // 「ヘルプ」のメニューから開くのは、公開のリポジトリだけ（計画 2h）
    func testHelpLinkIsThePublicRepositoryOnly() {
        XCTAssertEqual(AppLinks.repository.absoluteString, "https://github.com/taki-0105a/ShareScale")
        XCTAssertEqual(AppLinks.repository.scheme, "https"); XCTAssertEqual(AppLinks.repository.host, "github.com")
        XCTAssertNil(AppLinks.repository.query, "URL に値を載せない")
        let before = AppLanguage.current
        defer { AppLanguage.current = before }
        AppLanguage.current = .ja
        XCTAssertEqual(AppLinks.helpTitle, "ShareScale の説明を GitHub で開く")
        AppLanguage.current = .en
        XCTAssertEqual(AppLinks.helpTitle, "Open ShareScale on GitHub")
    }

    // それ以外の場所から開かれた時の案内（計画 2h）: 複製を開ける時だけ、既定のボタン「~/Applications の ShareScale を開く」を付ける
    func testElsewhereGuidanceOffersToOpenTheCopyOnlyWhenItIsOurs() {
        let before = AppLanguage.current
        AppLanguage.current = .ja
        defer { AppLanguage.current = before }
        let home = "/Users/taro", path = "/Users/taro/Applications/ShareScale.app"
        func copy(symlink: Bool = false, mine: Bool = true, id: String? = AppIdentifiers.app, version: Int? = 10100, cdhash: String? = "ab12",
                  real: String? = "/Users/taro/Applications/ShareScale.app") -> CopySnapshot {
            CopySnapshot(facts: CopyFacts(isSymlink: symlink, ownerIsMe: mine, bundle: BundleFacts(identifier: id, version: version, cdhash: cdhash)), realPath: real)
        }
        func guidance(_ c: CopySnapshot, own: Int? = 10100) -> ElsewhereGuidance { AppLocation.elsewhereGuidance(copy: c, home: home, ownVersion: own) }
        // 複製が ShareScale: ボタンを付ける。見出し・本文・ボタンで同じ文を重ねない
        let ok = guidance(copy())
        XCTAssertEqual(ok, ElsewhereGuidance(title: "この場所の ShareScale は開けません", detail: "~/Applications にインストールされている ShareScale を開いてください。",
                                             openCopyTitle: "~/Applications の ShareScale を開く"))
        XCTAssertTrue(AppLocation.canOpenCopy(copy(), home: home))
        AppLanguage.current = .en
        let en = guidance(copy())
        XCTAssertEqual(en, ElsewhereGuidance(title: "This copy of ShareScale can’t be opened from here", detail: "Open the ShareScale installed in ~/Applications instead.",
                                             openCopyTitle: "Open ShareScale in ~/Applications"))
        XCTAssertNotEqual(en.title, en.openCopyTitle, "見出しとボタンが同じ文にならない")
        // 自分の版の方が新しい時だけ、入れ直し方を 1 文添える（同じ・古い・読めない時は添えない。点検 2h）
        XCTAssertEqual(guidance(copy(), own: 10200).detail,
                       "Open the ShareScale installed in ~/Applications instead. This copy is newer than the one in ~/Applications. To install it, run scripts/build-sharescale.sh --install in the source folder.")
        AppLanguage.current = .ja
        XCTAssertEqual(guidance(copy(), own: 10200).detail,
                       "~/Applications にインストールされている ShareScale を開いてください。この場所の ShareScale の方が新しいバージョンです。インストールするには、ソースのフォルダで scripts/build-sharescale.sh --install を実行してください。")
        XCTAssertNotNil(guidance(copy(), own: 10200).openCopyTitle, "新しくても、複製を開くボタンは付ける")
        for own in [10100, 10000, nil] as [Int?] { XCTAssertEqual(guidance(copy(), own: own).detail, ok.detail, "\(String(describing: own))") }
        // 複製が無い: 今までどおりの案内だけ（Homebrew から入れたアプリか、予備の手順）
        let missing = CopySnapshot(facts: nil, realPath: nil)
        let none = guidance(missing)
        XCTAssertNil(none.openCopyTitle); XCTAssertFalse(AppLocation.canOpenCopy(missing, home: home))
        XCTAssertEqual(none.title, "Homebrew でインストールした ShareScale を開いてください")
        XCTAssertTrue(none.detail.contains("scripts/build-sharescale.sh --install"))
        // 複製はあるが、アプリからは開かないもの（リンク・ほかの利用者のもの・別のアプリ・版や署名を読めない）: 今までどおりの案内だけ
        let odd: [(String, CopySnapshot)] = [("リンク", copy(symlink: true)), ("ほかの利用者のもの", copy(mine: false)), ("別のアプリ", copy(id: "com.example.Other")),
                                             ("識別子を読めない", copy(id: nil)), ("版を読めない", copy(version: nil)), ("署名が無い", copy(cdhash: nil)),
                                             // ~/Applications そのものがリンク: 開いた先は実体のパスで役を決めるので、同じ案内がまた出る（堂々めぐり。点検 2h）
                                             ("~/Applications がリンク", copy(real: "/Volumes/Other/Apps/ShareScale.app")),
                                             ("実体のパスを読めない", copy(real: nil))]
        for (name, c) in odd {
            XCTAssertFalse(AppLocation.canOpenCopy(c, home: home), name)
            let g = guidance(c, own: 10200)
            XCTAssertNil(g.openCopyTitle, name)
            XCTAssertEqual(g.title, "~/Applications の ShareScale を開いてください", name)
            XCTAssertEqual(g.detail, "このアプリはこの場所からは開けません。~/Applications/ShareScale.app を開いてください。", name)
        }
        XCTAssertEqual(AppLocation.classify(bundlePath: path, home: home, isDevelopmentBuild: false), .copy, "ボタンで開く先は、複製の役になる")
        XCTAssertEqual(AppLocation.classify(bundlePath: "/Volumes/Other/Apps/ShareScale.app", home: home, isDevelopmentBuild: false), .elsewhere)
        // Homebrew 側が複製を開く時の判定（`Handoff.plan`）が断る複製は、ここでも開かない
        let own = BundleFacts(identifier: AppIdentifiers.app, version: 10100, cdhash: "ab12")
        for (name, c) in odd.prefix(5) {
            if case .abort = Handoff.plan(copy: c.facts, own: own) {} else { XCTFail("Handoff.plan は断る: \(name)") }
        }
        XCTAssertEqual(Handoff.plan(copy: copy().facts, own: own), .openCopy)
    }

    // 案内のウインドウのボタンの並びと、押された番号の読み方（点検 2h）
    func testLaunchAlertLayoutMapsButtonsInOrder() {
        // 既定のボタンがある: 既定（Return）→「終了」（Esc）
        let withPrimary = LaunchAlertLayout(hasPrimary: true, hasCopyable: false)
        XCTAssertEqual(withPrimary.buttons, [.primary, .quit]); XCTAssertTrue(withPrimary.quitTakesEscape)
        XCTAssertEqual(withPrimary.pressed(0), .primary); XCTAssertEqual(withPrimary.pressed(1), .quit, "「終了」は既定のボタンと読まない")
        // 今までの形: 「終了」が既定のボタン。「詳細をコピー」が 2 つ目
        let plain = LaunchAlertLayout(hasPrimary: false, hasCopyable: false)
        XCTAssertEqual(plain.buttons, [.quit]); XCTAssertFalse(plain.quitTakesEscape); XCTAssertEqual(plain.pressed(0), .quit)
        let copyable = LaunchAlertLayout(hasPrimary: false, hasCopyable: true)
        XCTAssertEqual(copyable.buttons, [.quit, .copy]); XCTAssertEqual(copyable.pressed(0), .quit); XCTAssertEqual(copyable.pressed(1), .copy)
        let all = LaunchAlertLayout(hasPrimary: true, hasCopyable: true)
        XCTAssertEqual(all.buttons, [.primary, .quit, .copy]); XCTAssertEqual(all.pressed(2), .copy)
        // 範囲の外（ウインドウが別の形で閉じた）は「終了」
        for layout in [withPrimary, plain, copyable, all] {
            for odd in [-1001, -1, 3, 99] { XCTAssertEqual(layout.pressed(odd), .quit, "\(layout.buttons) \(odd)") }
        }
    }

    // 案内のウインドウを閉じた後に行うこと（点検 2h）: 既定のボタンの時だけ、押した時の複製を確かめ直してから開く
    func testElsewhereActionRechecksTheCopyOnlyWhenThePrimaryButtonWasPressed() {
        let home = "/Users/taro"
        let good = CopySnapshot(facts: CopyFacts(isSymlink: false, ownerIsMe: true, bundle: BundleFacts(identifier: AppIdentifiers.app, version: 10100, cdhash: "ab12")),
                                realPath: "/Users/taro/Applications/ShareScale.app")
        let swapped = CopySnapshot(facts: CopyFacts(isSymlink: false, ownerIsMe: true, bundle: BundleFacts(identifier: "com.example.Other", version: 1, cdhash: "cd34")),
                                   realPath: "/Users/taro/Applications/ShareScale.app")
        var rechecks = 0, runningChecks = 0
        func action(_ pressed: LaunchAlertButton, now: CopySnapshot, running: Bool) -> ElsewhereAction {
            AppLocation.elsewhereAction(pressed: pressed, home: home, recheck: { rechecks += 1; return now }, copyRunning: { runningChecks += 1; return running })
        }
        // 「終了」・「詳細をコピー」では、複製が開けるものでも何も開かない（複製も読まない）
        for pressed in [LaunchAlertButton.quit, .copy] {
            XCTAssertEqual(action(pressed, now: good, running: true), .quit, "\(pressed)")
            XCTAssertEqual(action(pressed, now: good, running: false), .quit, "\(pressed)")
        }
        XCTAssertEqual(rechecks, 0); XCTAssertEqual(runningChecks, 0)
        // 既定のボタン: 押した時に確かめ直す。動いていれば開き直しを頼み、動いていなければ新しく開く
        XCTAssertEqual(action(.primary, now: good, running: true), .reopenRunningCopy, "メニューバーにだけ居る時も、主の窓が出るように")
        XCTAssertEqual(action(.primary, now: good, running: false), .launchCopy)
        XCTAssertEqual(rechecks, 2)
        // ウインドウを出している間に入れ替わっていた・消えていた → 開かない（動いているかも見ない）
        runningChecks = 0
        XCTAssertEqual(action(.primary, now: swapped, running: true), .cannotOpen)
        XCTAssertEqual(action(.primary, now: CopySnapshot(facts: nil, realPath: nil), running: true), .cannotOpen)
        XCTAssertEqual(action(.primary, now: CopySnapshot(facts: good.facts, realPath: "/Volumes/Other/Apps/ShareScale.app"), running: false), .cannotOpen)
        XCTAssertEqual(runningChecks, 0)
        // 開く処理の組み立て（`LaunchFlow`）は、この判断と並びだけを使う
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = (try? String(contentsOf: root.appendingPathComponent("Sources/ShareScale/Launch.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(source.contains("AppLocation.elsewhereAction(pressed: pressed, home: home, recheck: { CopySnapshot.read(copy) },"), "押した後に、ディスクを読み直す")
        XCTAssertTrue(source.contains("let pressed = layout.pressed(a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)"))
        XCTAssertFalse(source.contains("activateIfRunning"), "前に出すだけの開き方に戻さない")
    }

    // 複製の開き方（再点検 2h）: 動いていれば「前に出す＋新しい実体を作らずに開く」、動いていなければ「新しい実体として開く」
    func testCopyOpeningStepsReopenARunningCopyWithoutANewInstance() throws {
        XCTAssertEqual(AppLocation.reopenRunningCopySteps, [.activateRunning, .open(newInstance: false)],
                       "開き直しは、新しい実体を作らない（2 つ目の ShareScale を起動しない）。前に出すだけでは、メニューバーにだけ居る複製の主の窓が出ない")
        XCTAssertEqual(AppLocation.launchCopySteps, [.open(newInstance: true)], "動いていない複製は、新しい実体として開く")
        // 案内のボタンの後: 開き直しを頼めなければ、新しく開く手順に落とす。「終了」・開けない時は、何も開かない
        XCTAssertEqual(AppLocation.openAttempts(for: .reopenRunningCopy), [[.activateRunning, .open(newInstance: false)], [.open(newInstance: true)]])
        XCTAssertEqual(AppLocation.openAttempts(for: .launchCopy), [[.open(newInstance: true)]])
        XCTAssertEqual(AppLocation.openAttempts(for: .quit), []); XCTAssertEqual(AppLocation.openAttempts(for: .cannotOpen), [])
        // 手順を行う側（`Launch.swift`）は、この並びをそのまま行う（開く手の「新しい実体を作るか」を、そのまま渡す）
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ShareScale/Launch.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("            case .activateRunning: find(copy).forEach { _ = $0.activate() }\n"))
        XCTAssertTrue(source.contains("            case let .open(newInstance): if !LaunchFlow.open(copy, newInstance: newInstance) { opened = false }\n"))
        XCTAssertTrue(source.contains("        config.createsNewApplicationInstance = newInstance\n"), "「新しい実体を作るか」が、開く時の設定に届く")
        XCTAssertTrue(source.contains("    static func open(_ app: URL, newInstance: Bool = true) -> Bool {\n"))
        // それ以外の場所の案内の後: 並びを順に試し、開けたら終わる。どれも開けなければ「開けませんでした」の案内へ
        XCTAssertTrue(source.contains("            for steps in AppLocation.openAttempts(for: action) where RunningCopies.run(steps, copy) { exit(0) }\n            fallthrough\n        case .cannotOpen:\n"))
        // Homebrew 側が、置き換えなかった複製を開く時も、動いていれば同じ開き直し（見つかれば、できたかに依らず終了＝2 つ目の実体を開かない）
        XCTAssertTrue(source.contains("        if plan == .openCopy, !RunningCopies.find(paths.copy).isEmpty {\n            _ = RunningCopies.run(AppLocation.reopenRunningCopySteps, paths.copy)\n            exit(0)\n        }\n"))
    }

    func testHandoffSafetyRules() {
        let me: uid_t = 501
        func dir(_ uid: uid_t = 501, gid: gid_t = 20, mode: mode_t = 0o755, acl: Bool = false) -> FileFacts { FileFacts(kind: .directory, uid: uid, gid: gid, mode: mode, hasACL: acl) }
        func file(_ uid: uid_t = 501, mode: mode_t = 0o644, acl: Bool = false) -> FileFacts { FileFacts(kind: .regular, uid: uid, gid: 20, mode: mode, hasACL: acl) }
        let bundle = "/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app"
        let good: [String: FileFacts] = [
            "/": dir(0), "/opt": dir(0), "/opt/homebrew": dir(gid: 80), "/opt/homebrew/Cellar": dir(gid: 80, mode: 0o775),
            "/opt/homebrew/Cellar/sharescale": dir(gid: 80, mode: 0o775), "/opt/homebrew/Cellar/sharescale/1.2.0": dir(gid: 80),
            bundle: dir(gid: 80), bundle + "/Contents": dir(gid: 80), bundle + "/Contents/Info.plist": file(),
            bundle + "/Contents/MacOS": dir(), bundle + "/Contents/MacOS/ShareScale": file(mode: 0o755),
        ]
        let kids = [bundle: ["Contents"], bundle + "/Contents": ["Info.plist", "MacOS"], bundle + "/Contents/MacOS": ["ShareScale"]]
        func check(_ change: (inout [String: FileFacts]) -> Void) -> HandoffSafety.Problem? {
            var f = good; change(&f)
            return HandoffSafety.check(bundle: bundle, uid: me, reader: FakeFacts(facts: f, children: kids))
        }
        XCTAssertNil(check { _ in }, "Homebrew の標準の権限（Cellar は admin が書ける）は満たす")
        XCTAssertEqual(check { $0[bundle + "/Contents/Info.plist"] = file(502) }, .wrongOwner(bundle + "/Contents/Info.plist"), "中の項目は本人のもの")
        XCTAssertEqual(check { $0[bundle + "/Contents/MacOS/ShareScale"] = file(mode: 0o775) }, .writableByOthers(bundle + "/Contents/MacOS/ShareScale"),
                       "中の項目はグループも書けない（gid 80 でも）")
        XCTAssertEqual(check { $0[bundle + "/Contents/Info.plist"] = file(mode: 0o646) }, .writableByOthers(bundle + "/Contents/Info.plist"))
        XCTAssertEqual(check { $0[bundle + "/Contents"] = dir(gid: 80, acl: true) }, .aclPresent(bundle + "/Contents"))
        XCTAssertEqual(check { $0[bundle + "/Contents/MacOS/ShareScale"] = FileFacts(kind: .symlink, uid: 501, gid: 20, mode: 0o755, hasACL: false) },
                       .symlinkInside(bundle + "/Contents/MacOS/ShareScale"))
        XCTAssertEqual(check { $0.removeValue(forKey: bundle + "/Contents/Info.plist") }, .unreadable(bundle + "/Contents/Info.plist"))
        XCTAssertEqual(check { $0["/opt/homebrew/Cellar"] = dir(502, gid: 80, mode: 0o775) }, .wrongOwner("/opt/homebrew/Cellar"), "上位は本人か root")
        XCTAssertEqual(check { $0["/opt/homebrew/Cellar"] = dir(gid: 20, mode: 0o775) }, .writableByOthers("/opt/homebrew/Cellar"),
                       "グループの書き込みは gid 80 の時だけ（名前ではなく番号）")
        XCTAssertEqual(check { $0["/opt"] = dir(0, mode: 0o777) }, .writableByOthers("/opt"), "他人が書ける上位")
        XCTAssertEqual(check { $0["/opt"] = dir(0, mode: 0o1777) }, .writableByOthers("/opt"), "スティッキーでも他人が書ける")
        XCTAssertEqual(check { $0["/"] = dir(0, acl: true) }, .aclPresent("/"), "上位の ACL も満たさない")
        XCTAssertEqual(check { $0["/opt/homebrew"] = FileFacts(kind: .symlink, uid: 501, gid: 80, mode: 0o755, hasACL: false) }, .unreadable("/opt/homebrew"),
                       "上位がフォルダでない（実体のパスを渡すので起きないはず）")
        XCTAssertEqual(HandoffSafety.check(bundle: bundle, uid: me, reader: FakeFacts(facts: good, children: [:])), .unreadable(bundle), "中を読めない")
    }

    /// 実物の口（一時フォルダ。本人のファイルに ACL を付け、644 と 664 を比べ、シンボリックリンクを見つける）
    func testSystemFactsInTemporaryFolder() throws {
        let real = try XCTUnwrap(AppLocation.realPath(dir.path))
        let bundle = real + "/ShareScale.app"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundle + "/Contents/Info.plist", contents: Data("x".utf8))
        chmod(bundle + "/Contents/Info.plist", 0o644)
        for d in [bundle, bundle + "/Contents", bundle + "/Contents/MacOS"] { chmod(d, 0o755) }
        let reader = SystemFileFacts()
        XCTAssertNil(HandoffSafety.check(bundle: bundle, uid: geteuid(), reader: reader), "一時フォルダの上位（/private/var/folders…）は満たす")
        XCTAssertEqual(HandoffSafety.check(bundle: bundle, uid: geteuid() + 1, reader: reader), .wrongOwner(bundle))
        chmod(bundle + "/Contents/Info.plist", 0o664)
        XCTAssertEqual(HandoffSafety.check(bundle: bundle, uid: geteuid(), reader: reader), .writableByOthers(bundle + "/Contents/Info.plist"))
        chmod(bundle + "/Contents/Info.plist", 0o644)
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone allow write", bundle + "/Contents/Info.plist"]), 0)
        XCTAssertTrue(reader.facts(bundle + "/Contents/Info.plist")?.hasACL ?? false)
        XCTAssertTrue(reader.facts(bundle + "/Contents/Info.plist")?.aclAllowsWrite ?? false, "書き込みを許す ACL（~/Applications の確かめ）")
        XCTAssertEqual(HandoffSafety.check(bundle: bundle, uid: geteuid(), reader: reader), .aclPresent(bundle + "/Contents/Info.plist"))
        XCTAssertEqual(runTool("/bin/chmod", ["-N", bundle + "/Contents/Info.plist"]), 0)
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone deny write", bundle + "/Contents/Info.plist"]), 0)
        XCTAssertEqual(reader.facts(bundle + "/Contents/Info.plist")?.hasACL, true)
        XCTAssertEqual(reader.facts(bundle + "/Contents/Info.plist")?.aclAllowsWrite, false, "拒否だけの ACL は書き込みを許さない")
        XCTAssertEqual(runTool("/bin/chmod", ["-N", bundle + "/Contents/Info.plist"]), 0)
        XCTAssertNil(HandoffSafety.check(bundle: bundle, uid: geteuid(), reader: reader), "ACL を外せば満たす")
        symlink("/etc/hosts", bundle + "/Contents/MacOS/link")
        XCTAssertEqual(HandoffSafety.check(bundle: bundle, uid: geteuid(), reader: reader), .symlinkInside(bundle + "/Contents/MacOS/link"))
        XCTAssertEqual(reader.facts(bundle + "/Contents/MacOS/link")?.kind, .symlink, "リンクはたどらない")
        // ACL を読めない（ENOENT 以外の失敗）時は「書き込みを許す」に倒す（使わない側。再点検 軽微 5）
        XCTAssertTrue(SystemFileFacts.acl("x", read: { _ in (nil, EACCES) }) == (true, true))
        XCTAssertTrue(SystemFileFacts.acl("x", read: { _ in (nil, ENOENT) }) == (false, false), "ACL が無いだけなら許さない")
    }
}

/// 子プロセスを動かして終了コードを返す（試験の中の chmod・codesign 用）
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
