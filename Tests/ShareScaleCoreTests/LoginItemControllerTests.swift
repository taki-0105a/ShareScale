import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore

/// 偽のログイン項目（実物の `SMAppService` に触れない）。呼ばれた順を記録する
final class FakeLoginItem: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus
    private var _calls: [String] = []
    var failRegister = false
    var failUnregister = false
    /// 登録した時の状態（既定は enabled。`requiresApproval` で利用者がオフにしている時を表す）
    var statusAfterRegister: LoginItemStatus = .enabled
    /// 登録・解除の時に呼ぶ（Host の起動・終了を表す）
    var onRegister: () -> Void = {}
    var onUnregister: () -> Void = {}
    /// LaunchServices の更新の時に呼ぶ（計画 2j）
    var onRefresh: () -> Void = {}
    init(_ s: LoginItemStatus) { _status = s }
    var calls: [String] { lock.withLock { _calls } }
    func record(_ c: String) { lock.withLock { _calls.append(c) } }
    func status() -> LoginItemStatus { lock.withLock { _status } }
    func set(_ s: LoginItemStatus) { lock.withLock { _status = s } }
    func register() throws {
        record("register")
        if failRegister { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
        set(statusAfterRegister); onRegister()
    }
    func unregister() throws {
        record("unregister")
        if failUnregister { throw NSError(domain: "SMAppServiceErrorDomain", code: 2) }
        set(.notRegistered); onUnregister()
    }
    func openSystemSettingsLoginItems() { record("open") }
    func refreshLaunchServices() async { record("refresh"); onRefresh() }
}

/// 呼ばれた URL を記録する（裏のスレッドから呼ばれる）
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [URL] = []
    var all: [URL] { lock.withLock { _all } }
    func add(_ u: URL) { lock.withLock { _all.append(u) } }
}

/// ログイン項目の登録・解除（仕様「ログイン項目の登録」。時間の待ちは数えるだけで待たない）
@MainActor
final class LoginItemControllerTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    var stateFile: AppStateFile { AppStateFile(url: support.appendingPathComponent("app-state.json")) }

    /// Host の pid（nil なら動いていない）と、眠った秒数の記録
    final class Clock: @unchecked Sendable {
        var pid: Int64?
        var slept: [Double] = []
        /// `after` 秒眠った後に Host が起動する（nil なら起動しない）
        var startsAfter: Double?
        var startedPID: Int64 = 200
        var total: Double { slept.reduce(0, +) }
        /// 登録した回数（更新の後の登録し直しの試験で、何回目の起動が止められるかを決める。計画 2j）
        var registers = 0
        /// 応答を待つ間の 0.25 秒を除いた待ち（解除の後の待ち・やり直しの前の待ち）
        var waits: [Double] { slept.filter { $0 != 0.25 } }   // 0.25 = `LoginItemController.pollInterval`（`testUpdateTimingValues` が縛る）
    }

    /// 更新の後の登録し直し（計画 2j）: 前の版の Host（pid 100）が動いていて、記録した CDHash が違う。
    /// `blocked` 回目までの登録では Host が起動しない（macOS に止められた）。それより後の登録では 0.5 秒で起動する（`never` なら起動しない）
    func updated(blocked: Int, never: Bool = false, distribution: DistributionStatus? = nil) throws -> (FakeLoginItem, Clock, LoginItemController) {
        let service = FakeLoginItem(.enabled)
        let clock = Clock(); clock.pid = 100
        service.onUnregister = { clock.pid = nil; clock.startsAfter = nil }
        service.onRegister = {
            clock.registers += 1
            if !never, clock.registers > blocked { clock.startsAfter = clock.total + 0.5 }
        }
        try stateFile.save(AppState(registeredCDHash: "0a0a"))
        return (service, clock, controller(service, own: "0b0b", clock: clock, distribution: distribution))
    }

    func controller(_ service: FakeLoginItem, role: AppRole = .copy, own: String? = "aa", clock: Clock, distribution: DistributionStatus? = nil,
                    hostEmbedded: Bool = true) -> LoginItemController {
        LoginItemController(role: role, service: service, stateFile: stateFile, ownCDHash: own, hostPID: { clock.pid },
                            sleep: { s in
                                clock.slept.append(s)
                                if let a = clock.startsAfter, clock.total >= a { clock.pid = clock.startedPID }
                            }, distribution: distribution, hostEmbedded: { hostEmbedded })
    }

    func testTurnOnWaitsForTheHostAndRecordsTheCDHash() async {
        let service = FakeLoginItem(.notRegistered)
        let clock = Clock(); clock.startsAfter = 1.0
        let distribution = DistributionStatus()
        let c = controller(service, clock: clock, distribution: distribution)
        XCTAssertFalse(c.model.isOn); XCTAssertTrue(c.model.canToggle)
        XCTAssertEqual(c.model.note, "オンにすると、ログイン時に ShareScale Host が起動し、ほかの Mac からこの Mac の表示倍率を変更できるようになります。")
        await c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"])
        XCTAssertEqual(clock.total, 1.0, accuracy: 0.001, "Host が応答するまで 0.25 秒ずつ待つ")
        XCTAssertTrue(c.model.isOn); XCTAssertFalse(c.model.busy)
        XCTAssertEqual(c.model.result, "ShareScale Host を登録しました。動いています。"); XCTAssertFalse(c.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "aa", "登録した時の CDHash を記録する")
        XCTAssertEqual(distribution.lines.map(\.text), ["ログイン項目: ShareScale Host を登録しました。動いています。"], "結果を診断に")
        // オフ: 解除（記録も消す。pairings/host/ には触れない）
        await c.setEnabled(false)
        XCTAssertEqual(service.calls, ["register", "unregister"])
        XCTAssertFalse(c.model.isOn); XCTAssertNil(stateFile.load().state.registeredCDHash)
        XCTAssertEqual(c.model.result, "ShareScale Host の登録を解除しました。接続元の Mac とのペアリングは残っています（オンに戻せばそのまま使えます）。")
    }

    // 10 秒応答が無ければ 解除 → 5 秒 → 登録 を 1 回だけ
    func testNoResponseRetriesOnce() async {
        let service = FakeLoginItem(.notRegistered)
        let clock = Clock()                       // 起動しない
        let c = controller(service, clock: clock)
        await c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register", "unregister", "register"], "やり直しは 1 回だけ")
        XCTAssertEqual(clock.slept.filter { $0 == 5 }.count, 1, "解除の後 5 秒")
        XCTAssertEqual(clock.total, 10 + 5 + 10, accuracy: 0.001, "10 秒待つ → 5 秒 → 10 秒待つ")
        XCTAssertTrue(c.model.resultIsError)
        XCTAssertEqual(c.model.result, "ShareScale Host を登録しましたが、応答がありません。「この Mac を接続先にする」をオフにしてからオンにしてください。")
        XCTAssertNil(stateFile.load().state.registeredCDHash, "応答が無ければ記録しない（次に開いた時にもう一度登録し直す。点検 L）")
        // やり直しで応答した
        let service2 = FakeLoginItem(.notRegistered)
        let clock2 = Clock(); clock2.startsAfter = 12
        let c2 = controller(service2, clock: clock2)
        await c2.setEnabled(true)
        XCTAssertEqual(service2.calls, ["register", "unregister", "register"])
        XCTAssertFalse(c2.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "aa", "やり直しで応答すれば記録する")
        // 前から動いている Host（同じ pid）は応答とみなさない（登録で起動した新しい Host を待つ）
        let service3 = FakeLoginItem(.notRegistered)
        let clock3 = Clock(); clock3.pid = 100
        let c3 = controller(service3, clock: clock3)
        await c3.setEnabled(true)
        XCTAssertEqual(service3.calls, ["register", "unregister", "register"])
    }

    // requiresApproval（ログイン項目で利用者がオフにした）なら登録し直さず、システム設定を開くボタン
    func testRequiresApprovalIsNotReRegistered() async {
        let service = FakeLoginItem(.requiresApproval)
        let clock = Clock()
        let distribution = DistributionStatus()
        let c = controller(service, clock: clock, distribution: distribution)
        XCTAssertTrue(c.model.isOn, "登録はされている")
        XCTAssertTrue(c.model.needsApproval)
        XCTAssertEqual(c.model.note, "ログイン項目で ShareScale がオフになっています。システム設定 › 一般 › ログイン項目で ShareScale をオンにしてください。")
        await c.setEnabled(true)
        XCTAssertEqual(service.calls, [], "登録し直さない")
        XCTAssertEqual(distribution.lines.last?.action, .openLoginItemsSettings, "診断の行から「ログイン項目を開く…」（計画 2f-1 案 5）")
        XCTAssertNil(c.model.result, "画面ではスイッチの下の説明だけにする（同じ手順を 2 回言わない。計画 2f-1）")
        XCTAssertEqual(distribution.lines.last?.text, "ログイン項目: ログイン項目で ShareScale がオフになっているため、登録し直しませんでした。システム設定 › 一般 › ログイン項目でオンにしてください。",
                       "診断の行には手順を残す")
        c.openLoginItems()
        XCTAssertEqual(service.calls, ["open"])
        await c.startup()
        XCTAssertEqual(service.calls, ["open"], "起動時も登録し直さない")
        // システム設定でオンに戻した後に読み直すと、古い知らせ（診断の行）を消す（2f-1「2f-2 への注記」）
        c.refresh()
        XCTAssertEqual(distribution.lines.count, 1, "まだオフの間は残す")
        service.set(.enabled)
        c.refresh()
        XCTAssertEqual(distribution.lines, [], "オンに戻したら消す"); XCTAssertNil(c.model.result); XCTAssertTrue(c.model.isOn)
        // 登録した直後に requiresApproval になった
        let s2 = FakeLoginItem(.notRegistered); s2.statusAfterRegister = .requiresApproval
        let c2 = controller(s2, clock: Clock())
        await c2.setEnabled(true)
        XCTAssertEqual(s2.calls, ["register"]); XCTAssertTrue(c2.model.needsApproval)
    }

    // macOS 27 は一度も登録していないログイン項目に .notFound を返す（2026-09-30 実機）。中に Host があれば「まだ登録していない」として押せる（計画 2f-1）
    func testNotFoundBeforeTheFirstRegistrationIsTreatedAsNotRegistered() async {
        let service = FakeLoginItem(.notFound)
        let clock = Clock(); clock.startsAfter = 0.5
        let c = controller(service, clock: clock)
        XCTAssertTrue(c.model.canToggle, "中に Host があれば押せる"); XCTAssertFalse(c.model.isOn)
        XCTAssertEqual(c.model.note, "オンにすると、ログイン時に ShareScale Host が起動し、ほかの Mac からこの Mac の表示倍率を変更できるようになります。")
        await c.setEnabled(true)
        XCTAssertEqual(service.calls, ["register"], "登録を試みる")
        XCTAssertEqual(c.model.result, "ShareScale Host を登録しました。動いています。")
        // 中に Host があって登録が投げた: 本文は何をすればよいか、生の理由は「詳細をコピー」
        let failing = FakeLoginItem(.notFound); failing.failRegister = true
        let f = controller(failing, clock: Clock())
        await f.setEnabled(true)
        XCTAssertEqual(failing.calls, ["register"])
        XCTAssertEqual(f.model.result, "ShareScale Host をログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。")
        XCTAssertTrue(f.model.resultDetail?.contains("SMAppServiceErrorDomain") == true)
        // 中に Host が無い: 押せず、登録を試みない
        let none = FakeLoginItem(.notFound)
        let n = controller(none, clock: Clock(), hostEmbedded: false)
        XCTAssertFalse(n.model.canToggle)
        XCTAssertEqual(n.model.note, "このアプリの中に ShareScale Host が見つかりません。ShareScale を入れ直してください。")
        await n.setEnabled(true)
        XCTAssertEqual(none.calls, [])
        // 中に Host が無い × 登録していない（.notRegistered）も「見つかりません」（点検 2f-1）
        let missingNotRegistered = controller(FakeLoginItem(.notRegistered), clock: Clock(), hostEmbedded: false)
        XCTAssertFalse(missingNotRegistered.model.canToggle); XCTAssertTrue(missingNotRegistered.model.note.contains("入れ直して"))
        // 中に Host が無い × 登録済み: そのまま（解除できる）
        let stale = FakeLoginItem(.enabled)
        let e = controller(stale, clock: Clock(), hostEmbedded: false)
        XCTAssertTrue(e.model.isOn); XCTAssertTrue(e.model.canToggle, "解除できるように押せる")
        await e.setEnabled(false)
        XCTAssertEqual(stale.calls, ["unregister"])
        XCTAssertEqual(controller(FakeLoginItem(.requiresApproval), clock: Clock(), hostEmbedded: false).model.needsApproval, true)
    }

    // アプリの中の Host の有無（一時フォルダに作ったバンドルで。リンクは認めない）
    func testEmbeddedHostIsCheckedInsideTheBundle() throws {
        let app = support.appendingPathComponent("ShareScale.app")
        let host = app.appendingPathComponent(EmbeddedHost.relativePath)
        XCTAssertFalse(EmbeddedHost.isPresent(in: app), "無い")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        func plist(_ id: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try data.write(to: host.appendingPathComponent("Contents/Info.plist"))
        }
        try plist("io.github.taki-0105a.Other")
        XCTAssertFalse(EmbeddedHost.isPresent(in: app), "識別子が違う")
        try plist("io.github.taki-0105a.ShareScale.Host")
        XCTAssertTrue(EmbeddedHost.isPresent(in: app))
        // Host.app がリンク
        let other = support.appendingPathComponent("Linked.app")
        let linkedHost = other.appendingPathComponent(EmbeddedHost.relativePath)
        try FileManager.default.createDirectory(at: linkedHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHost, withDestinationURL: host)
        XCTAssertFalse(EmbeddedHost.isPresent(in: other), "リンクは認めない")
        // Host.app/Contents がリンク（点検 2f-1）
        let third = support.appendingPathComponent("LinkedContents.app")
        let thirdHost = third.appendingPathComponent(EmbeddedHost.relativePath)
        try FileManager.default.createDirectory(at: thirdHost, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: thirdHost.appendingPathComponent("Contents"), withDestinationURL: host.appendingPathComponent("Contents"))
        XCTAssertFalse(EmbeddedHost.isPresent(in: third), "Host.app/Contents のリンクも認めない")
    }

    // 複製の起動時: CDHash が変わっていれば LaunchServices を更新 → 解除 → 1 秒 → 登録（同じなら何もしない。開発の組み立ては自動では登録し直さない）
    func testStartupReRegistersWhenTheCDHashChanged() async throws {
        let service = FakeLoginItem(.enabled)
        let clock = Clock(); clock.pid = 100
        service.onUnregister = { clock.pid = nil }
        service.onRegister = { clock.startsAfter = clock.total + 0.5 }
        try stateFile.save(AppState(registeredCDHash: "0a0a"))
        let c = controller(service, own: "0b0b", clock: clock)
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register"])
        XCTAssertEqual(clock.slept.first, 1, "解除の後 1 秒（計画 2j。待ちの長さは、止められるかを決めない）")
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b")
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。")
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register"], "同じ CDHash なら登録し直さない")
        // 登録していない・開発の組み立て・署名の無い組み立てでは何もしない
        let off = FakeLoginItem(.notRegistered)
        await controller(off, own: "0c", clock: Clock()).startup()
        let dev = FakeLoginItem(.enabled)
        await controller(dev, role: .development, own: "0c", clock: Clock()).startup()
        let unsigned = FakeLoginItem(.enabled)
        await controller(unsigned, own: nil, clock: Clock()).startup()
        XCTAssertEqual(off.calls + dev.calls + unsigned.calls, [])
    }

    // ログイン項目でオフ（requiresApproval）の間に更新し、システム設定でオンに戻した: 古い知らせを消した後、起動時と同じ登録し直しを行う（点検 2f-2）
    func testTurningLoginItemsBackOnRunsTheReRegisterCheck() async throws {
        let service = FakeLoginItem(.requiresApproval)
        let clock = Clock(); clock.pid = 100
        service.onUnregister = { clock.pid = nil }
        service.onRegister = { clock.startsAfter = clock.total + 0.5 }
        try stateFile.save(AppState(registeredCDHash: "0a0a"))
        let c = controller(service, own: "0b0b", clock: clock)
        await c.setEnabled(true)   // 登録し直さない（needsApproval）
        XCTAssertEqual(service.calls, [])
        service.set(.enabled)
        c.refresh()
        await waitOnMain(3) { service.calls == ["refresh", "unregister", "register"] && !c.busy }
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register"])
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b")
    }

    // 更新の後の登録し直しの待ち時間（計画 2j。根拠は仕様「ログイン項目の登録」の実測）。オンにした時（初めての登録）は前のまま
    func testUpdateTimingValues() {
        XCTAssertEqual(LoginItemController.reregisterDelay, 1, "解除の後の待ち")
        XCTAssertEqual(LoginItemController.updateResponseTimeout, 3, "1 回目の応答の待ち")
        XCTAssertEqual(LoginItemController.updateRetryDelay, 3, "止められた後の、解除から登録までの待ち")
        XCTAssertEqual(LoginItemController.responseTimeout, 10, "やり直しの後の応答の待ち（オンにした時の待ちと同じ）")
        XCTAssertEqual(LoginItemController.retryDelay, 5, "オンにした時のやり直しの前の待ち（前のまま）")
        XCTAssertEqual(LoginItemController.updateFinalRetryDelay, 5, "2 回目も来ない時の、3 回目の前の待ち（止められてから 15 秒以上空ける。点検 2j-A）")
        XCTAssertEqual(LoginItemController.pollInterval, 0.25)
        XCTAssertEqual(LoginItemController.updateTiming, .init(firstResponse: 3, retries: [.init(delay: 3, response: 10), .init(delay: 5, response: 10)]))
        XCTAssertEqual(LoginItemController.turnOnTiming, .init(firstResponse: 10, retries: [.init(delay: 5, response: 10)]))
    }

    // 更新の後、1 回目の起動が通る: LaunchServices を更新 → 解除 → 1 秒 → 登録 → 0.5 秒で応答（計画 2j）
    func testUpdateReRegisterPassesOnTheFirstLaunch() async throws {
        let distribution = DistributionStatus()
        let (service, clock, c) = try updated(blocked: 0, distribution: distribution)
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register"], "LaunchServices の更新は解除の前")
        XCTAssertEqual(clock.waits, [1])
        XCTAssertEqual(clock.total, 1.5, accuracy: 0.001)
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。"); XCTAssertFalse(c.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b")
        XCTAssertEqual(distribution.lines.map(\.text), ["ログイン項目: 新しいバージョンの ShareScale Host に切り替えました。"])
        XCTAssertFalse(c.busy)
    }

    // 更新の後、1 回目の起動が macOS に止められる（2026-10-02〜04 実機。時間を空けた更新ではこれまですべて止められた。決め手は分かっていない）: 3 秒で見切り、解除 → 3 秒 → 登録で戻す（計画 2j）
    func testUpdateReRegisterRecoversQuicklyWhenTheFirstLaunchIsBlocked() async throws {
        let distribution = DistributionStatus()
        let (service, clock, c) = try updated(blocked: 1, distribution: distribution)
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register", "unregister", "register"], "LaunchServices の更新は 1 回だけ")
        XCTAssertEqual(clock.waits, [1, 3], "解除の後 1 秒、やり直しの前 3 秒")
        XCTAssertEqual(clock.total, 1 + 3 + 3 + 0.5, accuracy: 0.001, "前は 3 + 10 + 5 + 応答＝約 20 秒")
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。", "やり直しで戻っても「切り替えました」")
        XCTAssertFalse(c.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b", "やり直しで応答すれば記録する")
        XCTAssertEqual(distribution.lines.map(\.mark), [.ok])
    }

    // 更新の後、2 回目も止められた: 解除 → 5 秒 → 3 回目の登録で戻す（止められてから 15 秒以上後。点検 2j-A。
    // 止められた後に通った記録は、どれも止められてから 11 秒以上後の登録だった）
    func testUpdateReRegisterPassesOnTheThirdTry() async throws {
        let distribution = DistributionStatus()
        let (service, clock, c) = try updated(blocked: 2, distribution: distribution)
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register", "unregister", "register", "unregister", "register"])
        XCTAssertEqual(clock.waits, [1, 3, 5], "解除の後 1 秒、2 回目の前 3 秒、3 回目の前 5 秒")
        XCTAssertEqual(clock.total, 1 + 3 + 3 + 10 + 5 + 0.5, accuracy: 0.001, "1 回目の登録から 3 回目の登録までは 21 秒")
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。"); XCTAssertFalse(c.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b", "3 回目で応答すれば記録する")
        XCTAssertEqual(distribution.lines.map(\.mark), [.ok])
    }

    // 更新の後、3 回とも応答が無い: 1 + 3 + 3 + 10 + 5 + 10 ＝ 32 秒で「応答がありません」。記録しない（次に開いた時にもう一度。点検 L）
    func testUpdateReRegisterGivesUpAfterThreeTries() async throws {
        let (service, clock, c) = try updated(blocked: 0, never: true)
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register", "unregister", "register", "unregister", "register"])
        XCTAssertEqual(clock.slept, [1] + Array(repeating: 0.25, count: 12) + [3] + Array(repeating: 0.25, count: 40) + [5] + Array(repeating: 0.25, count: 40),
                       "待ちの順序と値")
        XCTAssertEqual(clock.total, 32, accuracy: 0.001)
        XCTAssertEqual(c.model.result, "ShareScale Host を登録しましたが、応答がありません。「この Mac を接続先にする」をオフにしてからオンにしてください。")
        XCTAssertTrue(c.model.resultIsError)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a", "応答が無ければ記録しない")
        XCTAssertFalse(c.busy)
    }

    // 上限ちょうど（登録から 3 秒）で応答する Host: 1 回目で通る（応答を見てから上限を見る順。点検 2j-B）
    func testUpdateReRegisterAcceptsAnAnswerExactlyAtTheLimit() async throws {
        let (service, clock, c) = try updated(blocked: 0)
        service.onRegister = { clock.registers += 1; clock.startsAfter = clock.total + 3 }   // 3 = `updateResponseTimeout`（`testUpdateTimingValues` が縛る）
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register"])
        XCTAssertEqual(clock.total, 1 + 3, accuracy: 0.001)
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。")
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b")
    }

    // やり直しの登録（2 回目・3 回目）が投げた: そこで止めて「登録できませんでした」。記録しない（再点検 2j）
    func testUpdateReRegisterStopsWhenARetriedRegisterThrows() async throws {
        for failingAt in [2, 3] {
            let (service, clock, c) = try updated(blocked: 2)
            service.onRegister = { [onRegister = service.onRegister] in onRegister(); if clock.registers == failingAt - 1 { service.failRegister = true } }
            await c.startup()
            let expected = ["refresh", "unregister", "register", "unregister", "register", "unregister", "register"].prefix(failingAt == 2 ? 5 : 7)
            XCTAssertEqual(service.calls, Array(expected), "\(failingAt) 回目の登録で止める")
            XCTAssertEqual(c.model.result, "ShareScale Host をログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。")
            XCTAssertTrue(c.model.resultIsError); XCTAssertTrue(c.model.resultDetail?.contains("SMAppServiceErrorDomain") == true)
            XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a", "記録しない")
            XCTAssertFalse(c.busy)
        }
    }

    // 遅いだけの Host（登録から 3.5 秒で応答する）: 3 秒で見切って解除しても、やり直しで戻り、記録する（点検 2j-A）
    func testUpdateReRegisterWithASlowHost() async throws {
        let (service, clock, c) = try updated(blocked: 0)
        service.onRegister = { clock.registers += 1; clock.startsAfter = clock.total + 3.5 }
        await c.startup()
        XCTAssertEqual(service.calls, ["refresh", "unregister", "register", "unregister", "register"])
        XCTAssertEqual(clock.waits, [1, 3])
        XCTAssertEqual(clock.total, 1 + 3 + 3 + 3.5, accuracy: 0.001)
        XCTAssertEqual(c.model.result, "新しいバージョンの ShareScale Host に切り替えました。")
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0b0b")
    }

    // 更新の後、登録したらログイン項目でオフ（requiresApproval）になった: やり直さない（1 回目・やり直しの後のどちらでも。計画 2j）
    func testUpdateReRegisterStopsAtRequiresApproval() async throws {
        let (first, clock1, c1) = try updated(blocked: 0)
        first.statusAfterRegister = .requiresApproval
        await c1.startup()
        XCTAssertEqual(first.calls, ["refresh", "unregister", "register"])
        XCTAssertEqual(clock1.waits, [1]); XCTAssertTrue(c1.model.needsApproval); XCTAssertNil(c1.model.result, "画面には出さない（スイッチの下の説明と同じ手順）")
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a")
        // 1 回目が止められ、やり直しの登録で requiresApproval
        let (second, clock2, c2) = try updated(blocked: 1)
        second.onRegister = { [onRegister = second.onRegister] in onRegister(); second.statusAfterRegister = .requiresApproval }
        await c2.startup()
        XCTAssertEqual(second.calls, ["refresh", "unregister", "register", "unregister", "register"])
        XCTAssertEqual(clock2.waits, [1, 3]); XCTAssertTrue(c2.model.needsApproval)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a")
        // 2 回目も止められ、3 回目の登録で requiresApproval（点検 2j-A）
        let (fourth, clock4, c4) = try updated(blocked: 2)
        fourth.onRegister = { [onRegister = fourth.onRegister] in onRegister(); if clock4.registers == 2 { fourth.statusAfterRegister = .requiresApproval } }
        await c4.startup()
        XCTAssertEqual(fourth.calls, ["refresh", "unregister", "register", "unregister", "register", "unregister", "register"])
        XCTAssertEqual(clock4.waits, [1, 3, 5]); XCTAssertTrue(c4.model.needsApproval)
        XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a")
        // 始めから requiresApproval なら、LaunchServices の更新もしない
        let (third, _, c3) = try updated(blocked: 0)
        third.set(.requiresApproval); c3.refresh()
        await c3.startup()
        XCTAssertEqual(third.calls, [])
    }

    // 取り除きが始まっている・待つ間に始まった: 登録し直さない（計画 2j。「ログイン時に開く」と同じ）
    func testUpdateReRegisterStopsWhenRemovalStarts() async throws {
        // 始めから
        let (before, _, c0) = try updated(blocked: 0)
        c0.lockForRemoval()
        await c0.startup()
        XCTAssertEqual(before.calls, [], "LaunchServices の更新もしない")
        // k 回目の解除の後の待ち（1 秒・3 秒・5 秒）の間に。どの待ちかは、秒数ではなく、何回目の解除の直後に眠ったかで見分ける（点検 2j-B）
        for (k, expected) in [(1, ["refresh", "unregister"]),
                              (2, ["refresh", "unregister", "register", "unregister"]),
                              (3, ["refresh", "unregister", "register", "unregister", "register", "unregister"])] {
            try stateFile.save(AppState(registeredCDHash: "0a0a"))
            let service = FakeLoginItem(.enabled)
            let clock = Clock()
            let distribution = DistributionStatus()
            var c: LoginItemController?
            var flow: UninstallFlow?
            var busyWhileWaiting: [Bool] = []
            var availableWhileWaiting: [Bool] = []
            c = LoginItemController(role: .copy, service: service, stateFile: stateFile, ownCDHash: "0b0b", hostPID: { clock.pid },
                                    sleep: { s in
                                        clock.slept.append(s)
                                        // 待つ間はずっと処理中で、完全な削除を始められない（再点検 2j）
                                        busyWhileWaiting.append(c?.busy ?? false)
                                        availableWhileWaiting.append(flow?.available ?? true)
                                        let calls = service.calls
                                        if calls.last == "unregister", calls.filter({ $0 == "unregister" }).count == k { c?.lockForRemoval() }
                                    },
                                    distribution: distribution, hostEmbedded: { true })
            let targets = ViewerTargets(book: nil, model: ViewerModel(client: nil, displays: { [] }), onSwitch: { _ in })
            flow = UninstallFlow(role: .copy, paths: AppPaths(home: dir), targets: targets, loginItems: c) {
                UninstallPorts(loginItem: FakeLoginItem(.notRegistered), hostState: { .stopped }, hostProcessRunning: { false }, askHostToQuit: {},
                               unpair: { _ in .alreadyRemoved }, trash: { _ in }, removeDefaults: { _ in })
            }
            XCTAssertEqual(flow?.available, true, "始める前は押せる")
            await c?.startup()
            XCTAssertFalse(busyWhileWaiting.isEmpty)
            XCTAssertEqual(busyWhileWaiting, Array(repeating: true, count: busyWhileWaiting.count), "待つ間はずっと処理中（\(k)）")
            XCTAssertEqual(availableWhileWaiting, Array(repeating: false, count: availableWhileWaiting.count), "待つ間は完全な削除を押せない（\(k)）")
            XCTAssertEqual(service.calls, expected, "\(k) 回目の解除の後の待ちの間に取り除きが始まった")
            XCTAssertNil(c?.model.result); XCTAssertEqual(distribution.lines, [], "結果は取り除きの窓が出す")
            XCTAssertEqual(c?.busy, false)
            XCTAssertEqual(stateFile.load().state.registeredCDHash, "0a0a")
        }
    }

    // 「ログイン時に ShareScale を開く」も、更新（CDHash が変わった）の後は LaunchServices を更新 → 解除 → 3 秒 → 登録（点検 2f-2・計画 2j）
    func testOpenAtLoginReRegistersAfterAnUpdate() async throws {
        let app = FakeLoginItem(.enabled)
        var slept: [Double] = []
        try stateFile.save(AppState(registeredAppCDHash: "0a0a"))
        let c = OpenAtLoginController(role: .copy, service: app, stateFile: stateFile, ownCDHash: "0b0b", sleep: { slept.append($0) })
        await c.startup()
        XCTAssertEqual(app.calls, ["refresh", "unregister", "register"], "LaunchServices の更新は解除の前（計画 2j）"); XCTAssertEqual(slept, [3])
        XCTAssertEqual(stateFile.load().state.registeredAppCDHash, "0b0b")
        await c.startup()
        XCTAssertEqual(app.calls, ["refresh", "unregister", "register"], "同じ CDHash なら登録し直さない（LaunchServices の更新もしない）")
        // スイッチでオン・オフした時にも記録する・消す
        c.setEnabled(false)
        XCTAssertNil(stateFile.load().state.registeredAppCDHash)
        c.setEnabled(true)
        XCTAssertEqual(stateFile.load().state.registeredAppCDHash, "0b0b")
        // 登録していない・開発の組み立てでは何もしない
        let off = FakeLoginItem(.notRegistered)
        await OpenAtLoginController(role: .copy, service: off, stateFile: stateFile, ownCDHash: "0c0c", sleep: { _ in }).startup()
        let dev = FakeLoginItem(.enabled)
        await OpenAtLoginController(role: .development, service: dev, stateFile: stateFile, ownCDHash: "0c0c", sleep: { _ in }).startup()
        XCTAssertEqual(off.calls + dev.calls, [])
        // ログイン項目でオフにされている（requiresApproval）時は、登録も解除もしない（再点検 2f-2。一時の写しで条件に requiresApproval を足すと落ちることを確かめた）
        let approval = FakeLoginItem(.requiresApproval)
        await OpenAtLoginController(role: .copy, service: approval, stateFile: stateFile, ownCDHash: "0e0e", sleep: { _ in }).startup()
        XCTAssertEqual(approval.calls, [])
        // 登録し直しを待つ間は完全な削除を始められず、待つ間に取り除きが始まったら登録し直さない（再点検 2f-2）
        try stateFile.save(AppState(registeredAppCDHash: "0a0a"))
        let during = FakeLoginItem(.enabled)
        var flow: UninstallFlow?
        var availableWhileWaiting: Bool?
        var controller: OpenAtLoginController?
        controller = OpenAtLoginController(role: .copy, service: during, stateFile: stateFile, ownCDHash: "0b0b", sleep: { _ in
            availableWhileWaiting = flow?.available
            controller?.lockForRemoval()
        })
        let targets = ViewerTargets(book: nil, model: ViewerModel(client: nil, displays: { [] }), onSwitch: { _ in })
        flow = UninstallFlow(role: .copy, paths: AppPaths(home: dir), targets: targets, openAtLogin: controller) {
            UninstallPorts(loginItem: FakeLoginItem(.notRegistered), hostState: { .stopped }, hostProcessRunning: { false }, askHostToQuit: {},
                           unpair: { _ in .alreadyRemoved }, trash: { _ in }, removeDefaults: { _ in })
        }
        XCTAssertEqual(flow?.available, true)
        await controller?.startup()
        XCTAssertEqual(availableWhileWaiting, false, "待つ間は完全な削除を押せない")
        XCTAssertEqual(during.calls, ["refresh", "unregister"], "待つ間に取り除きが始まったら登録し直さない")
        // 登録し直せなかったら理由を出す
        let failing = FakeLoginItem(.enabled); failing.failRegister = true
        let f = OpenAtLoginController(role: .copy, service: failing, stateFile: stateFile, ownCDHash: "0d0d", sleep: { _ in })
        await f.startup()
        XCTAssertEqual(f.model.result, "ログイン時に開く設定を、新しいバージョンで登録し直せませんでした。スイッチをオフにしてからオンにしてください。")
    }

    // LaunchServices の更新（計画 2j）: URL の順にすべて呼び、失敗しても続ける。返事が無ければ上限で待つのをやめ、
    // 見切った後は残りを始めない（点検 2j-B）。実物の LaunchServices には触れない
    func testLaunchServicesRefreshCallsEveryURLAndNeverWaitsLong() async throws {
        let app = URL(fileURLWithPath: "/tmp/x/ShareScale.app")
        let urls = [app.appendingPathComponent(EmbeddedHost.relativePath), app]
        let seen = URLRecorder()
        let r = await LaunchServicesRefresh.run(urls, limit: 5) { u in seen.add(u); return u == urls[0] ? -10814 : 0 }
        XCTAssertEqual(seen.all, urls, "順に、すべて")
        XCTAssertEqual(r, [-10814, 0], "1 つ目が失敗しても 2 つ目を呼ぶ")
        // 1 つ目の返事が無い（LaunchServices が止まっている）: 上限で待つのをやめ、待ちきれなかったものは nil。2 つ目は、1 つ目が戻った後も始めない
        let gate = DispatchSemaphore(value: 0)
        let stalled = URLRecorder()
        let start = Date()
        let slow = await LaunchServicesRefresh.run(urls, limit: 0.2) { u in stalled.add(u); _ = gate.wait(timeout: .now() + 3); return 0 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "上限（0.2 秒）で待つのをやめる")
        XCTAssertEqual(slow, [nil, nil])
        gate.signal()
        try await Task.sleep(nanoseconds: 300_000_000)   // 1 つ目の呼び出しが戻り、ループが次へ進む時間
        XCTAssertEqual(stalled.all, [urls[0]], "見切った後は、2 つ目を始めない（後に続く解除・登録と重ねない）")
        gate.signal()
        let none = await LaunchServicesRefresh.run([], limit: 5) { _ in 0 }
        XCTAssertEqual(none, [])
        XCTAssertEqual(LaunchServicesRefresh.timeout, 2, "実物の上限")
        // 実物が更新させるもの（URL を作るだけで、呼ばない）: Host のログイン項目は、中にある時だけ Host.app（先に。リンクは認めない。点検 2j-A・B）とアプリ。
        // ログイン時に開くのはアプリ
        XCTAssertEqual(SystemLoginItemService(appBundle: app).launchServicesURLs, [app], "中に Host が無い")
        XCTAssertEqual(SystemAppLoginItemService(appBundle: app).launchServicesURLs, [app])
        let bundle = support.appendingPathComponent("ShareScale.app")
        let host = bundle.appendingPathComponent(EmbeddedHost.relativePath)
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "io.github.taki-0105a.ShareScale.Host"], format: .xml, options: 0)
        try plist.write(to: host.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(SystemLoginItemService(appBundle: bundle).launchServicesURLs.map(\.path), [host.path, bundle.path], "中に Host がある（Host.app を先に）")
        let linked = support.appendingPathComponent("Linked.app")
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("Contents/Library/LoginItems"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(EmbeddedHost.relativePath), withDestinationURL: host)
        XCTAssertEqual(SystemLoginItemService(appBundle: linked).launchServicesURLs, [linked], "Host.app がリンクなら渡さない")
    }

    func testRolesAndFailures() async {
        // Homebrew 側・それ以外の場所では押せない
        let h = HomebrewBundle(prefix: "/opt/homebrew", realPath: "/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app")
        let brew = controller(FakeLoginItem(.notRegistered), role: .homebrew(h), clock: Clock())
        XCTAssertFalse(brew.model.canToggle)
        XCTAssertEqual(brew.model.note, "ログイン項目は ~/Applications/ShareScale.app からだけ登録できます。")
        await brew.setEnabled(true)
        // 開発の組み立ては押せるが注意を出す
        let dev = controller(FakeLoginItem(.notRegistered), role: .development, clock: Clock())
        XCTAssertTrue(dev.model.canToggle)
        XCTAssertEqual(dev.model.note, "開発用のビルドから登録しています（ビルドし直すと動かなくなります）。ふだんは ~/Applications/ShareScale.app から登録してください。")
        // 中に Host が無い（バンドルの中を見て判断する）
        let missing = controller(FakeLoginItem(.notFound), clock: Clock(), hostEmbedded: false)
        XCTAssertFalse(missing.model.canToggle); XCTAssertTrue(missing.model.note.contains("入れ直して"))
        await missing.setEnabled(true)
        // 登録・解除の失敗: 本文は何をすればよいか、生の理由は「詳細をコピー」
        let failing = FakeLoginItem(.notRegistered); failing.failRegister = true
        let c = controller(failing, clock: Clock())
        await c.setEnabled(true)
        XCTAssertEqual(c.model.result, "ShareScale Host をログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。")
        XCTAssertTrue(c.model.resultIsError); XCTAssertNotNil(c.model.resultDetail)
        XCTAssertNil(stateFile.load().state.registeredCDHash, "登録できなければ記録しない")
        let stuck = FakeLoginItem(.enabled); stuck.failUnregister = true
        let d = controller(stuck, clock: Clock())
        await d.setEnabled(false)
        XCTAssertEqual(d.model.result, "ShareScale Host の登録を解除できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。")
        XCTAssertTrue(d.model.isOn)
        // 状態を読めない
        XCTAssertEqual(controller(FakeLoginItem(.unknown), clock: Clock()).model.note, "ログイン項目の状態を読み取れません。システム設定 › 一般 › ログイン項目を確認してください。")
        // 取り除きの間と後は押せない（点検 F）
        let locked = FakeLoginItem(.notRegistered)
        let l = controller(locked, clock: Clock())
        l.lockForRemoval()
        XCTAssertFalse(l.model.canToggle)
        await l.setEnabled(true); await l.startup()
        XCTAssertEqual(locked.calls, [])
        l.unlockAfterRemoval()
        XCTAssertTrue(l.model.canToggle)
        // 開発の組み立ては、自分のバンドルにほかの人が書き込めるなら登録しない（点検 I）
        let devService = FakeLoginItem(.notRegistered)
        let unsafe = LoginItemController(role: .development, service: devService, stateFile: stateFile, ownCDHash: "0a", hostPID: { nil }, sleep: { _ in },
                                         ownBundleProblem: { .writableByOthers("/Users/x/src/build/ShareScale.app") }, hostEmbedded: { true })
        await unsafe.setEnabled(true)
        XCTAssertEqual(devService.calls, [], "登録しない")
        XCTAssertEqual(unsafe.model.result, "このビルドのフォルダにほかの人が書き込めるため、登録しません。ビルドしたフォルダの所有者とアクセス権を確認してください。")
        XCTAssertEqual(unsafe.model.resultDetail, "writable by others: /Users/x/src/build/ShareScale.app")
        let copyService = FakeLoginItem(.notRegistered)
        let copyClock = Clock(); copyClock.startsAfter = 0
        let copyC = LoginItemController(role: .copy, service: copyService, stateFile: stateFile, ownCDHash: "0a", hostPID: { copyClock.pid },
                                        sleep: { _ in copyClock.pid = 7 }, ownBundleProblem: { .writableByOthers("x") }, hostEmbedded: { true })
        await copyC.setEnabled(true)
        XCTAssertEqual(copyService.calls, ["register"], "複製は ~/Applications の確かめを置き換えの時に済ませているので、この確かめは開発の組み立てだけ")
    }
}
