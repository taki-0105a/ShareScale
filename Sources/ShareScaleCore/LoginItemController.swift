import Combine
import Foundation
import ShareScaleHostCore

/// ログイン項目（Host の常駐）の口。実物は `SMAppService.loginItem(identifier: "io.github.taki-0105a.ShareScale.Host")`（`SystemLoginItemService`）。
/// 試験では差し替える（実物の登録・解除をしない）
public protocol LoginItemService: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
    /// 更新の後の登録し直しの前に、置き換えた後の中身で LaunchServices の登録を更新させる（`LaunchServicesRefresh`。計画 2j）。
    /// 失敗しても投げない（登録し直しは続ける）。効くかは未確認
    func refreshLaunchServices() async
}

/// 実物（ShareScaleHostCore の `SystemChecks` を呼ぶだけ）
public struct SystemLoginItemService: LoginItemService {
    /// ShareScale.app（実物は `Bundle.main.bundleURL`）
    public let appBundle: URL
    public init(appBundle: URL = Bundle.main.bundleURL) { self.appBundle = appBundle }
    public func status() -> LoginItemStatus { SystemChecks.loginItem() }
    public func register() throws { try SystemChecks.registerLoginItem() }
    public func unregister() throws { try SystemChecks.unregisterLoginItem() }
    public func openSystemSettingsLoginItems() { SystemChecks.openLoginItemsSettings() }
    /// 更新させるもの: 中の ShareScale Host.app（ログイン項目の実体。起動の条件が固定されるのはこちらなので先に。点検 2j-B）と、アプリ。
    /// Host.app は `EmbeddedHost.isPresent`（途中にリンクが無く、識別子が Host）の時だけ渡す（ほかの所と同じく、リンクを認めない。点検 2j-A）
    public var launchServicesURLs: [URL] {
        EmbeddedHost.isPresent(in: appBundle) ? [appBundle.appendingPathComponent(EmbeddedHost.relativePath), appBundle] : [appBundle]
    }
    public func refreshLaunchServices() async { _ = await LaunchServicesRefresh.run(launchServicesURLs) }
}

/// 引き渡し・ログイン項目の診断の行（見る側の診断の窓の末尾に足す。「結果をコピー」にも入る）
@MainActor
public final class DistributionStatus: ObservableObject {
    public enum Key: Int, Comparable, Sendable {
        case appState, handoff, loginItem
        public static func < (a: Key, b: Key) -> Bool { a.rawValue < b.rawValue }
    }
    @Published public private(set) var entries: [Key: ViewerDiagnostics.Line] = [:]
    public init() {}
    public func set(_ key: Key, _ line: ViewerDiagnostics.Line?) { entries[key] = line }
    /// 決まった順の行
    public var lines: [ViewerDiagnostics.Line] { entries.keys.sorted().compactMap { entries[$0] } }
}

/// 「この Mac を接続先にする」の表示（純粋な値）
public struct HostSwitchModel: Equatable, Sendable {
    public var isOn: Bool
    public var canToggle: Bool
    public var busy: Bool
    public var note: String
    /// 「ログイン項目を開く」ボタンを出す（`requiresApproval`）
    public var needsApproval: Bool
    public var result: String?
    public var resultIsError: Bool
    public var resultDetail: String?
    public init(isOn: Bool, canToggle: Bool, busy: Bool, note: String, needsApproval: Bool, result: String? = nil, resultIsError: Bool = false, resultDetail: String? = nil) {
        self.isOn = isOn; self.canToggle = canToggle; self.busy = busy; self.note = note; self.needsApproval = needsApproval
        self.result = result; self.resultIsError = resultIsError; self.resultDetail = resultDetail
    }
}

/// ログイン項目の登録・解除（仕様「ログイン項目の登録（複製だけが行う）」）。登録・解除は複製（と開発の組み立て）だけが行う。
/// - オン: 登録 → Host の応答（host-control の `state.json` の `pid` の生存。登録の前と違う pid）を最大 10 秒待つ → 無ければ 解除 → 5 秒 → 登録 を 1 回だけ → 結果を診断に
/// - オフ: 解除（`pairings/host/` は残す）
/// - 複製の起動時: 登録済み（`enabled`）で、自分の CDHash と `app-state.json` の `registered_cdhash` が違えば（更新した）、
///   LaunchServices を更新 → 解除 → 1 秒 → 登録 → 応答を最大 3 秒 → 無ければ 解除 → 3 秒 → 登録 → 最大 10 秒
///   → まだ無ければ 解除 → 5 秒 → 登録 → 最大 10 秒（計画 2j・点検 2j-A。更新の後の 1 回目の Host の起動は、macOS に止められることが多い。
///   簡易署名の Host の起動の条件が古い指紋のまま、と推測している。止められても、すばやく戻す）
/// - `requiresApproval`（利用者がログイン項目でオフにした）なら登録し直さず、システム設定を開くボタンを出す
/// - `SMAppService` の `.notFound` は、アプリの中に Host があれば「まだ登録していない」（`.notRegistered`）として扱う
///   （macOS 27 は一度も登録していないログイン項目に `.notFound` を返す。2026-09-30 実機で確認。計画 2f-1）。Host が本当に無い時だけ「見つかりません」
/// 時間の待ちは `sleep` の口（試験では待たずに数える）
@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var busy = false
    @Published public private(set) var result: (text: String, isError: Bool, detail: String?)?
    /// 直前の結果の種類（`needsApproval` の結果は、スイッチの下の説明と同じ手順を言うので画面に出さない。計画 2f-1）
    private var lastOutcome: Outcome?
    /// 取り除き中・取り除いた後（スイッチを押せない。`UninstallFlow` が立てる。点検 F）
    @Published public private(set) var lockedForRemoval = false

    public let role: AppRole
    private let service: LoginItemService
    private let stateFile: AppStateFile
    private let ownCDHash: String?
    private let hostPID: () -> Int64?
    private let sleep: (Double) async -> Void
    private let distribution: DistributionStatus?
    /// 開発の組み立てから登録する前の、自分のバンドルの持ち主・権限の確かめ（問題があれば理由。点検 I）
    private let ownBundleProblem: () -> HandoffSafety.Problem?
    /// アプリの中に Host があるか（実物は `EmbeddedHost.isPresent(in: Bundle.main.bundleURL)`。試験では差し替える。
    /// 既定値は持たない（組み立てで渡し忘れたらコンパイルで気づくように。点検 2f-1）
    private let hostEmbedded: () -> Bool

    /// オンにした時（初めての登録）: 応答を最大 10 秒 → 無ければ 解除 → 5 秒 → 登録 → 最大 10 秒（計画 2e-1 のまま。初めての登録で止められた記録は無い）
    public static let responseTimeout = 10.0
    public static let pollInterval = 0.25
    public static let retryDelay = 5.0
    /// 更新の後の登録し直し（計画 2j・点検 2j-A）: 解除の後 1 秒 → 登録 → 応答を最大 3 秒 → 無ければ 解除 → 3 秒 → 登録 → 最大 10 秒（`responseTimeout`）
    /// → まだ無ければ 解除 → 5 秒（`updateFinalRetryDelay`）→ 登録 → 最大 10 秒。
    /// 根拠（2026-10-02〜04 実機）: 止められない時、登録から Host の応答までは 1〜2 秒。解除の後の待ちは 1 秒でも通った（待ちの長さは止められるかを決めない）。
    /// 止められた後に通った 2 回目の登録は、どれも止められてから 11 秒以上後（1.0.0 の 10 秒の応答の待ち＋5 秒、試作 5 は 3 秒・8 秒後に様子を見た後の 3 秒）。
    /// 止められてから約 6 秒後の 2 回目（この流れの 2 回目）で通った記録は無いので、それでも来なければ 3 回目を、止められてから 15 秒以上後に行う
    /// （最悪でも 1.0.0 と同じ性質）。ふつうは 2〜3 秒、1 回目だけ止められれば 8 秒前後、2 回目も止められれば 23 秒前後、どれも来なければ 32 秒
    /// （LaunchServices が止まった時は、その上限 2 秒を足して最大 34 秒）
    public static let reregisterDelay = 1.0
    public static let updateResponseTimeout = 3.0
    public static let updateRetryDelay = 3.0
    public static let updateFinalRetryDelay = 5.0

    /// 登録して応答を待つ時の、待ち時間の組（秒）: 1 回目の応答の待ちと、やり直しごとの（解除の後の待ち・応答の待ち）
    struct Timing: Equatable {
        struct Retry: Equatable { var delay: Double; var response: Double }
        var firstResponse: Double
        var retries: [Retry]
    }
    static let turnOnTiming = Timing(firstResponse: responseTimeout, retries: [.init(delay: retryDelay, response: responseTimeout)])
    static let updateTiming = Timing(firstResponse: updateResponseTimeout, retries: [.init(delay: updateRetryDelay, response: responseTimeout),
                                                                                    .init(delay: updateFinalRetryDelay, response: responseTimeout)])

    /// - `hostPID`: 動いている Host の pid（`state.json` の `running` が真で pid が生きている。無ければ nil）
    public init(role: AppRole, service: LoginItemService, stateFile: AppStateFile, ownCDHash: String?, hostPID: @escaping () -> Int64?,
                sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                distribution: DistributionStatus? = nil, ownBundleProblem: @escaping () -> HandoffSafety.Problem? = { nil },
                hostEmbedded: @escaping () -> Bool) {
        self.role = role; self.service = service; self.stateFile = stateFile; self.ownCDHash = ownCDHash
        self.hostPID = hostPID; self.sleep = sleep; self.distribution = distribution; self.ownBundleProblem = ownBundleProblem
        self.hostEmbedded = hostEmbedded
        status = Self.effective(service.status(), hostEmbedded: hostEmbedded())
    }

    /// `SMAppService` の状態と中の Host の有無を、画面と判断に使う形にする（組み合わせをすべて書く。`default` を使わない）:
    /// - 中に Host がある: `.notFound` は「まだ登録していない」（macOS 27 は登録前に `.notFound` を返す）
    /// - 中に Host が無い: 登録していなければ「見つかりません（入れ直してください）」。登録済み・承認待ちはそのまま（解除できるように）
    static func effective(_ s: LoginItemStatus, hostEmbedded: Bool) -> LoginItemStatus {
        switch (s, hostEmbedded) {
        case (.notFound, true): return .notRegistered
        case (.notFound, false): return .notFound
        case (.notRegistered, true): return .notRegistered
        case (.notRegistered, false): return .notFound
        case (.enabled, _): return .enabled
        case (.requiresApproval, _): return .requiresApproval
        case (.unknown, _): return .unknown
        }
    }

    /// 取り除きの間と後はスイッチを押せなくする（中止で閉じた時は `unlockAfterRemoval`）
    public func lockForRemoval() { lockedForRemoval = true }
    public func unlockAfterRemoval() { lockedForRemoval = false }

    /// 今の状態を読み直す。「ログイン項目でオフになっているため、登録し直しませんでした…」の後に、利用者がシステム設定でオンに戻していたら、
    /// その知らせ（結果と診断の行）を消す（古い知らせを残さない。2f-1「2f-2 への注記」。前面に来た時・設定のタブを開いた時に呼ぶ）
    public func refresh() {
        let s = Self.effective(service.status(), hostEmbedded: hostEmbedded())
        if s != status { status = s }
        if lastOutcome == .needsApproval, s != .requiresApproval {
            lastOutcome = nil; result = nil
            distribution?.set(.loginItem, nil)
            // オンに戻った時も、起動時と同じ登録し直しの確かめを行う（オフの間に更新していれば CDHash が変わっている。点検 2f-2）
            if s == .enabled { Task { await self.startup() } }
        }
    }

    public var model: HostSwitchModel {
        let on = status == .enabled || status == .requiresApproval
        let note: String
        let viewerRole = role == .copy || role == .development
        switch status {
        case _ where !viewerRole:
            note = tr("ログイン項目は ~/Applications/ShareScale.app からだけ登録できます。", "Login items can only be registered from ~/Applications/ShareScale.app.")
        case .requiresApproval:
            note = tr("ログイン項目で ShareScale がオフになっています。システム設定 › 一般 › ログイン項目で ShareScale をオンにしてください。",
                      "ShareScale is turned off in Login Items. Turn it on in System Settings › General › Login Items.")
        case .notFound:
            note = tr("このアプリの中に ShareScale Host が見つかりません。ShareScale を入れ直してください。",
                      "ShareScale Host wasn’t found inside this app. Reinstall ShareScale.")
        case _ where role == .development:   // enabled・notRegistered・unknown（上の 2 つは先に出す）
            note = tr("開発用のビルドから登録しています（ビルドし直すと動かなくなります）。ふだんは ~/Applications/ShareScale.app から登録してください。",
                      "Registering from a development build (it stops working when you rebuild). Normally register from ~/Applications/ShareScale.app.")
        case .enabled:
            note = tr("ログインすると ShareScale Host が起動し、ほかの Mac からこの Mac の表示倍率を変更できます。",
                      "ShareScale Host starts when you log in, so other Macs can change this Mac’s display scale.")
        case .notRegistered:
            note = tr("オンにすると、ログイン時に ShareScale Host が起動し、ほかの Mac からこの Mac の表示倍率を変更できるようになります。",
                      "When on, ShareScale Host starts at login so other Macs can change this Mac’s display scale.")
        case .unknown:
            note = tr("ログイン項目の状態を読み取れません。システム設定 › 一般 › ログイン項目を確認してください。",
                      "Can’t read the login item state. Check System Settings › General › Login Items.")
        }
        // 「ログイン項目でオフになっているため、登録し直しませんでした…」は、オフの間はスイッチの下の説明と同じ手順を言い、
        // システム設定でオンにした後は古い知らせになるため、画面には出さない（診断の行には残す）
        let shown = lastOutcome == .needsApproval ? nil : result
        return HostSwitchModel(isOn: on, canToggle: role.canRegisterLoginItem && !busy && !lockedForRemoval && status != .notFound, busy: busy, note: note,
                               needsApproval: status == .requiresApproval && role.canRegisterLoginItem,
                               result: shown?.text, resultIsError: shown?.isError ?? false, resultDetail: shown?.detail)
    }

    public func openLoginItems() { service.openSystemSettingsLoginItems() }

    /// スイッチを押した
    public func setEnabled(_ on: Bool) async {
        guard role.canRegisterLoginItem, !busy, !lockedForRemoval else { return }
        busy = true
        defer { busy = false; refresh() }
        refresh()
        if on {
            if status == .requiresApproval { report(.needsApproval); return }
            if status == .enabled { return }
            if status == .notFound { return }   // 中に Host が本当に無い（スイッチは押せず、説明が「入れ直してください」と言う）
            if role == .development, let p = ownBundleProblem() { report(.unsafeBundle(p.detail)); return }
            report(await registerAndConfirm(previous: hostPID(), timing: Self.turnOnTiming))
        } else {
            do {
                try service.unregister()
                try? stateFile.update { $0.registeredCDHash = nil }
                report(.unregistered)
            } catch {
                report(.failed(unregister: true, detail: "\(error)"))
            }
        }
    }

    /// 複製の起動時: 登録済みで CDHash が変わっていれば登録し直す（複製だけ。開発の組み立ては自動では登録し直さない）
    public func startup() async {
        guard role == .copy, !busy, !lockedForRemoval else { return }
        refresh()
        guard status == .enabled, let own = ownCDHash, stateFile.load().state.registeredCDHash != own else { return }
        busy = true
        defer { busy = false; refresh() }
        let previous = hostPID()
        // 登録し直しの前に、LaunchServices の登録を新しい中身で更新させる（止められなくなるかは未確認。失敗しても続ける。計画 2j）
        await service.refreshLaunchServices()
        try? service.unregister()
        await sleep(Self.reregisterDelay)
        // 待つ間に取り除きが始まっていたら登録し直さない（取り除きが消すものを作り直さない。「ログイン時に開く」と同じ。計画 2j）
        guard !lockedForRemoval else { return }
        let outcome = await registerAndConfirm(previous: previous, timing: Self.updateTiming)
        // 更新の後は、1 回目の起動が止められてやり直しで戻ることが多い。どちらも「切り替えました」（計画 2j）
        report(outcome == .registered || outcome == .registeredAfterRetry ? .switched : outcome)
    }

    enum Outcome: Equatable {
        case registered, registeredAfterRetry, switched, noResponse, needsApproval, unregistered
        case failed(unregister: Bool, detail: String)
        case unsafeBundle(String)
        /// やり直しを待つ間に取り除きが始まった（何も出さない。計画 2j）
        case stoppedForRemoval
    }

    /// 登録して Host の応答を待つ（`timing.firstResponse` 秒）。無ければ `timing.retries` の順に、解除 → `delay` 秒 → 登録 → `response` 秒 を行う
    /// （オンにした時は 1 回、更新の後は 2 回。点検 2j-A）。
    /// `registered_cdhash` は Host が応答した時だけ書く（応答が無ければ、次に開いた時にもう一度登録し直す。点検 L）
    private func registerAndConfirm(previous: Int64?, timing: Timing) async -> Outcome {
        do { try service.register() } catch { return .failed(unregister: false, detail: "\(error)") }
        if service.status() == .requiresApproval { return .needsApproval }
        if await waitForHost(previous: previous, limit: timing.firstResponse) { recordRegistered(); return .registered }
        for retry in timing.retries {
            try? service.unregister()
            await sleep(retry.delay)
            guard !lockedForRemoval else { return .stoppedForRemoval }
            do { try service.register() } catch { return .failed(unregister: false, detail: "\(error)") }
            if service.status() == .requiresApproval { return .needsApproval }
            if await waitForHost(previous: previous, limit: retry.response) { recordRegistered(); return .registeredAfterRetry }
        }
        return .noResponse
    }

    private func recordRegistered() {
        if let own = ownCDHash { try? stateFile.update { $0.registeredCDHash = own } }
    }

    /// 登録の前と違う pid の Host が動くまで待つ（最大 `limit` 秒）
    private func waitForHost(previous: Int64?, limit: Double) async -> Bool {
        var waited = 0.0
        while true {
            if let p = hostPID(), p != previous { return true }
            if waited >= limit { return false }
            await sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    private func report(_ o: Outcome) {
        let r: (String, Bool, String?)
        switch o {
        case .stoppedForRemoval: return   // 取り除きの窓が結果を出す
        case .registered, .registeredAfterRetry:
            r = (tr("ShareScale Host を登録しました。動いています。", "Registered ShareScale Host. It’s running."), false, nil)
        case .switched:
            r = (tr("新しいバージョンの ShareScale Host に切り替えました。", "Switched to the new version of ShareScale Host."), false, nil)
        case .noResponse:
            r = (tr("ShareScale Host を登録しましたが、応答がありません。「この Mac を接続先にする」をオフにしてからオンにしてください。",
                    "ShareScale Host was registered but isn’t responding. Turn Use This Mac as a Target off, then on again."), true, nil)
        case .needsApproval:
            r = (tr("ログイン項目で ShareScale がオフになっているため、登録し直しませんでした。システム設定 › 一般 › ログイン項目でオンにしてください。",
                    "ShareScale is turned off in Login Items, so it wasn’t registered again. Turn it on in System Settings › General › Login Items."), true, nil)
        case .unregistered:
            r = (tr("ShareScale Host の登録を解除しました。接続元の Mac とのペアリングは残っています（オンに戻せばそのまま使えます）。",
                    "Removed ShareScale Host from Login Items. Pairings with the Macs to connect from are kept (turn it back on to use them)."), false, nil)
        case let .unsafeBundle(detail):
            r = (tr("このビルドのフォルダにほかの人が書き込めるため、登録しません。ビルドしたフォルダの所有者とアクセス権を確認してください。",
                    "Others can write to this build’s folder, so it won’t be registered. Check the owner and permissions of the build folder."), true, detail)
        case let .failed(unregister, detail):
            r = (unregister ? tr("ShareScale Host の登録を解除できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。",
                                 "Couldn’t remove ShareScale Host from Login Items. Try again, or check System Settings › General › Login Items.")
                            : tr("ShareScale Host をログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。",
                                 "Couldn’t add ShareScale Host to Login Items. Try again, or check System Settings › General › Login Items."), true, detail)
        }
        result = r
        lastOutcome = o
        let mark: ViewerDiagnostics.Mark = r.1 ? .bad : .ok
        // ログイン項目で直せる失敗には「ログイン項目を開く…」を添える（計画 2f-1 案 5）
        let action: DiagnosticAction?
        switch o {
        case .needsApproval, .failed: action = .openLoginItemsSettings
        case .registered, .registeredAfterRetry, .switched, .noResponse, .unregistered, .unsafeBundle, .stoppedForRemoval: action = nil
        }
        distribution?.set(.loginItem, ViewerDiagnostics.Line(mark, tr("ログイン項目: ", "Login item: ") + r.0, action: action))   // 生の理由は画面の「詳細をコピー」だけ
    }
}
