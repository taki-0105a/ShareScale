import Foundation

/// 裏での取り直しの方針（計画 2f-2。2f-1「2f-2 への注記」: 通知の (b)「ほかの Mac が変えた」と (c)「接続できなくなった」を、
/// ShareScale が前面にない時にも拾う）。純粋な関数。通信と電池に配慮して、次の時だけ取り直す:
/// - 通知がオンで、(b) か (c) を選んでいる（通知のためだけに行うので、通知しないなら取り直さない。(a) は自分の操作の結果なので要らない）
/// - ShareScale が前面にない（前面では、前面に来た時・更新・カードのクリックで取り直している。前面では通知もしない）
/// - Mac が眠っていない（システムのスリープ・画面のスリープのどちらでもない）。**眠りから戻って 60 秒の間も取り直さない**
///   （ネットワークが戻る前に取り直すと「接続できなくなりました」の誤報になる。点検 2f-2）
/// - 接続先がある
/// 間隔は 60 秒。直前の取り直しが失敗した（接続できない）後と、低電力モードの間は 300 秒（点検 2f-2）
public enum BackgroundRefreshPolicy {
    public static let interval: Duration = .seconds(60)
    public static let afterFailure: Duration = .seconds(300)
    public static let lowPower: Duration = .seconds(300)
    /// 眠りから戻った後、取り直さない間
    public static let afterWake: Duration = .seconds(60)
    /// 条件を満たさない時に、もう一度確かめるまでの間隔（取り直しはしない。条件を読むだけ）
    public static let recheck: Duration = .seconds(30)

    public struct Conditions: Equatable, Sendable {
        public var notificationsOn: Bool
        public var kinds: Set<ChangeNotificationKind>
        public var appActive: Bool
        /// システムがスリープに入る（`willSleep`〜`didWake`）
        public var systemAsleep: Bool
        /// 画面がスリープしている（`screensDidSleep`〜`screensDidWake`）
        public var screensAsleep: Bool
        /// 眠りから戻って `afterWake` の間
        public var wokeRecently: Bool
        /// 低電力モード（`ProcessInfo.isLowPowerModeEnabled`）
        public var lowPowerMode: Bool
        public var hasTarget: Bool
        public var lastFailed: Bool
        public init(notificationsOn: Bool, kinds: Set<ChangeNotificationKind>, appActive: Bool, systemAsleep: Bool = false, screensAsleep: Bool = false,
                    wokeRecently: Bool = false, lowPowerMode: Bool = false, hasTarget: Bool, lastFailed: Bool) {
            self.notificationsOn = notificationsOn; self.kinds = kinds; self.appActive = appActive; self.systemAsleep = systemAsleep
            self.screensAsleep = screensAsleep; self.wokeRecently = wokeRecently; self.lowPowerMode = lowPowerMode
            self.hasTarget = hasTarget; self.lastFailed = lastFailed
        }
    }

    /// 次に取り直すまでの間隔（nil なら取り直さない）
    public static func delay(_ c: Conditions) -> Duration? {
        guard c.notificationsOn, !c.kinds.isDisjoint(with: [.changedByOther, .connectionLost]), !c.appActive,
              !c.systemAsleep, !c.screensAsleep, !c.wokeRecently, c.hasTarget else { return nil }
        if c.lastFailed { return afterFailure }
        return c.lowPowerMode ? lowPower : interval
    }
}

/// 眠りの様子（`NSWorkspace` の 4 つの知らせから。システムと画面を別々に持ち、どちらかが眠っていれば眠っている。点検 2f-2）
public struct SleepState: Equatable, Sendable {
    public var systemAsleep = false
    public var screensAsleep = false
    /// 最後に戻った時刻（システムか画面のどちらか）
    public var lastWake: ContinuousClock.Instant?
    public init() {}

    public enum Event: Sendable { case willSleep, didWake, screensDidSleep, screensDidWake }
    public mutating func handle(_ e: Event, at now: ContinuousClock.Instant) {
        switch e {
        case .willSleep: systemAsleep = true
        case .didWake: systemAsleep = false; lastWake = now
        case .screensDidSleep: screensAsleep = true
        case .screensDidWake: screensAsleep = false; lastWake = now
        }
    }
    /// 戻って `BackgroundRefreshPolicy.afterWake` の間か
    public func wokeRecently(at now: ContinuousClock.Instant) -> Bool {
        guard let w = lastWake else { return false }
        return now - w < BackgroundRefreshPolicy.afterWake
    }
}

/// 裏での取り直しを回す（`BackgroundRefreshPolicy` に従う。画面に結び付かない Task。`start` は 1 回だけ効く）。
/// 待った後にもう一度条件を確かめてから取り直す（待つ間に前面に来た・眠った・通知をオフにした時は取り直さない）。
/// 待つ間は自分を強く持たない（条件と待つ口だけを持って待ち、待った後に弱い参照から取り直す。点検 2f-2）
@MainActor
public final class BackgroundRefresher {
    private let conditions: () -> BackgroundRefreshPolicy.Conditions
    private let refresh: () async -> Void
    private let sleep: (Duration) async -> Void
    nonisolated(unsafe) private var task: Task<Void, Never>?

    /// - `refresh`: 実物は `ViewerModel.refresh()`（間引きつき。`.refresh` の結果として通知の判定に渡る）
    /// - `sleep`: 待つ（試験では待たずに記録する）
    public init(conditions: @escaping () -> BackgroundRefreshPolicy.Conditions, refresh: @escaping () async -> Void,
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.conditions = conditions; self.refresh = refresh; self.sleep = sleep
    }
    deinit { task?.cancel() }

    public var isRunning: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                // 待つ前に次の間隔と待つ口だけを取り出し、自分の強い参照は持たずに待つ
                guard let (delay, sleep) = self.map({ (BackgroundRefreshPolicy.delay($0.conditions()), $0.sleep) }) else { return }
                await sleep(delay ?? BackgroundRefreshPolicy.recheck)
                guard delay != nil, !Task.isCancelled, let me = self, BackgroundRefreshPolicy.delay(me.conditions()) != nil else { continue }
                await me.refresh()
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
}
