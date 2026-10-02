import Darwin
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol

/// 「ログイン時に ShareScale を開く」・「Dock に表示する」・Host のアイコン（計画 2f-2 案 1・2。実物の `SMAppService` と `NSApp` に触れない）
@MainActor
final class MenuBarSettingsTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    func testOpenAtLoginIsOffByDefaultAndOnlyTheCopyRegisters() {
        let service = FakeLoginItem(.notFound)   // macOS 27 は登録前に .notFound を返すことがある
        let c = OpenAtLoginController(role: .copy, service: service)
        XCTAssertEqual(c.status, .notRegistered, "アプリ自身は必ずあるので「まだ登録していない」")
        XCTAssertFalse(c.model.isOn); XCTAssertTrue(c.model.canToggle)
        XCTAssertEqual(c.model.note, "オンにすると、ログインした時に ShareScale が開き、メニューバーに表示されます。")
        c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"]); XCTAssertTrue(c.model.isOn)
        XCTAssertEqual(c.model.note, "ログインすると ShareScale が開き、メニューバーに表示されます。")
        c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"], "登録済みなら登録し直さない")
        c.setEnabled(false)
        XCTAssertEqual(service.calls, ["register", "unregister"]); XCTAssertFalse(c.model.isOn)
        // 開発の組み立てでは登録しない（組み立て直すと開けなくなる）
        let dev = FakeLoginItem(.notRegistered)
        let d = OpenAtLoginController(role: .development, service: dev)
        XCTAssertFalse(d.model.canToggle)
        XCTAssertEqual(d.model.note, "ログイン時に開く設定は、~/Applications/ShareScale.app からだけ変更できます。")
        d.setEnabled(true)
        XCTAssertEqual(dev.calls, [])
        // 取り除きの間は押せない
        c.lockForRemoval(); XCTAssertFalse(c.model.canToggle); c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register", "unregister"])
        c.unlockAfterRemoval(); XCTAssertTrue(c.model.canToggle)
    }

    func testOpenAtLoginApprovalAndFailure() {
        let service = FakeLoginItem(.requiresApproval)
        let c = OpenAtLoginController(role: .copy, service: service)
        XCTAssertTrue(c.model.isOn); XCTAssertTrue(c.model.needsApproval)
        XCTAssertEqual(c.model.note, "ログイン項目で ShareScale がオフになっています。システム設定 › 一般 › ログイン項目で ShareScale をオンにしてください。")
        c.openLoginItems()
        XCTAssertEqual(service.calls, ["open"])
        service.set(.notRegistered); service.failRegister = true
        c.setEnabled(true)
        XCTAssertEqual(c.model.result, "ログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。")
        XCTAssertNotNil(c.model.resultDetail); XCTAssertFalse(c.model.isOn)
        service.failRegister = false
        c.setEnabled(true)
        XCTAssertNil(c.model.result, "成功したら失敗の一言を消す")
    }

    func testDockAndHostIconSettingsAreAppliedAndSaved() {
        let store = MemoryStore()
        let docked = Locked<[Bool]>([]), claims = Locked<[Bool]>([])
        let s = AppearanceSettings(preferences: AppearancePreferences(store: store), applyDock: { v in docked.update { $0.append(v) } },
                                   claim: { v in claims.update { $0.append(v) } })
        XCTAssertTrue(s.showsInDock, "Dock に表示するは既定でオン"); XCTAssertFalse(s.hostIconAlwaysVisible, "Host のアイコンを常に出すは既定でオフ")
        s.applyAtLaunch()
        XCTAssertEqual(docked.value, [true]); XCTAssertEqual(claims.value, [true], "起動時に受け持つ")
        s.setShowsInDock(false)
        XCTAssertEqual(docked.value, [true, false]); XCTAssertEqual(store.all["appearance.dock"], "0")
        s.setHostIconAlwaysVisible(true)
        XCTAssertEqual(claims.value, [true, false], "常に出すなら手放す"); XCTAssertEqual(store.all["appearance.hostIcon"], "1")
        s.releaseAtQuit()
        XCTAssertEqual(claims.value, [true, false, false])
        let again = AppearanceSettings(preferences: AppearancePreferences(store: store), applyDock: { _ in }, claim: { _ in })
        XCTAssertFalse(again.showsInDock); XCTAssertTrue(again.hostIconAlwaysVisible, "保存した値を読む")
    }

    func testClaimKeeperWritesRemovesAndNotifies() {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        let notified = Locked(0)
        let k = MenuBarClaimKeeper(folder: folder, pid: 4242, notify: { notified.update { $0 += 1 } }, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
        k.update(claim: true)
        XCTAssertEqual(folder.readMenuBarClaim(), MenuBarClaim(pid: 4242, at: 1_800_000_000)); XCTAssertEqual(notified.value, 1)
        k.update(claim: false)
        XCTAssertNil(folder.readMenuBarClaim()); XCTAssertEqual(notified.value, 2)
        // 書けない（フォルダに書けない）時は通知もしない（Host はアイコンを出したまま）
        chmod(folder.directory.path, 0o500)
        defer { chmod(folder.directory.path, 0o700) }
        k.update(claim: true)
        XCTAssertEqual(notified.value, 2)
    }
}
