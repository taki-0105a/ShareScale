import Combine
import Foundation
import ShareScaleHostCore
import ShareScaleProtocol

/// 設定の「この Mac の接続先」に出すもの（仕様「自己診断」の Host のメニューと「この Mac の接続先」。`HostControlClient.hostState()` の結果から作る純粋な値）。
/// - 状態: 動作中／一時停止中／止まっている／状態を読めない（記号と文字。色だけで示さない）
/// - 案内: 動いていない・読めない時は HostCore の `HostControlClient.notRunningGuidance`（「この Mac を接続先にする」をオンにする。計画 2e-1 で戻した）。
///   読めない理由などの生の内容は本文に出さず `guidanceDetail`（「詳細をコピー」）へ
/// - 「この Mac を接続先にする」（ログイン項目）の表示は `LoginItemController.model`（ShareScale.app 側で `SMAppService` の状態を読む。計画 2e-1）
/// - バージョンの食い違い: アプリの `CFBundleVersion`（`appBuild`）と Host の `build` が違えば案内する（アップデートの途中の案内が出ている時は重ねない）
/// - 操作（一時停止・再開・接続元の Mac を追加・登録を解除・あとで・受け付けの設定・終了）は Host が動いている時だけ押せる
/// - Host から来た文字列（名前・版・直近の失敗）は制御文字を除き、長さを切り詰めてから持つ
public struct HostPanelModel: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, paused, stopped, unknown }

    /// 操作（`HostControlClient` の指示に 1 対 1）
    public enum Action: Equatable, Sendable {
        case pause, resume, issueCode, quit
        case unpair(PairingID), snooze(PairingID)
        case tailscaleOnly(Bool), allowGlobal(Bool)
        /// Host の窓を出す（ShareScale.app のメニューの「接続コードを表示…」「診断…」。計画 2f-2 案 2）
        case showCode, showDiagnostics
    }

    /// 状態のカードの注意の 1 つ
    public struct Notice: Equatable, Hashable, Sendable {
        public let text: String
        public let action: DiagnosticAction?
        public init(_ text: String, action: DiagnosticAction? = nil) { self.text = text; self.action = action }
    }

    /// 見る側（画面では「接続元の Mac」）の 1 行
    public struct Viewer: Equatable, Identifiable, Sendable {
        public let id: PairingID
        public let name: String         // 表示名（確かめの窓の題名に使う）
        public let title: String        // 行の見出し（名前。80 日使われていなければ、その知らせ）
        public let detail: String       // 未確定／一度も接続していません／最終接続: N 日前
        public let stale: Bool          // 80 日の知らせ（「あとで」を出す）
        public var accessibilityLabel: String { title + tr("、", ", ") + detail }
    }

    public var status: Status
    public var symbol: String
    public var statusText: String
    public var guidance: String?
    /// 案内の生の理由（「詳細をコピー」。本文には出さない）
    public var guidanceDetail: String?
    public var listener: String?
    /// 状態のカードの注意（ファイアウォール・FileVault には「〜の設定を開く…」を添える。計画 2f-1 案 5）
    public var noticeItems: [Notice]
    /// 注意の文だけ
    public var notices: [String] { noticeItems.map(\.text) }
    public var viewers: [Viewer]
    /// 発行中のコード（期限だけ。コードは Host の窓に出る）
    public var code: String?
    public var canOperate: Bool
    public var pauseAction: Action
    public var pauseTitle: String
    public var canIssueCode: Bool
    public var issueCodeTitle: String
    public var tailscaleOnly: Bool
    public var allowGlobal: Bool
    public var version: String?

    public static func make(_ state: HostControlClient.HostState, now: Int64, appBuild: Int? = nil) -> HostPanelModel {
        let s = state.summary
        var m = HostPanelModel(status: .stopped, symbol: "xmark.circle", statusText: "", guidance: nil, guidanceDetail: nil, listener: nil, noticeItems: [], viewers: [],
                               code: nil, canOperate: false, pauseAction: .pause, pauseTitle: tr("一時停止", "Pause"), canIssueCode: false,
                               issueCodeTitle: tr("接続元の Mac を追加…", "Add a Mac to Connect From…"), tailscaleOnly: s?.tailscaleOnly ?? false,
                               allowGlobal: s?.allowGlobal ?? false,
                               version: s.map { "ShareScale Host \(TextRules.clip($0.version, maxBytes: 32))" })
        switch state {
        case let .running(s):
            m.status = s.paused ? .paused : .running
            m.symbol = s.paused ? "pause.circle" : "checkmark.circle"
            m.statusText = s.paused ? tr("一時停止中（表示倍率を変更しません）", "Paused (the display scale isn’t changed)") : tr("動作中", "Running")
            m.guidance = tr("操作しても反応がない場合は、「この Mac を接続先にする」をオフにしてから、もう一度オンにしてください。",
                            "If nothing happens when you use these controls, turn Use This Mac as a Target off and then on again.")
            m.listener = listenerText(s)
            m.noticeItems = notices(s, appBuild: appBuild)
            m.canOperate = true
            m.pauseAction = s.paused ? .resume : .pause
            m.pauseTitle = s.paused ? tr("再開", "Resume") : tr("一時停止", "Pause")
            if s.pairings.count >= Limits.maxPairings {
                m.issueCodeTitle = tr("接続元の Mac を追加（上限の \(Limits.maxPairings) 台に達しています）", "Add a Mac to Connect From (limit of \(Limits.maxPairings) reached)")
            } else if s.listenerStatus != "listening" {
                m.issueCodeTitle = tr("接続元の Mac を追加（接続を受け付けていません）", "Add a Mac to Connect From (not accepting connections)")
            } else {
                m.canIssueCode = true
            }
            if let x = s.codeExpires, x > now {
                // 「表示」を重ねず、どのウインドウかを名前で指す（用語集「窓」）
                m.code = tr("接続コードを ShareScale Host の「接続コード」ウインドウに表示しています（残り \(HostLanguage.clock(Int(x - now)))）。",
                            "The pairing code is showing in ShareScale Host’s Pairing Code window (\(HostLanguage.clock(Int(x - now))) left).")
            }
        case .notRunning:
            m.status = .stopped
            m.symbol = "xmark.circle"
            m.statusText = tr("停止しています", "Not running")
            m.guidance = HostControlClient.notRunningGuidance(state, language: AppLanguage.current.host)
        case let .unknown(problem):
            m.status = .unknown
            m.symbol = "questionmark.circle"
            m.statusText = tr("状態を読み取れません", "State unavailable")
            m.guidance = HostControlClient.notRunningGuidance(state, language: AppLanguage.current.host)
            m.guidanceDetail = problem
        }
        m.viewers = (s?.pairings ?? []).sorted { (displayName($0.name), $0.id.hex) < (displayName($1.name), $1.id.hex) }.map { viewer($0, now: now) }
        return m
    }

    static func displayName(_ raw: String) -> String {
        let t = TextRules.clip(raw, maxBytes: NameRules.maxBytes).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || HostLanguage.isUnnamedPlaceholder(t) ? AppLanguage.current.host.unnamed : t
    }

    static func viewer(_ p: HostControlState.Pairing, now: Int64) -> Viewer {
        let name = displayName(p.name)
        let title = p.stale ? tr("「\(name)」は 80 日間使われていません。登録を解除しますか？", "“\(name)” hasn’t been used in 80 days. Remove it?") : name
        let detail: String
        if !p.confirmed {
            detail = tr("確認待ち（その Mac で登録が完了していません）", "Pending confirmation (not yet finished on that Mac)")
        } else if let last = p.lastSeen {
            let age = now - last
            if age < 0 { detail = tr("最後の接続: 不明（時計が合っていません）", "Last connected: unknown (clock mismatch)") }
            else if age / 86_400 == 0 { detail = tr("最後の接続: 今日", "Last connected: today") }
            else { detail = tr("最後の接続: \(age / 86_400) 日前", "Last connected: \(HostLanguage.count(Int(age / 86_400), "day", "days")) ago") }
        } else {
            detail = tr("まだ接続していません", "Not connected yet")
        }
        return Viewer(id: p.id, name: name, title: title, detail: detail, stale: p.stale)
    }

    /// 受け付けの状態（Host のメニューと同じ言葉。文になっているものは「。」で終える）。
    /// 受け付けている時の 1 行は Host のメニューと同じ関数（`MenuModel.acceptingLine`。設定の 3 つの状態で出し分ける。計画 2h）
    static func listenerText(_ s: HostControlState.Summary) -> String {
        let port = s.port.map(String.init) ?? "?"
        switch s.listenerStatus {
        case "listening":
            // Host のメニュー・Host の診断・ShareScale のメニューと、文字どおり同じ行（Tailscale の IPv4 も同じ条件で出す。点検 2h）
            return MenuModel.acceptingLine(tailscaleOnly: s.tailscaleOnly, allowGlobal: s.allowGlobal, tailscaleIPv4: HostMenuFacts(summary: s).tailscaleIPv4,
                                           port: port, AppLanguage.current.host)
        case "waiting_for_network":
            return tr("Tailscale が見つからないため、接続を受け付けていません。", "Not accepting connections because Tailscale wasn’t found.")
        case "port_in_use":
            return tr("ポート \(port) がほかのアプリ（別のユーザの ShareScale など）で使われているため、接続を受け付けられません。",
                      "Can’t accept connections because port \(port) is in use by another app (such as another user’s ShareScale).")
        case "failed":
            return tr("接続を受け付けられません（もう一度試しています）。詳しくは ShareScale Host の「診断」で確認できます。", "Can’t accept connections (trying again). See Diagnostics in ShareScale Host for details.")
        case "starting":
            return tr("接続の受け付けを準備しています…", "Getting ready to accept connections…")
        default:
            return tr("接続を受け付けていません。", "Not accepting connections.")
        }
    }

    /// 案内（Host のメニューと同じ順: 更新の途中 ＞ 版の食い違い ＞ 奪い合い ＞ 直近の失敗、のあとに読めないファイル・ファイアウォール・FileVault）。
    /// ログイン項目の状態は Host の `state.json` の `login_item`（Host 自身が読むと `not_found` になりうる）ではなく、ShareScale.app 側で読んでスイッチの下に出す（計画 2e-1）
    static func notices(_ s: HostControlState.Summary, appBuild: Int? = nil) -> [Notice] {
        var out: [Notice] = []
        func add(_ text: String, _ action: DiagnosticAction? = nil) { out.append(Notice(text, action: action)) }
        if s.updating { add(tr("アップデートの途中です。ShareScale を開き直すと完了します。", "An update is in progress. Reopen ShareScale to finish it.")) }
        if !s.updating, let app = appBuild, app > 0, s.build != Int64(app) {
            add(s.build < Int64(app)
                ? tr("ShareScale Host が古いバージョンで動いています。ShareScale を開き直すと新しいバージョンに切り替わります。",
                     "ShareScale Host is running an older version. Reopen ShareScale to switch to the new version.")
                : tr("ShareScale Host がこのアプリより新しいバージョンで動いています。新しいバージョンの ShareScale を開いてください。",
                     "ShareScale Host is running a newer version than this app. Open the newer ShareScale."))
        }
        if s.contention { add(tr("表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）。", "The display scale keeps being changed back (another app may be changing it).")) }
        if !s.contention, !s.updating, let e = s.lastError {
            add(tr("直近のエラー: ", "Last error: ") + TextRules.clip(e))
        }
        if s.storeProblems > 0 {
            add(tr("読み込めないペアリングのファイルが \(s.storeProblems) 件あります。詳しくは ShareScale Host の「診断」で確認できます。",
                   "\(HostLanguage.count(Int(s.storeProblems), "pairing file", "pairing files")) can’t be read. See Diagnostics in ShareScale Host for details."))
        }
        switch s.firewall {
        case "block_all":
            add(tr("ファイアウォールで「外部からの接続をすべてブロック」がオンになっているため、ほかの Mac から接続できません。システム設定 › ネットワーク › ファイアウォール › オプションでオフにしてください。",
                   "The firewall is set to block all incoming connections, so other Macs can’t connect. Turn this off in System Settings › Network › Firewall › Options."), .openFirewallSettings)
        case "blocked":
            add(tr("ファイアウォールが ShareScale Host への接続をブロックしています。システム設定 › ネットワーク › ファイアウォール › オプションで、ShareScale Host を「外部からの接続を許可」にしてください。",
                   "The firewall is blocking connections to ShareScale Host. In System Settings › Network › Firewall › Options, set ShareScale Host to Allow incoming connections."), .openFirewallSettings)
        default: break
        }
        if s.fileVault == false {
            add(tr("FileVault がオフです。ペアリングの鍵はディスクの暗号化で保護されるため、システム設定 › プライバシーとセキュリティ › FileVault でオンにすることをお勧めします。",
                   "FileVault is off. Pairing keys are protected by disk encryption, so turning on FileVault in System Settings › Privacy & Security is recommended."), .openFileVaultSettings)
        }
        return out
    }

    /// 「接続を受け付けるネットワーク」の見出しの下の注記（既定で受け付ける範囲。受け付けの行の「ローカルネットワークと Tailscale」の中身。点検 2h）
    public static var defaultNetworkNote: String {
        tr("既定では、プライベートアドレス（同じネットワークや VPN など）と Tailscale の範囲（100.64.0.0/10・fc00::/7）からの接続を受け付けます。",
           "By default, connections are accepted from private addresses (the same network, a VPN, and so on) and from the ranges Tailscale uses (100.64.0.0/10 and fc00::/7).")
    }

    /// 操作を送った後の一言
    public static func sentMessage(_ a: Action) -> String {
        switch a {
        case .issueCode: return tr("ShareScale Host に接続コードの作成を指示しました。", "Asked ShareScale Host to create a pairing code.")
        case .quit: return tr("ShareScale Host に終了を指示しました。", "Asked ShareScale Host to quit.")
        case .pause, .resume, .tailscaleOnly, .allowGlobal: return tr("ShareScale Host に設定を送信しました。", "Sent the setting to ShareScale Host.")
        case .unpair: return tr("ShareScale Host に登録の解除を指示しました。", "Asked ShareScale Host to remove the Mac.")
        case .snooze: return tr("この通知は 30 日間表示しません。", "This notice won’t appear for 30 days.")
        case .showCode: return tr("ShareScale Host に「接続コード」ウインドウの表示を指示しました。", "Asked ShareScale Host to show its Pairing Code window.")
        case .showDiagnostics: return tr("ShareScale Host に「診断」ウインドウの表示を指示しました。", "Asked ShareScale Host to show its Diagnostics window.")
        }
    }

    /// この Mac で ShareScale Host が動いている（一時停止中を含む）。主の窓の案内に `mainWindowHint` を添えるかどうか
    public var hostIsRunning: Bool { status == .running || status == .paused }

    /// 主の窓で接続先が無い時に添える 1 行（この Mac で Host が動いている時だけ。実機確認 2026-09-30: メニューバーの記号が切り欠きに隠れて見つからなかった）
    public static var mainWindowHint: String {
        tr("この Mac も接続先として使っている場合は、設定 › この Mac の接続先から操作できます。",
           "If you also use this Mac as a target, you can manage it in Settings › This Mac as a Target.")
    }

    /// Host が動いていない時の操作の答え（指示を置かない。止まっていた間に置いた指示を、次の起動で急に行わないため）
    public static var notRunningAction: String {
        tr("ShareScale Host が動いていません。「この Mac を接続先にする」をオンにしてから、もう一度操作してください。",
           "ShareScale Host isn’t running. Turn on Use This Mac as a Target, then try again.")
    }
}

/// 「この Mac の接続先」の読み取りと操作（`HostControlClient` の薄い包み）。
/// - 読み直し: タブを開いている間は `startPolling`（既定 2 秒ごと）、閉じたら `stopPolling`。操作の 0.5 秒後と 2 秒後にも読む。値が変わった時だけ `panel` を書き換える
/// - 操作: 送る前に Host が動いているかを確かめ、動いていなければ置かない（`HostPanelModel.notRunningAction`）
/// - 受け付けのスイッチは、押したら次の読み直しまで新しい値を見せる（Host の処理は 0.2 秒ほどで終わる）。
///   操作の後、最初の読み直し（`rereadDelays` の 1 つ目）までは定期の読み直しを見送る（Host が処理する前の値に一瞬戻さないため）
@MainActor
public final class HostPanelStore: ObservableObject {
    @Published public private(set) var panel: HostPanelModel
    /// Host が動いている時の、Host のメニューの元の値（ShareScale.app のメニューバーの「この Mac の接続先」の節。動いていなければ nil。計画 2f-2 案 2）
    @Published public private(set) var facts: HostMenuFacts?
    /// 直前の操作の結果の一言（誤りなら `actionFailed` が真）と、コピーできる生の理由
    @Published public private(set) var actionMessage: String?
    @Published public private(set) var actionFailed = false
    @Published public private(set) var actionDetail: String?

    private let client: HostControlClient
    private let clock: () -> Int64
    /// アプリの `CFBundleVersion`（Host の `build` と比べる。バンドルの外では nil）
    private let appBuild: Int?
    /// 操作の後に読み直すまでの時間（Host は通知を受けて 0.2 秒以上空けて処理する）
    private let rereadDelays: [Double]
    /// 定期の読み直しの Task（`deinit` からも取り消すので nonisolated。取り消しはどのスレッドからでもよい）
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    /// この時刻までは定期の読み直しを見送る（操作の直後）
    private var holdPollingUntil: ContinuousClock.Instant?

    /// メニューバーの「この Mac の接続先」の節に出すもの（動いている・プロセスはあるが読めない・無し。点検 2f-2）
    @Published public private(set) var menuSection: ViewerMenu.HostSection?
    /// Host の識別子のプロセスが動いているか（実物は `NSRunningApplication`。`state.json` を読めない時に節を出すかに使う）
    private let hostProcessRunning: () -> Bool
    /// ShareScale だけが Host の状態を読めない（`.unreadable`）のが `yieldAfter` 続いた。真の間はメニューバーの受け持ちを外し、Host にアイコンを戻させる
    /// （ShareScale の節からは Host を操作できないため。読めるようになったら偽に戻り、受け持ちを書き直す。再点検 2f-2）
    @Published public private(set) var yieldsMenuBar = false
    public static let yieldAfter: Duration = .seconds(10)
    private var unreadableSince: ContinuousClock.Instant?
    private var recheckScheduled = false
    private let monotonic: () -> ContinuousClock.Instant
    private let sleep: (Duration) async -> Void

    public init(client: HostControlClient, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }, rereadDelays: [Double] = [0.5, 2],
                appBuild: Int? = nil, hostProcessRunning: @escaping () -> Bool = { false },
                monotonic: @escaping () -> ContinuousClock.Instant = { .now },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.client = client; self.clock = clock; self.rereadDelays = rereadDelays; self.appBuild = appBuild; self.hostProcessRunning = hostProcessRunning
        self.monotonic = monotonic; self.sleep = sleep
        let state = client.hostState()
        panel = HostPanelModel.make(state, now: clock(), appBuild: appBuild)
        facts = Self.facts(state)
        menuSection = Self.section(state, appBuild: appBuild, processRunning: hostProcessRunning)
        noteSection()
    }
    deinit { pollTask?.cancel() }

    static func facts(_ s: HostControlClient.HostState) -> HostMenuFacts? {
        if case let .running(summary) = s { return HostMenuFacts(summary: summary) }
        return nil
    }

    /// 節に出すもの（Host のプロセスが無ければ nil）:
    /// - 動いている: 値（アプリより古い版なら `outdated`）
    /// - `state.json` を読めない・形が違う: `.unreadable`
    /// - まだ書いていない・前の Host の pid が残っている（`running` が真なのに pid が生きていない）: `.starting`
    /// - `running:false` を書いた（終了の途中）: `.stopping`（再点検 2f-2。一瞬の移り変わりを「読み取れません」と言わない）
    static func section(_ s: HostControlClient.HostState, appBuild: Int?, processRunning: () -> Bool) -> ViewerMenu.HostSection? {
        if case let .running(summary) = s {
            let outdated = (appBuild ?? 0) > 0 && summary.build < Int64(appBuild ?? 0)
            return .running(HostMenuFacts(summary: summary), outdated: outdated)
        }
        guard processRunning() else { return nil }
        switch s {
        case .running: return nil   // 上で返している
        case .unknown: return .unreadable
        case .notRunning(last: nil): return .starting
        case let .notRunning(last: summary?): return summary.running ? .starting : .stopping
        }
    }

    /// `.unreadable` が続いた時間を数え、`yieldAfter` を過ぎたら受け持ちを外す。読めない間は `yieldAfter` ごとに読み直す
    private func noteSection() {
        guard menuSection == .unreadable else {
            unreadableSince = nil
            if yieldsMenuBar { yieldsMenuBar = false }
            return
        }
        let now = monotonic()
        if let since = unreadableSince {
            if now - since >= Self.yieldAfter, !yieldsMenuBar { yieldsMenuBar = true }
        } else {
            unreadableSince = now
        }
        guard !recheckScheduled else { return }
        recheckScheduled = true
        let sleep = sleep
        Task { [weak self] in
            await sleep(Self.yieldAfter)
            guard let self else { return }
            self.recheckScheduled = false
            self.reload()
        }
    }

    /// `state.json` を読み直す（値が変わった時だけ書き換える）
    public func reload() {
        let state = client.hostState()
        let p = HostPanelModel.make(state, now: clock(), appBuild: appBuild)
        if p != panel { panel = p }
        let f = Self.facts(state)
        if f != facts { facts = f }
        let m = Self.section(state, appBuild: appBuild, processRunning: hostProcessRunning)
        if m != menuSection { menuSection = m }
        noteSection()
    }

    /// 読み直しを頼んでいるもの（設定のタブ・初回のガイド。どれかが開いている間は読み直す。点検 2f-2）
    private var pollOwners: Set<String> = []

    /// 開いている間の読み直しを始める（読み直しは 1 本だけ。2 回目からは頼み手を覚えるだけ）
    public func startPolling(every seconds: Double = 2, owner: String = "settings") {
        pollOwners.insert(owner)
        guard pollTask == nil else { return }
        reload()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                guard let self, !Task.isCancelled else { break }
                self.pollTick()
            }
        }
    }
    private func pollTick() {
        if let until = holdPollingUntil {
            if ContinuousClock.now < until { return }
            holdPollingUntil = nil
        }
        reload()
    }
    /// 閉じたら止める（ほかの頼み手が開いている間は止めない）
    public func stopPolling(owner: String = "settings") {
        pollOwners.remove(owner)
        guard pollOwners.isEmpty else { return }
        pollTask?.cancel(); pollTask = nil
    }
    public var isPolling: Bool { pollTask != nil }

    /// 操作を送る。`report` が偽なら結果の一言を「この Mac の接続先」のタブに残さない（メニューバーからの操作。結果は Host の窓が出ることで分かる。計画 2f-2）。
    /// 送れなかった時の一言は、どちらでも残す
    public func perform(_ a: HostPanelModel.Action, report: Bool = true) {
        guard client.hostState().isRunning else {
            actionMessage = HostPanelModel.notRunningAction; actionFailed = true; actionDetail = nil
            reload()
            return
        }
        do {
            switch a {
            case .pause: try client.pause()
            case .resume: try client.resume()
            case .issueCode: try client.issueCode()
            case .quit: try client.quit()
            case let .unpair(id): try client.unpair(id)
            case let .snooze(id): try client.snooze(id)
            case let .tailscaleOnly(v): try client.setTailscaleOnly(v); panel.tailscaleOnly = v
            case let .allowGlobal(v): try client.setAllowGlobal(v); panel.allowGlobal = v
            case .showCode: try client.showCode()
            case .showDiagnostics: try client.showDiagnostics()
            }
            if report { actionMessage = HostPanelModel.sentMessage(a); actionFailed = false; actionDetail = nil }
            holdPollingUntil = ContinuousClock.now + .milliseconds(Int((rereadDelays.first ?? 0) * 1000))
        } catch {
            actionMessage = tr("ShareScale Host に指示を送れませんでした。~/Library/Application Support/ShareScale/host-control/ のアクセス権を確認してください。",
                               "Couldn’t send the request to ShareScale Host. Check the permissions of ~/Library/Application Support/ShareScale/host-control/.")
            actionFailed = true
            actionDetail = "\(error)"
        }
        let delays = rereadDelays
        Task { [weak self] in
            var slept = 0.0
            for d in delays {
                try? await Task.sleep(nanoseconds: UInt64(max(0, d - slept) * 1e9))
                slept = d
                self?.reload()
            }
        }
    }
}
