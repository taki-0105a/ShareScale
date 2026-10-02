import XCTest
@testable import ShareScaleCore
import ShareScaleProtocol

/// 偽の通知の口（実物の `UNUserNotificationCenter` に触れない）。許可を求めた回数と送った通知を記録する
final class FakePoster: NotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NotificationAuthorization
    private var _requests = 0
    private var _posted: [PlannedNotification] = []
    let grant: Bool
    init(_ status: NotificationAuthorization, grant: Bool = true) { _status = status; self.grant = grant }
    var requests: Int { lock.withLock { _requests } }
    var posted: [PlannedNotification] { lock.withLock { _posted } }
    func authorization() async -> NotificationAuthorization { lock.withLock { _status } }
    func requestAuthorization() async -> Bool {
        lock.withLock { _requests += 1; _status = grant ? .authorized : .denied }
        return grant
    }
    func post(_ n: PlannedNotification) async { lock.withLock { _posted.append(n) } }
}

/// 最初の許可の読み取りを `release` まで止める偽の口（読み直しとスイッチの操作を入れ違えるため）。2 回目からは `later` をすぐ返す
final class GatedPoster: NotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<NotificationAuthorization, Never>?
    private var first = true
    let later: NotificationAuthorization
    init(later: NotificationAuthorization) { self.later = later }
    var isWaiting: Bool { lock.withLock { waiting != nil } }
    func authorization() async -> NotificationAuthorization {
        let gate = lock.withLock { () -> Bool in defer { first = false }; return first }
        guard gate else { return later }
        return await withCheckedContinuation { c in lock.withLock { waiting = c } }
    }
    func release(_ a: NotificationAuthorization) {
        let c = lock.withLock { () -> CheckedContinuation<NotificationAuthorization, Never>? in defer { waiting = nil }; return waiting }
        c?.resume(returning: a)
    }
    func requestAuthorization() async -> Bool { true }
    func post(_ n: PlannedNotification) async {}
}

/// 変わった時の通知（計画 2f-1 案 7）。判定は純粋な関数、許可と送り出しは偽の口
@MainActor
final class ChangeNotificationsTests: XCTestCase {
    override func setUp() { AppLanguage.current = .ja }
    let all = Set(ChangeNotificationKind.allCases)

    func result(_ trigger: ViewerResult.Trigger = .refresh, before: RemoteState? = connected(), beforeFailure: ViewerFailure? = nil,
                after: RemoteState? = connected(), failure: ViewerFailure? = nil) -> ViewerResult {
        ViewerResult(trigger: trigger, targetName: "書斎の Mac", previousState: before, previousFailure: beforeFailure, state: after, failure: failure)
    }
    func other(at: Int64, mode: Mode = .twoX) -> RemoteState {
        RemoteState(payload(mode: mode, vd: StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .twoX, source: .signature),
                            setBy: StatusPayload.SetBy(byYou: false, at: at)))
    }

    func testPlannerDecidesByTheTransition() {
        // (a) 切り替えの結果（自分の操作）
        let ok = NotificationPlanner.plan(result(.apply(.x2), after: connected(mode: .x2, scaling: .x2)), enabled: all, appActive: false)
        XCTAssertEqual(ok, PlannedNotification(kind: .scaleSwitched, title: "書斎の Mac", body: "表示倍率を 2x Retina に切り替えました。"))
        XCTAssertEqual(ok?.identifier, "io.github.taki-0105a.ShareScale.scaleSwitched")
        let later = NotificationPlanner.plan(result(.apply(.x1), after: RemoteState(payload(session: false, vd: nil))), enabled: all, appActive: false)
        XCTAssertEqual(later?.body, "画面共有を始めると、自動で 1x 等倍に切り替わります。")
        let paused = NotificationPlanner.plan(result(.apply(.x2), failure: .paused), enabled: all, appActive: false)
        XCTAssertEqual(paused?.body, "表示倍率を 2x Retina に切り替えられませんでした。ShareScale を開くと、確認することが表示されます。")
        let mismatch = NotificationPlanner.plan(result(.apply(.x2), after: connected(mode: .x2, scaling: .x1)), enabled: all, appActive: false)
        XCTAssertEqual(mismatch?.kind, .scaleSwitched); XCTAssertTrue(mismatch?.body.contains("切り替えられませんでした") == true)
        XCTAssertNil(NotificationPlanner.plan(result(.refresh), enabled: all, appActive: false), "取り直しで変わらなければ何も出さない")
        // (c) 接続できなくなった: 直前まで接続できていた時だけ。続く間は出さない
        let lost = NotificationPlanner.plan(result(after: connected(), failure: .unreachable), enabled: all, appActive: false)
        XCTAssertEqual(lost?.kind, .connectionLost)
        XCTAssertEqual(lost?.body, "接続先に接続できなくなりました。ShareScale を開くと、確認することが表示されます。")
        XCTAssertNil(NotificationPlanner.plan(result(beforeFailure: .unreachable, failure: .unreachable), enabled: all, appActive: false), "同じ状態の間は 1 回")
        XCTAssertNil(NotificationPlanner.plan(result(before: nil, failure: .unreachable), enabled: all, appActive: false), "起動・切り替えの直後（前を知らない）は出さない")
        XCTAssertEqual(NotificationPlanner.plan(result(failure: .timedOut), enabled: all, appActive: false)?.kind, .connectionLost)
        XCTAssertNil(NotificationPlanner.plan(result(failure: .notPaired), enabled: [.connectionLost], appActive: false), "接続できない失敗だけ")
        XCTAssertEqual(NotificationPlanner.plan(result(.apply(.x2), failure: .unreachable), enabled: all, appActive: false)?.kind, .connectionLost,
                       "切り替えで接続できなくなった時は、接続できなくなった方を出す（1 回に 1 つ）")
        XCTAssertEqual(NotificationPlanner.plan(result(.apply(.x2), failure: .unreachable), enabled: [.scaleSwitched], appActive: false)?.kind, .scaleSwitched)
        // Host が断った結果（一時停止中・処理中）は「接続できなくなった」ではない（計画 2i。接続はできている）
        for refusal in [ViewerFailure.paused, .busy] {
            XCTAssertNil(NotificationPlanner.plan(result(.apply(.x2), failure: refusal), enabled: [.connectionLost, .changedByOther], appActive: false), "\(refusal)")
            XCTAssertNil(NotificationPlanner.plan(result(failure: refusal), enabled: all, appActive: false), "\(refusal)")
            XCTAssertEqual(NotificationPlanner.plan(result(.apply(.x2), failure: refusal), enabled: all, appActive: false)?.kind, .scaleSwitched, "切り替えられなかった、は出す")
            // 断られた後に接続できなくなった: 直前まで接続できていたので、1 回出す
            XCTAssertEqual(NotificationPlanner.plan(result(beforeFailure: refusal, failure: .unreachable), enabled: all, appActive: false)?.kind, .connectionLost, "\(refusal)")
            // 手元の状態を捨てた後（届かなくなった後に断られた時）でも、断られた＝接続はできていたので、出す（再点検 2i）
            XCTAssertEqual(NotificationPlanner.plan(result(before: nil, beforeFailure: refusal, failure: .unreachable), enabled: all, appActive: false)?.kind, .connectionLost, "\(refusal)")
        }
        XCTAssertNil(NotificationPlanner.plan(result(beforeFailure: .timedOut, failure: .unreachable), enabled: all, appActive: false), "接続できない失敗が続く間は出さない")
        XCTAssertNil(NotificationPlanner.plan(result(beforeFailure: .notPaired, failure: .unreachable), enabled: all, appActive: false))
        // (b) ほかの Mac が変えた: 新しく見た時だけ
        let changed = NotificationPlanner.plan(result(before: connected(), after: other(at: 10)), enabled: all, appActive: false)
        XCTAssertEqual(changed?.body, "ほかの接続元の Mac が表示倍率を 2x Retina に変更しました。")
        XCTAssertNil(NotificationPlanner.plan(result(before: other(at: 10), after: other(at: 10)), enabled: all, appActive: false), "同じ変更は 1 回")
        XCTAssertEqual(NotificationPlanner.plan(result(before: other(at: 10), after: other(at: 20)), enabled: all, appActive: false)?.kind, .changedByOther, "もう一度変えた")
        XCTAssertNil(NotificationPlanner.plan(result(before: nil, after: other(at: 10)), enabled: all, appActive: false), "前を知らない時は出さない")
        XCTAssertEqual(NotificationPlanner.plan(result(before: connected(), after: other(at: 10, mode: .off)), enabled: all, appActive: false)?.body,
                       "ほかの接続元の Mac が、表示倍率を自動で保つのをオフにしました。")
        // 前面にある時・選んでいない種類は出さない
        XCTAssertNil(NotificationPlanner.plan(result(failure: .unreachable), enabled: all, appActive: true))
        XCTAssertNil(NotificationPlanner.plan(result(failure: .unreachable), enabled: [.scaleSwitched, .changedByOther], appActive: false))
        // 英語。秘密・アドレスを含めない
        AppLanguage.current = .en
        XCTAssertEqual(NotificationPlanner.plan(result(.apply(.x1), after: connected()), enabled: all, appActive: false)?.body, "Switched the display scale to 1x Standard.")
        XCTAssertEqual(NotificationPlanner.plan(result(.apply(.x1), after: RemoteState(payload(session: false, vd: nil))), enabled: all, appActive: false)?.body,
                       "The display scale switches to 1x Standard when Screen Sharing starts.")
        // 題名（接続先の名前）も制御文字を除いて切り詰める
        let raw = ViewerResult(trigger: .apply(.x1), targetName: "Stu\u{7}dio" + String(repeating: "x", count: 200), previousState: connected(), previousFailure: nil,
                               state: connected(), failure: nil)
        XCTAssertEqual(NotificationPlanner.plan(raw, enabled: all, appActive: false)?.title.utf8.count, 128)
        XCTAssertFalse(NotificationPlanner.plan(raw, enabled: all, appActive: false)?.title.contains("\u{7}") ?? true)
        for kind in ChangeNotificationKind.allCases { XCTAssertFalse(kind.settingLabel.isEmpty) }
    }

    func testModelReportsEachResultWithThePreviousStateOfTheSameTarget() async {
        let fake = FakeTarget(.success(connected()))
        let vm = ViewerModel(client: fake, displays: { [lg] }, targetLabel: "書斎の Mac")
        var results: [ViewerResult] = []
        vm.onResult = { results.append($0) }
        await vm.refresh()
        guard hasCount(results, 1) else { return }
        XCTAssertEqual(results[0].trigger, .refresh); XCTAssertNil(results[0].previousState)
        XCTAssertEqual(results[0].targetName, "書斎の Mac")
        fake.setResult = .success(connected(mode: .x2, scaling: .x2))
        await vm.apply(.x2)
        guard hasCount(results, 2) else { return }
        XCTAssertEqual(results[1].trigger, .apply(.x2))
        XCTAssertEqual(results[1].previousState, connected()); XCTAssertEqual(results[1].state?.mode, .x2)
        fake.statusResult = .failure(.unreachable)
        await vm.refresh(force: true)
        guard hasCount(results, 3) else { return }
        XCTAssertEqual(results[2].failure, .unreachable); XCTAssertNil(results[2].previousFailure)
        vm.updateClient(FakeTarget(.success(connected())), targetLabel: "Air")
        await vm.refresh()
        guard hasCount(results, 4) else { return }
        XCTAssertNil(results[3].previousState, "接続先を切り替えたら前の状態は持ち越さない"); XCTAssertNil(results[3].previousFailure)
    }

    // 成功 → 届かない → 断られた（手元の状態を捨てる）→ 届かない → 届かない: 「接続できなくなりました」は、届かなくなるたびに 1 回ずつ
    // （再点検 2i。状態を捨てた経路で、2 回目が出なくなっていた）。届かない状態が続く間は、重ねて出さない
    func testConnectionLostFiresOnceEachTimeEvenAfterTheStaleStateWasDropped() async {
        let fake = FakeTarget(.success(connected()))
        let vm = ViewerModel(client: fake, displays: { [lg] }, targetLabel: "書斎の Mac")
        var kinds: [ChangeNotificationKind?] = []
        vm.onResult = { kinds.append(NotificationPlanner.plan($0, enabled: [.connectionLost], appActive: false)?.kind) }
        await vm.refresh()
        fake.statusResult = .failure(.unreachable)
        await vm.refresh(force: true)
        await vm.refresh(force: true)
        fake.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertNil(vm.state, "届かなくなった後に断られたので、古い状態は捨てている")
        await vm.refresh(force: true)
        await vm.refresh(force: true)
        await vm.refresh(force: true)
        XCTAssertEqual(kinds, [nil, .connectionLost, nil, nil, .connectionLost, nil, nil],
                       "成功・届かない（出す）・届かない・断られた・届かない（出す）・届かない・届かない")
        // 起動の直後（前を知らない）と、接続できない失敗が続く間は、今までどおり出さない
        let never = ViewerModel(client: FakeTarget(.failure(.unreachable)), displays: { [lg] }, targetLabel: "書斎の Mac")
        var first: [ChangeNotificationKind?] = []
        never.onResult = { first.append(NotificationPlanner.plan($0, enabled: [.connectionLost], appActive: false)?.kind) }
        await never.refresh(); await never.refresh(force: true)
        XCTAssertEqual(first, [nil, nil])
    }

    // 読み直しの途中でスイッチを操作したら、その前に始めた読み直しの結果（古い）は捨てる（点検 2f-1 の再点検）
    func testStaleAuthorizationReadIsDropped() async {
        let store = MemoryStore()
        let poster = GatedPoster(later: .authorized)
        let n = ViewerNotifications(preferences: NotificationPreferences(store: store), poster: poster, appActive: { false })
        let refresh = Task { await n.refreshAuthorization() }
        await waitFor(2) { poster.isWaiting }
        XCTAssertTrue(poster.isWaiting)
        await n.setEnabled(true)                  // 読み直しを待つ間にオンにした（許可あり）
        XCTAssertTrue(n.enabled)
        poster.release(.denied)                   // 前に始めた読み直しが、古い「許可なし」を返す
        await refresh.value
        XCTAssertTrue(n.enabled, "古い読み取りでスイッチをオフに戻さない")
        XCTAssertEqual(n.authorization, .authorized); XCTAssertEqual(store.string(forKey: "notify.enabled"), "1")
    }

    func testTurningOnAsksOnceAndDeniedStaysOff() async {
        let store = MemoryStore()
        let poster = FakePoster(.notDetermined, grant: true)
        let n = ViewerNotifications(preferences: NotificationPreferences(store: store), poster: poster, appActive: { false })
        XCTAssertFalse(n.enabled, "既定はオフ"); XCTAssertEqual(n.kinds, all, "種類は既定ですべて")
        XCTAssertNil(n.handle(result(failure: .unreachable)), "オフの時は出さない")
        XCTAssertEqual(poster.posted, [])
        XCTAssertEqual(poster.requests, 0, "起動しただけでは許可を求めない")
        await n.setEnabled(true)
        XCTAssertTrue(n.enabled); XCTAssertEqual(poster.requests, 1); XCTAssertEqual(store.string(forKey: "notify.enabled"), "1")
        await n.setEnabled(false); await n.setEnabled(true)
        XCTAssertEqual(poster.requests, 1, "許可が決まった後は求めない")
        n.setKind(.changedByOther, false)
        XCTAssertEqual(store.string(forKey: "notify.changedByOther"), "0")
        XCTAssertEqual(ViewerNotifications(preferences: NotificationPreferences(store: store), poster: poster, appActive: { false }).kinds, [.scaleSwitched, .connectionLost],
                       "設定は環境設定に残る")
        await n.handle(result(failure: .unreachable))?.value
        XCTAssertEqual(poster.posted.map(\.kind), [.connectionLost])
        XCTAssertNil(n.model.problem)
        // (b) ほかの Mac が変えた は、裏での取り直しを入れた 2f-2 で設定に戻した（外していれば送らず、オンなら送る）
        XCTAssertNil(n.handle(result(before: connected(), after: other(at: 10))), "外した種類は送らない")
        n.setKind(.changedByOther, true)
        await n.handle(result(before: connected(), after: other(at: 10)))?.value
        XCTAssertEqual(poster.posted.map(\.kind), [.connectionLost, .changedByOther])
        XCTAssertEqual(n.model.kinds.keys.sorted { $0.rawValue < $1.rawValue }, [.changedByOther, .connectionLost, .scaleSwitched], "設定には (a)(b)(c)")
        // 前面にある時は送らない（`appActive` を渡している）
        let front = ViewerNotifications(preferences: NotificationPreferences(store: store), poster: poster, appActive: { true })
        XCTAssertTrue(front.enabled)
        XCTAssertNil(front.handle(result(failure: .unreachable)))
        // 後からシステム設定で許可を取り消した: 読み直すとスイッチはオフに戻り、保存される
        let revoked = FakePoster(.denied)
        let r2 = ViewerNotifications(preferences: NotificationPreferences(store: store), poster: revoked, appActive: { false })
        XCTAssertTrue(r2.enabled)
        await r2.refreshAuthorization()
        XCTAssertFalse(r2.enabled); XCTAssertEqual(store.string(forKey: "notify.enabled"), "0")
        XCTAssertNotNil(r2.model.problem)
        // 許可されなかった → オフのまま、システム設定で許可するよう案内
        let deniedStore = MemoryStore()
        let denied = ViewerNotifications(preferences: NotificationPreferences(store: deniedStore), poster: FakePoster(.notDetermined, grant: false), appActive: { false })
        await denied.setEnabled(true)
        XCTAssertFalse(denied.enabled); XCTAssertEqual(deniedStore.string(forKey: "notify.enabled"), "0")
        XCTAssertEqual(denied.model.problem, "通知が許可されていません。システム設定 › 通知で ShareScale の通知を許可してから、もう一度オンにしてください。")
        // バンドルの外（`swift run`）では使えない
        let outside = ViewerNotifications(preferences: NotificationPreferences(store: MemoryStore()), poster: FakePoster(.unavailable), appActive: { false })
        await outside.refreshAuthorization()
        XCTAssertFalse(outside.model.canToggle)
        await outside.setEnabled(true)
        XCTAssertFalse(outside.enabled)
    }
}
