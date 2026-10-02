import Combine
import Foundation
import ShareScaleProtocol

/// 変わった時の通知（計画 2f-1 案 7）。既定はオフ。オンにした時に初めて通知の許可を求める（利用者の操作から）。
/// 知らせるもの（それぞれ選べる）:
/// - (a) 表示倍率を切り替えた（自分の操作の結果。成功／失敗）
/// - (b) ほかの接続元の Mac が表示倍率を変えた（`set_by.who == "other"` を新しく見た時だけ。同じ接続先で前の状態を知っている時）
/// - (c) 接続先に接続できなくなった（直前まで接続できていた時だけ。接続できない状態が続く間は 1 回）
/// ShareScale が前面にある時は出さない（画面の案内で足りる）。通知の文は接続先の名前だけを含め、アドレス・秘密は入れない。
/// 判定は純粋な関数 `NotificationPlanner`、通知の実物は口 `NotificationPosting`（試験では差し替える）
public enum ChangeNotificationKind: String, CaseIterable, Sendable {
    case scaleSwitched, changedByOther, connectionLost

    /// 設定で選べる（送る）種類。(b) ほかの Mac が変えた は、2f-1 では前面にない時に見つけられなかったので出さなかったが、
    /// 2f-2 で裏での取り直し（`BackgroundRefreshPolicy`）を入れたので戻した
    public static let offered: [ChangeNotificationKind] = [.scaleSwitched, .changedByOther, .connectionLost]

    /// 設定 › 一般 のチェックボックスの文言
    public var settingLabel: String {
        switch self {
        case .scaleSwitched: return tr("表示倍率を切り替えた時（切り替えられなかった時を含む）", "When the display scale is switched (or couldn’t be)")
        case .changedByOther: return tr("ほかの接続元の Mac が表示倍率を変更した時", "When another Mac changes the display scale")
        case .connectionLost: return tr("接続先に接続できなくなった時", "When ShareScale can no longer connect to the Host")
        }
    }
}

/// 問い合わせ 1 回の結果（`ViewerModel.onResult`）。前の状態は同じ接続先のもの（接続先を切り替えると nil に戻る）
public struct ViewerResult: Equatable, Sendable {
    public enum Trigger: Equatable, Sendable { case refresh, apply(DisplayMode) }
    public let trigger: Trigger
    public let targetName: String
    public let previousState: RemoteState?
    public let previousFailure: ViewerFailure?
    public let state: RemoteState?
    public let failure: ViewerFailure?
    public init(trigger: Trigger, targetName: String, previousState: RemoteState?, previousFailure: ViewerFailure?, state: RemoteState?, failure: ViewerFailure?) {
        self.trigger = trigger; self.targetName = targetName; self.previousState = previousState; self.previousFailure = previousFailure
        self.state = state; self.failure = failure
    }
}

/// 出す通知（題名は接続先の名前、本文は 1〜2 文）。同じ種類の通知は置き換える（通知センターに溜めない）
public struct PlannedNotification: Equatable, Sendable {
    public let kind: ChangeNotificationKind
    public let title: String
    public let body: String
    public var identifier: String { "io.github.taki-0105a.ShareScale." + kind.rawValue }
}

/// 通知の判定（純粋な関数）
public enum NotificationPlanner {
    /// 出す通知（1 回の結果につき多くても 1 つ。優先: 接続できなくなった ＞ 切り替えの結果 ＞ ほかの Mac が変えた）
    public static func plan(_ r: ViewerResult, enabled: Set<ChangeNotificationKind>, appActive: Bool) -> PlannedNotification? {
        guard !appActive else { return nil }
        for kind in [ChangeNotificationKind.connectionLost, .scaleSwitched, .changedByOther] where enabled.contains(kind) {
            // 題名は接続先の名前（Host から来た名前のこともあるので、制御文字を除いて切り詰める）
            if let body = body(kind, r) { return PlannedNotification(kind: kind, title: TextRules.clip(r.targetName, maxBytes: NameRules.maxBytes), body: body) }
        }
        return nil
    }

    static func body(_ kind: ChangeNotificationKind, _ r: ViewerResult) -> String? {
        switch kind {
        case .connectionLost:
            // 直前まで接続できていた時だけ: 前の結果が Host の断り（一時停止中・処理中。接続はできていた。手元の状態を捨てた後でも＝届かなくなった後に
            // 断られた時。再点検 2i）、または、前の結果が成功で状態を知っている（起動・切り替えの直後は、前を知らないので出さない）。
            // 接続できない失敗が続く間は、前の結果も接続できない失敗なので出ない（同じ状態の間は 1 回）。Host が断った結果そのものは「接続できなくなった」ではない
            let wasConnected = r.previousFailure.map(\.isRefusal) ?? (r.previousState != nil)
            guard r.failure == .unreachable || r.failure == .timedOut, wasConnected else { return nil }
            return tr("接続先に接続できなくなりました。ShareScale を開くと、確認することが表示されます。",
                      "ShareScale can no longer connect to the Host. Open ShareScale to see what to check.")
        case .scaleSwitched:
            guard case let .apply(m) = r.trigger else { return nil }
            let name = DataSaving.optionLabel(m)
            if r.failure == nil, let s = r.state, s.lastError == nil {
                if s.sessionActive, !s.virtualAmbiguous, let vd = s.virtualDisplay, vd.scaling == m {
                    return tr("表示倍率を \(jaName(name, "に"))切り替えました。", "Switched the display scale to \(name).")
                }
                if !s.sessionActive {
                    return tr("画面共有を始めると、自動で \(jaName(name, "に"))切り替わります。", "The display scale switches to \(name) when Screen Sharing starts.")
                }
            }
            return tr("表示倍率を \(jaName(name, "に"))切り替えられませんでした。ShareScale を開くと、確認することが表示されます。",
                      "Couldn’t switch the display scale to \(name). Open ShareScale to see what to check.")
        case .changedByOther:
            guard r.trigger == .refresh, r.failure == nil, let s = r.state, s.setByOther == true, let p = r.previousState,
                  p.setByOther != true || p.setAt != s.setAt else { return nil }
            guard let m = s.mode, m != .off else {
                return tr("ほかの接続元の Mac が、表示倍率を自動で保つのをオフにしました。", "Another Mac turned off keeping the display scale automatically.")
            }
            return tr("ほかの接続元の Mac が表示倍率を \(DataSaving.optionLabel(m)) に変更しました。", "Another Mac changed the display scale to \(DataSaving.optionLabel(m)).")
        }
    }
}

/// 通知の許可の状態（`UNAuthorizationStatus` の写し。`unavailable` はバンドルの外で動いている時）
public enum NotificationAuthorization: Equatable, Sendable { case notDetermined, denied, authorized, unavailable }

/// 通知の口。実物は `UNUserNotificationCenter`（ShareScale の実行体の `SystemNotificationPoster`）。試験では差し替える
public protocol NotificationPosting: Sendable {
    func authorization() async -> NotificationAuthorization
    /// 許可を求める（初めての時だけ macOS が確認の画面を出す）。許可されたら true
    func requestAuthorization() async -> Bool
    func post(_ n: PlannedNotification) async
}

/// 通知の設定（`UserDefaults` の `notify.enabled`（既定オフ）と種類ごとの `notify.<種類>`（既定オン））
public struct NotificationPreferences {
    private let store: StringStore
    public init(store: StringStore) { self.store = store }
    public var enabled: Bool {
        get { store.string(forKey: "notify.enabled") == "1" }
        nonmutating set { store.set(newValue ? "1" : "0", forKey: "notify.enabled") }
    }
    public func isOn(_ k: ChangeNotificationKind) -> Bool { store.string(forKey: "notify." + k.rawValue) != "0" }
    public func set(_ k: ChangeNotificationKind, _ on: Bool) { store.set(on ? "1" : "0", forKey: "notify." + k.rawValue) }
}

/// 設定 › 一般 の「通知」に出すもの（純粋な値）
public struct NotificationSettingsModel: Equatable, Sendable {
    public var isOn: Bool
    public var canToggle: Bool
    public var busy: Bool
    public var kinds: [ChangeNotificationKind: Bool]
    public var note: String
    /// 許可されていない時の注意（「通知の設定を開く…」を添える）
    public var problem: String?
    public init(isOn: Bool, canToggle: Bool, busy: Bool, kinds: [ChangeNotificationKind: Bool], note: String, problem: String?) {
        self.isOn = isOn; self.canToggle = canToggle; self.busy = busy; self.kinds = kinds; self.note = note; self.problem = problem
    }
}

/// 通知の設定と送り出し（`ViewerModel.onResult` から `handle` を呼ぶ）
@MainActor
public final class ViewerNotifications: ObservableObject {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var kinds: Set<ChangeNotificationKind>
    @Published public private(set) var authorization: NotificationAuthorization = .notDetermined
    @Published public private(set) var busy = false
    private let preferences: NotificationPreferences
    private let poster: NotificationPosting
    private let appActive: () -> Bool
    /// スイッチを操作するたびに増やす（その前に始めた許可の読み直しの結果を捨てるため）
    private var generation = 0

    public init(preferences: NotificationPreferences, poster: NotificationPosting, appActive: @escaping () -> Bool) {
        self.preferences = preferences; self.poster = poster; self.appActive = appActive
        enabled = preferences.enabled
        kinds = Set(ChangeNotificationKind.allCases.filter { preferences.isOn($0) })
    }

    /// 許可の状態を読み直す（設定を開いた時。求めはしない）。システム設定で後から許可を取り消していたら、スイッチをオフに戻して保存する。
    /// 読んでいる間にスイッチが操作された（世代の番号が変わった）・操作の途中（`busy`）なら、その結果は捨てる（新しい結果を古い読み取りで上書きしないため）
    public func refreshAuthorization() async {
        guard !busy else { return }
        let gen = generation
        let a = await poster.authorization()
        guard !busy, gen == generation else { return }
        authorization = a
        if a == .denied, enabled { enabled = false; preferences.enabled = false }
    }

    /// 「通知」のスイッチ。オンにする時だけ許可を確かめ、まだ決まっていなければ求める（利用者の操作からだけ呼ぶ）。
    /// 許可されなければオフのままにし、「システム設定 › 通知 で許可してください」を出す
    public func setEnabled(_ on: Bool) async {
        guard !busy else { return }
        generation += 1
        guard on else { enabled = false; preferences.enabled = false; return }
        busy = true
        defer { busy = false }
        var a = await poster.authorization()
        if a == .notDetermined { a = await poster.requestAuthorization() ? .authorized : .denied }
        authorization = a
        enabled = a == .authorized
        preferences.enabled = enabled
    }

    public func setKind(_ k: ChangeNotificationKind, _ on: Bool) {
        preferences.set(k, on)
        if on { kinds.insert(k) } else { kinds.remove(k) }
    }

    /// 問い合わせの結果を受け取る。出すものがあれば送り、その `Task` を返す（前面にある時・オフの時・設定に出していない種類は送らず nil。試験は返った `Task` を待つ）
    @discardableResult
    public func handle(_ r: ViewerResult) -> Task<Void, Never>? {
        let chosen = kinds.intersection(ChangeNotificationKind.offered)
        guard enabled, let n = NotificationPlanner.plan(r, enabled: chosen, appActive: appActive()) else { return nil }
        let poster = poster
        return Task { await poster.post(n) }
    }

    public var model: NotificationSettingsModel {
        let problem: String?
        switch authorization {
        case .denied:
            problem = tr("通知が許可されていません。システム設定 › 通知で ShareScale の通知を許可してから、もう一度オンにしてください。",
                         "Notifications aren’t allowed. Allow notifications for ShareScale in System Settings › Notifications, then turn this on again.")
        case .unavailable:
            problem = tr("通知は ~/Applications の ShareScale から使えます。", "Notifications work from ShareScale in ~/Applications.")
        case .notDetermined, .authorized:
            problem = nil
        }
        return NotificationSettingsModel(
            isOn: enabled, canToggle: !busy && authorization != .unavailable, busy: busy,
            kinds: Dictionary(uniqueKeysWithValues: ChangeNotificationKind.offered.map { ($0, kinds.contains($0)) }),
            note: tr("ShareScale が前面にない時だけ通知します。その間は 1 分ごとに接続先を確認します（接続できない時と低電力モードの時は 5 分ごと。スリープの間は確認しません）。通知には接続先の名前を表示し、アドレスは表示しません。",
                     "You’re notified only when ShareScale isn’t in front. While it isn’t, ShareScale checks the target every minute (every 5 minutes when it can’t connect or in Low Power Mode, and not while the Mac is asleep). Notifications show the target’s name but not its addresses."),
            problem: problem)
    }
}
