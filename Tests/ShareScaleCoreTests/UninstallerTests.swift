import Darwin
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 「ShareScale を取り除く」（仕様「解除と取り除き」の 1〜7）。一時フォルダをホームとして、口（登録の解除・ゴミ箱・環境設定・unpair・時計）を差し替えて端から端まで試す。
/// ゴミ箱は一時フォルダの中の `Trash`（実物のゴミ箱に移さない）
@MainActor
final class UninstallerTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    var home: URL { dir.appendingPathComponent("home", isDirectory: true) }
    var paths: AppPaths { AppPaths(home: home) }
    var trashDir: URL { dir.appendingPathComponent("Trash", isDirectory: true) }

    /// 利用者の環境を一時フォルダの中に作る（秘密・付帯情報・一時ファイル・記録・環境設定・窓の状態・アプリ）
    func makeInstall() throws {
        let fm = FileManager.default
        for role in ["host", "viewer"] {
            let d = paths.pairings.appendingPathComponent(role, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for n in ["\(String(repeating: "a", count: 32)).key", "\(String(repeating: "a", count: 32)).meta", ".\(String(repeating: "b", count: 32)).1.2.tmp"] {
                fm.createFile(atPath: d.appendingPathComponent(n).path, contents: Data("secret".utf8), attributes: [.posixPermissions: 0o600])
            }
        }
        try fm.createDirectory(at: paths.hostControl, withIntermediateDirectories: true)
        fm.createFile(atPath: paths.hostControl.appendingPathComponent("state.json").path, contents: Data("{}".utf8))
        fm.createFile(atPath: paths.appState.path, contents: Data("{}".utf8))
        try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        fm.createFile(atPath: paths.logs.appendingPathComponent("host.log").path, contents: Data("log".utf8))
        try fm.createDirectory(at: XCTUnwrap(paths.preferenceFiles.first).deletingLastPathComponent(), withIntermediateDirectories: true)
        for p in paths.preferenceFiles { fm.createFile(atPath: p.path, contents: Data("plist".utf8)) }
        try fm.createDirectory(at: paths.savedState, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.copy.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    /// 記録の口: 呼ばれた順
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// 偽の Host（`state.json` の読み取りと、識別子のプロセスの有無）
    final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var _state: HostLiveness
        private var _process: Bool
        init(_ s: HostLiveness) { _state = s; _process = s == .running }
        var state: HostLiveness { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
        var process: Bool { get { lock.withLock { _process } } set { lock.withLock { _process = newValue } } }
    }

    func ports(_ service: FakeLoginItem, appLoginItem: FakeLoginItem? = nil, log: Log, host: Host, trashFails: Set<String> = [],
               unpairResult: @escaping @Sendable (PairingID) -> TargetRemoval = { _ in .removed(name: "") }) -> UninstallPorts {
        let trash = trashDir
        let home = self.home.path
        return UninstallPorts(loginItem: service, appLoginItem: appLoginItem,
                              hostState: { host.state },
                              hostProcessRunning: { host.process },
                              askHostToQuit: { log.add("quit") },
                              unpair: { id in log.add("unpair \(id.hex.prefix(2))"); return unpairResult(id) },
                              trash: { url in
                                  let rel = String(url.path.dropFirst(home.count))
                                  log.add("trash \(rel)")
                                  if trashFails.contains(rel) { throw CocoaError(.fileWriteNoPermission) }
                                  try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
                              },
                              removeDefaults: { log.add("defaults \($0)") },
                              sleep: { s in log.add("sleep \(s)") })
    }

    func exists(_ u: URL) -> Bool { var st = stat(); return lstat(u.path, &st) == 0 }
    /// ゴミ箱の中に秘密（`.key`）が 1 つも無いか
    func trashHasKeys() -> Bool {
        let e = FileManager.default.enumerator(atPath: trashDir.path)
        while let n = e?.nextObject() as? String { if n.hasSuffix(".key") || n.hasSuffix(".tmp") { return true } }
        return false
    }

    func testRemovesEverythingInOrder() async throws {
        try makeInstall()
        let service = FakeLoginItem(.enabled)
        let host = Host(.running)
        service.onUnregister = { host.state = .stopped; host.process = false }     // 解除で launchd が Host を止める
        let log = Log()
        let u = Uninstaller(paths: paths, ports: ports(service, log: log, host: host, unpairResult: { id in
            id == pid(2) ? .removedLocally(name: "居間の Mac mini") : .removed(name: "Studio")
        }))
        let report = await u.run(targets: [(pid(1), "Studio"), (pid(2), "居間の Mac mini")], homebrewRemoved: false)
        XCTAssertEqual(service.calls, ["unregister"])
        XCTAssertEqual(log.all, ["unpair 01", "unpair 02",
                                 "trash /Library/Application Support/ShareScale", "trash /Library/Logs/ShareScale",
                                 "defaults io.github.taki-0105a.ShareScale", "defaults io.github.taki-0105a.ShareScale.Host",
                                 "trash /Library/Preferences/io.github.taki-0105a.ShareScale.plist", "trash /Library/Preferences/io.github.taki-0105a.ShareScale.Host.plist",
                                 "trash /Library/Saved Application State/io.github.taki-0105a.ShareScale.savedState",
                                 "trash /Applications/ShareScale.app"],
                       "Host を止めてから unpair（取り除きの途中で新しい接続を受けない）→ 秘密の削除 → ゴミ箱 → アプリは最後")
        XCTAssertFalse(trashHasKeys(), "秘密・一時ファイルはゴミ箱に移さず削除する")
        XCTAssertTrue(report.completed); XCTAssertNil(report.aborted)
        XCTAssertEqual(report.unreachable, ["居間の Mac mini"])
        XCTAssertEqual(report.brewCommand, "brew uninstall sharescale", "実行はせず、コピーできる形で出す")
        for u in [paths.support, paths.logs, paths.savedState, paths.copy] + paths.preferenceFiles { XCTAssertFalse(exists(u), u.path) }
        XCTAssertEqual(report.summary.title, "ShareScale を完全に削除しました")
        XCTAssertTrue(report.summary.detail.contains("「居間の Mac mini」に接続できなかったため、その Mac の ShareScale Host のメニューでも、この Mac の登録を解除してください。"))
        XCTAssertTrue(report.summary.detail.hasSuffix("最後に、ターミナルで下のコマンドを実行して Homebrew からも削除してください。"), "コマンドは画面がコピーできる形で別に出す")
        XCTAssertEqual(u.phase, .finished); XCTAssertEqual(u.report, report)
        // もう一度（冪等）: 無いものは飛ばし、Homebrew から削除済みなら brew の案内を出さない
        let again = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: Log(), host: Host(.stopped))).run(targets: [], homebrewRemoved: true)
        XCTAssertTrue(again.completed); XCTAssertNil(again.brewCommand)
        XCTAssertEqual(again.summary.detail, "ShareScale を終了します。")
    }

    // Host が止まらなければ中止（何も消さない）。2 秒たっても動いていれば host-control の quit も頼む
    func testAbortsWhenTheHostKeepsRunning() async throws {
        try makeInstall()
        let service = FakeLoginItem(.enabled)
        let log = Log()
        let report = await Uninstaller(paths: paths, ports: ports(service, log: log, host: Host(.running))).run(targets: [(pid(1), "Studio")], homebrewRemoved: false)
        XCTAssertEqual(report.aborted, "ログイン項目の登録は解除しましたが、ShareScale Host が停止したことを確認できなかったため、ほかのものは削除していません。ShareScale Host のメニューから終了してから、もう一度選択してください。",
                       "登録は外れた時の文（点検 M）")
        XCTAssertEqual(report.abortDetail, "ShareScale Host is still running after 10 s (state: running, process: true)")
        XCTAssertEqual(log.all.filter { $0 == "quit" }.count, 1)
        XCTAssertEqual(log.all.firstIndex(of: "quit"), 8, "0.25 秒 × 8 = 2 秒の後に quit を頼む")
        XCTAssertEqual(log.all.filter { $0.hasPrefix("sleep") }.count, 40, "最大 10 秒")
        XCTAssertFalse(log.all.contains { $0.hasPrefix("unpair") || $0.hasPrefix("trash") })
        XCTAssertTrue(exists(paths.pairings.appendingPathComponent("host/\(String(repeating: "a", count: 32)).key")))
        XCTAssertEqual(report.summary.title, "完全な削除を中止しました")
        // 登録の解除に失敗して登録が残る → 中止（何も取り除いていない時の文）
        let stuck = FakeLoginItem(.enabled); stuck.failUnregister = true
        let r2 = await Uninstaller(paths: paths, ports: ports(stuck, log: Log(), host: Host(.stopped))).run(targets: [], homebrewRemoved: false)
        XCTAssertEqual(r2.aborted, "ログイン項目の登録を解除できなかったため、何も削除していません。システム設定 › 一般 › ログイン項目を確認してから、もう一度選択してください。")
        XCTAssertTrue(r2.abortDetail?.hasPrefix("unregister:") ?? false)
        // ログイン項目の状態を読めない（unknown）時も解除を試み、解除の後の状態で判断する（再点検 軽微 6）
        let unknownService = FakeLoginItem(.unknown)
        let unknownHost = Host(.running)
        unknownService.onUnregister = { unknownHost.state = .stopped; unknownHost.process = false }
        let r4 = await Uninstaller(paths: paths, ports: ports(unknownService, log: Log(), host: unknownHost)).run(targets: [], homebrewRemoved: true)
        XCTAssertEqual(unknownService.calls, ["unregister"]); XCTAssertNil(r4.aborted)
        try makeInstall()
        let unknownStuck = FakeLoginItem(.unknown); unknownStuck.failUnregister = true
        let r5 = await Uninstaller(paths: paths, ports: ports(unknownStuck, log: Log(), host: Host(.stopped))).run(targets: [], homebrewRemoved: true)
        XCTAssertEqual(r5.abortDetail?.hasSuffix("(status: unknown)"), true, "解除できず、状態も分からなければ中止")
        // ログイン項目からでなく開かれた Host: 登録は無いが quit で止まる
        let host = Host(.running)
        let quitLog = Log()
        var p = ports(FakeLoginItem(.notRegistered), log: quitLog, host: host)
        p.askHostToQuit = { quitLog.add("quit"); host.state = .stopped; host.process = false }
        let r3 = await Uninstaller(paths: paths, ports: p).run(targets: [], homebrewRemoved: true)
        XCTAssertTrue(r3.completed)
    }

    // state.json を読めない（.unknown）なら止まったとみなさず中止する。state.json が無くても Host のプロセスが生きていれば中止する（点検 A）
    func testUnknownStateOrALiveProcessIsNotStopped() async throws {
        try makeInstall()
        let unknownLog = Log()
        let r = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: unknownLog, host: Host(.unknown))).run(targets: [(pid(1), "Studio")], homebrewRemoved: false)
        XCTAssertEqual(r.aborted, "ShareScale Host が停止したことを確認できなかったため、何も削除していません。ShareScale Host のメニューから終了してから、もう一度選択してください。")
        XCTAssertEqual(r.abortDetail, "host-control/state.json can’t be read")
        XCTAssertEqual(unknownLog.all, [], "待たずに中止し、何もしない")
        let processLog = Log()
        let alive = Host(.stopped); alive.process = true    // state.json は止まっている（無い）が、プロセスは生きている
        let r2 = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: processLog, host: alive)).run(targets: [], homebrewRemoved: false)
        XCTAssertEqual(r2.abortDetail, "ShareScale Host is still running after 10 s (state: stopped, process: true)")
        XCTAssertFalse(processLog.all.contains { $0.hasPrefix("trash") })
        XCTAssertTrue(exists(paths.pairings.appendingPathComponent("viewer/\(String(repeating: "a", count: 32)).key")), "何も消さない")
        XCTAssertEqual(HostLiveness(.unknown(problem: "x")), .unknown)
        XCTAssertEqual(HostLiveness(.notRunning(last: nil)), .stopped)
    }

    // 秘密を消せない → 中止（ゴミ箱に移すと秘密がゴミ箱に入るため）。ゴミ箱に移せないものがあればアプリは残す
    func testSecretsMustBeDeletedAndTheAppIsKeptWhenSomethingIsLeft() async throws {
        try makeInstall()
        let hostDir = paths.pairings.appendingPathComponent("host", isDirectory: true)
        chmod(hostDir.path, 0o500)
        let log = Log()
        let r = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: log, host: Host(.stopped))).run(targets: [(pid(1), "Studio")], homebrewRemoved: false)
        chmod(hostDir.path, 0o700)
        XCTAssertEqual(r.aborted, "ログイン項目の登録を解除し、接続先に登録の解除を伝えましたが、ペアリングの鍵を削除できなかったため、ほかのものは削除していません。~/Library/Application Support/ShareScale/pairings/ の中身とアクセス権を確認してから、もう一度選択してください。")
        XCTAssertEqual(r.abortDetail, "pairings/host: 2 key or temporary file(s) remain", "鍵と一時ファイル（秘密を含む）が残れば中止（再点検 軽微 4）")
        XCTAssertEqual(log.all, ["unpair 01"], "unpair の後、ゴミ箱には何も移さない")
        // 記録のフォルダをゴミ箱に移せない → アプリは残し、もう一度取り除けるようにする
        let log2 = Log()
        let r2 = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: log2, host: Host(.stopped),
                                                               trashFails: ["/Library/Logs/ShareScale"])).run(targets: [], homebrewRemoved: false)
        XCTAssertNil(r2.aborted); XCTAssertFalse(r2.completed); XCTAssertFalse(r2.appTrashed)
        XCTAssertEqual(r2.leftovers, ["~/Library/Logs/ShareScale"])
        XCTAssertTrue(exists(paths.copy), "アプリは残す")
        XCTAssertFalse(log2.all.contains("trash /Applications/ShareScale.app"))
        XCTAssertEqual(r2.summary.title, "ShareScale の一部を削除しました")
        XCTAssertFalse(trashHasKeys())
    }

    // 秘密の削除はリンクをたどらず、フォルダの外を消さない。リンク・他人のフォルダ・知らない名前があれば何も消さずに中止する（点検 B）
    func testSecretDeletionNeverFollowsLinksOrTouchesOtherFiles() async throws {
        let fm = FileManager.default
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        func makeOutside() throws {
            try fm.createDirectory(at: outside.appendingPathComponent("host"), withIntermediateDirectories: true)
            for n in ["notes.txt", "photo.jpg", "host/\(String(repeating: "c", count: 32)).key"] { fm.createFile(atPath: outside.appendingPathComponent(n).path, contents: Data("keep".utf8)) }
        }
        func outsideIntact() -> Bool { ["notes.txt", "photo.jpg", "host/\(String(repeating: "c", count: 32)).key"].allSatisfy { exists(outside.appendingPathComponent($0)) } }
        try makeOutside()
        // pairings を外へのリンクにする（点検担当の再現）→ 中止し、外のファイルは残る。ゴミ箱にも進まない
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        symlink(outside.path, paths.pairings.path)
        XCTAssertEqual(Uninstaller.deleteSecrets(support: paths.support), "pairings: not a real folder (Not a directory)")
        XCTAssertTrue(outsideIntact())
        try makeInstallAround()
        let log = Log()
        let r = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), log: log, host: Host(.stopped))).run(targets: [], homebrewRemoved: true)
        XCTAssertNotNil(r.aborted); XCTAssertFalse(log.all.contains { $0.hasPrefix("trash") }, "鍵を消せなければゴミ箱に進まない")
        XCTAssertTrue(outsideIntact())
        // 役割のフォルダ（host）がリンク → 中止
        unlink(paths.pairings.path)
        try fm.createDirectory(at: paths.pairings, withIntermediateDirectories: true)
        symlink(outside.appendingPathComponent("host").path, paths.pairings.appendingPathComponent("host").path)
        XCTAssertEqual(Uninstaller.deleteSecrets(support: paths.support), "pairings/host: not a real folder (Not a directory)")
        XCTAssertTrue(outsideIntact())
        // support 自体がリンク → 中止
        unlink(paths.pairings.appendingPathComponent("host").path)
        let realSupport = dir.appendingPathComponent("realSupport", isDirectory: true)
        try fm.moveItem(at: paths.support, to: realSupport)
        symlink(realSupport.path, paths.support.path)
        XCTAssertNotNil(Uninstaller.deleteSecrets(support: paths.support))
        unlink(paths.support.path)
        try fm.moveItem(at: realSupport, to: paths.support)
        // 他人のフォルダ（持ち主の番号を変えて表す）→ 中止
        try fm.createDirectory(at: paths.pairings.appendingPathComponent("viewer"), withIntermediateDirectories: true)
        XCTAssertEqual(Uninstaller.deleteSecrets(support: paths.support, uid: geteuid() + 1), "\(paths.support.path): not your folder")
        // 知らない名前があれば、何も消さずに一覧を示す
        let viewer = paths.pairings.appendingPathComponent("viewer")
        let key = viewer.appendingPathComponent("\(String(repeating: "d", count: 32)).key")
        fm.createFile(atPath: key.path, contents: Data("k".utf8))
        fm.createFile(atPath: viewer.appendingPathComponent("notes.txt").path, contents: Data("n".utf8))
        symlink(outside.appendingPathComponent("photo.jpg").path, viewer.appendingPathComponent("\(String(repeating: "e", count: 32)).meta").path)
        XCTAssertEqual(Uninstaller.deleteSecrets(support: paths.support), "pairings/viewer: unexpected items: notes.txt")
        XCTAssertTrue(exists(key), "何も消さない")
        // 知らない名前を除けば消える。形の合うリンクはリンクだけが消え、リンク先は残る
        unlink(viewer.appendingPathComponent("notes.txt").path)
        XCTAssertNil(Uninstaller.deleteSecrets(support: paths.support))
        XCTAssertFalse(exists(key)); XCTAssertFalse(exists(viewer.appendingPathComponent("\(String(repeating: "e", count: 32)).meta")))
        XCTAssertTrue(outsideIntact(), "リンクはたどらない（unlinkat はリンクだけを消す）")
        XCTAssertNil(Uninstaller.deleteSecrets(support: dir.appendingPathComponent("none")), "無いものは飛ばす")
        // 名前の形
        XCTAssertTrue(Uninstaller.isSecretFileName("\(String(repeating: "a", count: 32)).key"))
        XCTAssertTrue(Uninstaller.isSecretFileName(".\(String(repeating: "a", count: 32)).123.456.tmp"))
        for bad in ["\(String(repeating: "A", count: 32)).key", "x.key", ".\(String(repeating: "a", count: 32)).tmp", "..tmp", "notes.txt"] {
            XCTAssertFalse(Uninstaller.isSecretFileName(bad), bad)
        }
    }

    /// `makeInstall` のうち、秘密のフォルダ以外（pairings をリンクにした状態で使う）
    func makeInstallAround() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.copy.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    // 「ログイン時に ShareScale を開く」の登録も外す。外せなくても続け、結果に書く（計画 2f-2）
    func testAlsoRemovesOpeningAtLogin() async throws {
        try makeInstall()
        let service = FakeLoginItem(.notRegistered)
        let app = FakeLoginItem(.enabled)
        let r = await Uninstaller(paths: paths, ports: ports(service, appLoginItem: app, log: Log(), host: Host(.stopped))).run(targets: [], homebrewRemoved: true)
        XCTAssertEqual(app.calls, ["unregister"]); XCTAssertTrue(r.completed)
        try makeInstall()
        let stuck = FakeLoginItem(.enabled); stuck.failUnregister = true
        let r2 = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), appLoginItem: stuck, log: Log(), host: Host(.stopped)))
            .run(targets: [], homebrewRemoved: true)
        XCTAssertTrue(r2.appLoginItemLeft); XCTAssertFalse(r2.completed); XCTAssertNil(r2.aborted)
        XCTAssertTrue(r2.appTrashed, "アプリは消す（残った登録は開けないだけ）")
        XCTAssertEqual(r2.summary.title, "ShareScale の一部を削除しました")
        XCTAssertEqual(r2.summary.detail, "ログイン時に開く ShareScale の登録を解除できませんでした。システム設定 › 一般 › ログイン項目で ShareScale を削除してください。")
        // 登録していなければ触れない
        try makeInstall()
        let none = FakeLoginItem(.notFound)
        _ = await Uninstaller(paths: paths, ports: ports(FakeLoginItem(.notRegistered), appLoginItem: none, log: Log(), host: Host(.stopped))).run(targets: [], homebrewRemoved: true)
        XCTAssertEqual(none.calls, [])
    }

    func testPlannedItemsAndFlow() async throws {
        let items = Uninstaller.plannedItems(paths: AppPaths(home: URL(fileURLWithPath: "/Users/taro")), targetNames: ["Studio", "Air"], homebrewRemoved: false)
        XCTAssertEqual(items, ["ログイン項目の ShareScale Host と、ログイン時に開く ShareScale の登録を解除し、ShareScale Host を終了します",
                               "接続先 2 台に、この Mac の登録を解除するよう伝えます: Studio、Air",
                               "ペアリングの鍵を削除します（ゴミ箱には入れません）: ~/Library/Application Support/ShareScale/pairings",
                               "ゴミ箱に入れる: ~/Library/Application Support/ShareScale",
                               "ゴミ箱に入れる: ~/Library/Logs/ShareScale",
                               "ゴミ箱に入れる: ~/Library/Preferences/io.github.taki-0105a.ShareScale.plist",
                               "ゴミ箱に入れる: ~/Library/Preferences/io.github.taki-0105a.ShareScale.Host.plist",
                               "ゴミ箱に入れる: ~/Library/Saved Application State/io.github.taki-0105a.ShareScale.savedState",
                               "ゴミ箱に入れる: ~/Applications/ShareScale.app",
                               "最後に brew uninstall sharescale の実行を案内します（アプリからは実行しません）"])
        XCTAssertFalse(Uninstaller.plannedItems(paths: paths, targetNames: [], homebrewRemoved: true).contains { $0.contains("brew") })
        // 取り除きの窓の段階（複製だけ。確かめ → 取り除き中 → 結果）
        try makeInstall()
        let model = ViewerModel(client: nil, displays: { [] })
        let targets = ViewerTargets(book: nil, model: model, onSwitch: { _ in })
        let log = Log()
        let loginService = FakeLoginItem(.notRegistered)
        let loginItems = LoginItemController(role: .copy, service: loginService, stateFile: AppStateFile(url: dir.appendingPathComponent("s.json")),
                                             ownCDHash: "0a", hostPID: { nil }, sleep: { _ in }, hostEmbedded: { true })
        let flow = UninstallFlow(role: .copy, paths: paths, targets: targets, loginItems: loginItems) {
            self.ports(FakeLoginItem(.notRegistered), log: log, host: Host(.stopped))
        }
        XCTAssertTrue(flow.available)
        // 起動時に Homebrew から削除されていた: 問いかけを出し、設定から開いても brew の案内を出さない（点検 O）
        flow.noteHomebrewRemoved()
        XCTAssertTrue(flow.askAfterHomebrewRemoval)
        flow.begin()
        XCTAssertEqual(flow.stage, .confirming); XCTAssertFalse(flow.askAfterHomebrewRemoval)
        XCTAssertFalse(flow.plannedItems.contains { $0.contains("brew") }, "Homebrew から削除済みなら brew の案内を出さない")
        flow.windowClosed()
        XCTAssertEqual(flow.stage, .idle, "確かめの途中で窓を閉じたら取りやめる")
        flow.begin()
        flow.confirm()
        XCTAssertEqual(flow.stage, .running)
        XCTAssertFalse(loginItems.model.canToggle, "取り除き中はスイッチを押せない（点検 F）")
        await loginItems.setEnabled(true)
        XCTAssertEqual(loginService.calls, [], "取り除き中は登録しない")
        await waitOnMain(5) { flow.stage == .finished }
        XCTAssertEqual(flow.stage, .finished)
        XCTAssertEqual(flow.uninstaller?.report?.completed, true)
        XCTAssertTrue(flow.didRemove); XCTAssertFalse(flow.available, "取り除いた後はもう始めない")
        XCTAssertFalse(loginItems.model.canToggle, "取り除いた後もスイッチを押せない")
        flow.windowClosed()
        XCTAssertEqual(flow.stage, .finished, "取り除いた後は窓を閉じてもそのまま")
        // 中止の結果からは始め直せる（窓を閉じると鍵も外れる）
        try makeInstall()
        let busyLog = Log()
        let loginItems2 = LoginItemController(role: .copy, service: FakeLoginItem(.notRegistered), stateFile: AppStateFile(url: dir.appendingPathComponent("s2.json")),
                                              ownCDHash: "0a", hostPID: { nil }, sleep: { _ in }, hostEmbedded: { true })
        let aborting = UninstallFlow(role: .copy, paths: paths, targets: targets, loginItems: loginItems2) {
            self.ports(FakeLoginItem(.notRegistered), log: busyLog, host: Host(.unknown))
        }
        aborting.begin(); aborting.confirm()
        await waitOnMain(5) { aborting.stage == .finished }
        XCTAssertNotNil(aborting.uninstaller?.report?.aborted); XCTAssertFalse(aborting.didRemove)
        aborting.begin()
        XCTAssertEqual(aborting.stage, .confirming, "中止の結果から始め直せる")
        XCTAssertNil(aborting.uninstaller)
        XCTAssertTrue(loginItems2.model.canToggle, "始め直す前は鍵を外す")
        aborting.cancel()
        // ログイン項目を登録している間は始めない（点検 F）
        let slow = FakeLoginItem(.notRegistered)
        let gate = Locked(false)
        let loginItems3 = LoginItemController(role: .copy, service: slow, stateFile: AppStateFile(url: dir.appendingPathComponent("s3.json")),
                                              ownCDHash: "0a", hostPID: { nil }, sleep: { _ in while !gate.value { try? await Task.sleep(nanoseconds: 1_000_000) } }, hostEmbedded: { true })
        let blocked = UninstallFlow(role: .copy, paths: paths, targets: targets, loginItems: loginItems3) {
            self.ports(FakeLoginItem(.notRegistered), log: Log(), host: Host(.stopped))
        }
        let registering = Task { await loginItems3.setEnabled(true) }
        await waitOnMain(2) { loginItems3.busy }
        XCTAssertFalse(blocked.available)
        XCTAssertEqual(blocked.note, "ログイン項目を変更しています。終わってから削除してください。")
        blocked.begin()
        XCTAssertEqual(blocked.stage, .idle)
        gate.value = true
        await registering.value
        let dev = UninstallFlow(role: .development, paths: paths, targets: targets) { self.ports(FakeLoginItem(.notRegistered), log: log, host: Host(.stopped)) }
        XCTAssertFalse(dev.available)
        XCTAssertEqual(dev.note, "完全な削除は ~/Applications の ShareScale からだけ行えます。")
        dev.begin()
        XCTAssertEqual(dev.stage, .idle, "複製でなければ始めない")
    }

    // 実物の組み立て: Host の生存は state.json と Host の識別子のプロセスの両方で見る（再点検 軽微 6。ゴミ箱・環境設定の口は呼ばない）
    func testSystemPortsWiring() throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))   // 上のフォルダも 700 が要る
        let asked = Locked<[String]>([])
        let notified = Locked(0)
        let ports = UninstallPorts.system(client: HostControlClient(folder: folder, notify: { notified.update { $0 += 1 } }),
                                          unpair: { _ in .removed(name: "") },
                                          isRunning: { id in asked.update { $0.append(id) }; return true })
        XCTAssertTrue(ports.hostProcessRunning())
        XCTAssertEqual(asked.value, ["io.github.taki-0105a.ShareScale.Host"], "Host の識別子で尋ねる")
        XCTAssertEqual(ports.hostState(), .stopped, "state.json が無ければ止まっている（プロセスは別に見る）")
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(support.path, 0o700)
        FileManager.default.createFile(atPath: folder.directory.appendingPathComponent("state.json").path, contents: Data("{".utf8), attributes: [.posixPermissions: 0o600])
        XCTAssertEqual(ports.hostState(), .unknown, "読めなければ分からない")
        ports.askHostToQuit()
        XCTAssertEqual(folder.readRequests(now: Int64(Date().timeIntervalSince1970)).requests.map(\.op), [.quit])
        XCTAssertEqual(notified.value, 1)
    }

    // 取り除いた後は帳簿を読み直さない（秘密のフォルダを作り直さない。点検 N）
    func testFrozenTargetsDoNotRecreateTheFolder() throws {
        let store = SecretStore(base: support, role: .viewer, machine: "m")
        let model = ViewerModel(client: nil, displays: { [] })
        let targets = ViewerTargets(book: TargetBook(store: store, settings: MemoryStore()), model: model, onSwitch: { _ in })
        targets.freeze()
        targets.reload()
        XCTAssertFalse(exists(viewerDir), "帳簿を読まない（読むとフォルダを作る）")
        XCTAssertTrue(targets.frozen)
    }
}
