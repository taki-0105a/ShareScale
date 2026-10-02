import Darwin
import XCTest
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// ShareScale.app がメニューバーを受け持っている印と、Host のアイコンを出すかの判定（計画 2f-2 案 2。一時フォルダ）
final class MenuBarClaimTests: TempDirTestCase {
    var folder: HostControlFolder { HostControlFolder(directory: dir.appendingPathComponent("support/host-control", isDirectory: true)) }

    func testShapeIsStrict() throws {
        let c = try XCTUnwrap(MenuBarClaim(pid: 4242, at: 1_800_000_000))
        XCTAssertEqual(String(decoding: c.encoded(), as: UTF8.self), "{\"format\":1,\"pid\":4242,\"at\":1800000000}\n")
        XCTAssertEqual(MenuBarClaim.decode(c.encoded()), c)
        XCTAssertNil(MenuBarClaim.decode(Data("{\"format\":1,\"pid\":4242,\"at\":1,\"x\":1}".utf8)), "知らないキー")
        XCTAssertNil(MenuBarClaim.decode(Data("{\"format\":2,\"pid\":4242,\"at\":1}".utf8)), "知らない形式")
        XCTAssertNil(MenuBarClaim.decode(Data("{\"format\":1,\"pid\":\"4242\",\"at\":1}".utf8)), "型違い")
        XCTAssertNil(MenuBarClaim.decode(Data("{\"format\":1,\"pid\":0,\"at\":1}".utf8)), "pid は 1 以上")
        XCTAssertNil(MenuBarClaim(pid: Int64(Int32.max) + 1, at: 1))
    }

    func testWriteReadAndRemoveOnlyOwnClaim() throws {
        let f = folder
        XCTAssertNil(f.readMenuBarClaim(), "無ければ nil（Host はアイコンを出す）")
        try f.writeMenuBarClaim(XCTUnwrap(MenuBarClaim(pid: 100, at: 1)))
        XCTAssertEqual(f.readMenuBarClaim()?.pid, 100)
        var st = stat(); XCTAssertEqual(stat(f.menuBarClaimURL.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        f.removeMenuBarClaim(ownedBy: 200)
        XCTAssertEqual(f.readMenuBarClaim()?.pid, 100, "別の ShareScale の印は消さない")
        f.removeMenuBarClaim(ownedBy: 100)
        XCTAssertNil(f.readMenuBarClaim())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.menuBarClaimURL.path))
        f.removeMenuBarClaim(ownedBy: 100)   // 無くても何もしない
        // 形の違う印は、誰の印か分からないので消してよい
        try Data("garbage".utf8).write(to: f.menuBarClaimURL)
        XCTAssertNil(f.readMenuBarClaim())
        f.removeMenuBarClaim(ownedBy: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.menuBarClaimURL.path))
        // 書きかけの一時ファイル（落ちたプロセスのもの）は起動時の片付けで消える
        let dead = "999999"
        try Data("x".utf8).write(to: f.directory.appendingPathComponent(".menubar-owner.\(dead).7.tmp"))
        XCTAssertEqual(HostControlFolder.temporaryOwner(".menubar-owner.\(dead).7.tmp"), .some(pid_t(999999)))
        f.removeStaleTemporaries()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".menubar-owner.\(dead).7.tmp").path))
    }

    func testIconIsHiddenOnlyWhileTheClaimingProcessIsShareScale() throws {
        let c = try XCTUnwrap(MenuBarClaim(pid: 100, at: 1))
        XCTAssertTrue(HostIconPolicy.showsIcon(claim: nil, hostHealthy: true, isShareScale: { _ in true }), "印が無ければ出す")
        XCTAssertFalse(HostIconPolicy.showsIcon(claim: c, hostHealthy: true, isShareScale: { $0 == 100 }), "ShareScale.app が受け持っている間は出さない")
        XCTAssertTrue(HostIconPolicy.showsIcon(claim: c, hostHealthy: true, isShareScale: { _ in false }), "落ちた・終わった・pid が別のアプリなら出す")
    }

    // Host が起動に失敗した・state.json を書けない時は、印があっても出す（ShareScale の節が出ないため。点検 2f-2）
    func testIconIsShownWhenTheHostItselfIsUnhealthy() throws {
        let c = try XCTUnwrap(MenuBarClaim(pid: 100, at: 1))
        XCTAssertTrue(HostIconPolicy.showsIcon(claim: c, hostHealthy: false, isShareScale: { _ in true }))
    }

    // 実物の判定（`NSRunningApplication` の写し）: 終わった pid・終了の途中・別のアプリ・0 以下は ShareScale とみなさない（点検 2f-2）
    func testIsShareScaleLooksAtTheRunningApplication() {
        let apps: [pid_t: HostIconPolicy.RunningApp] = [
            100: HostIconPolicy.RunningApp(bundleIdentifier: BundleIdentifiers.app, isTerminated: false),
            200: HostIconPolicy.RunningApp(bundleIdentifier: BundleIdentifiers.app, isTerminated: true),
            300: HostIconPolicy.RunningApp(bundleIdentifier: "com.apple.Safari", isTerminated: false),
            400: HostIconPolicy.RunningApp(bundleIdentifier: nil, isTerminated: false),
        ]
        let lookup: (pid_t) -> HostIconPolicy.RunningApp? = { apps[$0] }
        XCTAssertTrue(HostIconPolicy.isShareScale(100, lookup: lookup))
        XCTAssertFalse(HostIconPolicy.isShareScale(200, lookup: lookup), "終了の途中")
        XCTAssertFalse(HostIconPolicy.isShareScale(300, lookup: lookup), "pid が使い回されて別のアプリ")
        XCTAssertFalse(HostIconPolicy.isShareScale(400, lookup: lookup))
        XCTAssertFalse(HostIconPolicy.isShareScale(500, lookup: lookup), "終わった pid（死んだ pid）")
        XCTAssertFalse(HostIconPolicy.isShareScale(0, lookup: { _ in apps[100] }))
        XCTAssertFalse(HostIconPolicy.isShareScale(Int64(Int32.max) + 1, lookup: { _ in apps[100] }))
    }
}
