import Combine
import Foundation

/// 画面に出す内容を決める（接続先との通信は `TargetControlling` の口。本物は `TargetSession`）。
/// SwiftUI にも AppKit にも依存しないのでテストできる。案内の文言は `ViewerNotice`（純粋な関数）
@MainActor
public final class ViewerModel: ObservableObject {
    @Published public private(set) var state: RemoteState?
    @Published public private(set) var failure: ViewerFailure?
    /// 想定外のエラーの生の内容。画面の本文には出さず、コピーできるようにだけしておく
    @Published public private(set) var failureDetail: String?
    @Published public private(set) var busy = false
    @Published public private(set) var displays: [LocalDisplay]
    /// 接続先の表示名（帳簿の名前。相手の名前が取れない時の見出しにも使う）
    @Published public private(set) var targetLabel: String
    /// 接続先の表示名が利用者の付けた名前か（真なら見出しに相手のコンピュータ名ではなくこの名前を出す。計画 2f-1 案 6）
    @Published public private(set) var targetLabelIsAlias = false
    /// 接続先が帳簿で未確定（名乗りの後の `status` がまだ通っていない）
    @Published public private(set) var targetUnconfirmed = false
    /// 届かない時に、別の VPN が既定の経路を握っていそうか
    @Published public private(set) var vpnSuspected = false
    /// カードごとに選んだ倍率が変わった時に画面を更新するため
    @Published private var preferenceVersion = 0
    /// 切り替えを「一時停止中」で断られた（次に成功するか、接続できなくなるまで覚えておく。手元に状態が無い間は `state.paused` に写せないので、
    /// その後に「処理中」で断られると「一時停止中」が消えていた。再点検 2i）
    @Published private var refusedAsPaused = false

    private var client: TargetControlling?
    private let displayProvider: () -> [LocalDisplay]
    private let vpnCheck: () async -> Bool
    private let preferences: DisplayPreferences
    private let clock: () -> ContinuousClock.Instant
    private var lastRefresh: ContinuousClock.Instant?
    /// 接続先を切り替えるたびに増やす。古い接続先への問い合わせの結果が遅れて届いたら捨てるため
    private var generation = 0
    /// 処理中に選ばれた倍率。処理が終わったら 1 回だけ送る（最後に選んだものだけ）
    private var pendingMode: DisplayMode?
    /// この時間内の再取得は省く（起動時に複数の経路から同時に呼ばれるため。スリープ中も進む時計で数える）
    public static let coalesceInterval: Duration = .seconds(2)
    /// 問い合わせ 1 回の結果（変わった時の通知 `ViewerNotifications.handle` に渡す。計画 2f-1 案 7）。
    /// 取り消された時・途中で接続先が切り替わった時は呼ばない。前の状態は同じ接続先のもの
    public var onResult: ((ViewerResult) -> Void)?

    /// - `client`: 接続先（nil なら未登録。「接続先を追加」を案内する）
    public init(client: TargetControlling?,
                displays: @escaping () -> [LocalDisplay],
                targetLabel: String = "",
                unconfirmed: Bool = false,
                vpnCheck: @escaping () async -> Bool = { false },
                preferences: DisplayPreferences = DisplayPreferences(store: InMemoryStringStore()),
                clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.client = client
        self.vpnCheck = vpnCheck
        self.targetLabel = targetLabel
        self.targetUnconfirmed = unconfirmed
        self.displayProvider = displays
        self.preferences = preferences
        self.clock = clock
        self.displays = displays()
    }

    public func reloadDisplays() { displays = displayProvider() }

    /// 接続先が登録されているか（無ければ「接続先を追加」を案内する）
    public var hasTarget: Bool { client != nil }

    /// 接続先を変えた（nil は「接続先なし」）。前の相手の状態は捨て、処理中の問い合わせの結果も無効にし、次の refresh は間引かずに取り直す
    public func updateClient(_ newClient: TargetControlling?, targetLabel: String, unconfirmed: Bool = false, aliased: Bool = false) {
        generation += 1
        client = newClient
        self.targetLabel = targetLabel
        targetLabelIsAlias = aliased
        targetUnconfirmed = unconfirmed
        state = nil; failure = nil; failureDetail = nil; vpnSuspected = false; refusedAsPaused = false
        lastRefresh = nil
        pendingMode = nil        // 前の接続先に向けて選んだものは、新しい接続先には送らない
        busy = false
    }

    /// 名前を付け直した（相手と状態はそのまま。見出し・案内・通知の名前だけが変わる）
    public func rename(targetLabel: String, aliased: Bool) {
        self.targetLabel = targetLabel
        targetLabelIsAlias = aliased
    }

    // MARK: - 操作

    /// 状態を取り直す。呼び出し側の Task が取り消されたら（`ViewerFailure.cancelled`）画面の状態は変えない。
    /// 画面の寿命に結び付いた Task（SwiftUI の `.task {}` など）から呼ばない（画面が消えると途中で取り消されるため。2d-2）
    public func refresh(force: Bool = false) async {
        guard !busy, client != nil else { return }
        if !force, let last = lastRefresh, clock() - last < Self.coalesceInterval { return }
        let previous = lastRefresh
        lastRefresh = clock()
        if await perform(.refresh, { await $0.status() }) { lastRefresh = previous }   // 取り消されたら、取り直したことにしない（次の refresh を間引かない）
        reloadDisplays()
    }

    public func apply(_ mode: DisplayMode) async {
        guard !busy, client != nil else { return }
        await perform(.apply(mode)) { await $0.set(mode) }
        lastRefresh = clock()
    }

    /// 問い合わせ1回分。途中で接続先が切り替わったら、結果を捨てて何も変えない。取り消されたら true
    @discardableResult
    private func perform(_ trigger: ViewerResult.Trigger, _ request: (TargetControlling) async -> Result<RemoteState, ViewerFailure>) async -> Bool {
        guard let c = client else { return false }
        let gen = generation
        let before = (state: state, failure: failure)
        busy = true
        let result = await request(c)
        guard gen == generation else { return false }
        if case .failure(.cancelled) = result {
            // 取り消し: 状態も案内も変えない。処理中に選ばれた倍率は利用者の操作なので捨てず、
            // 取り消しを受け継がない Task で送る（呼び出し側の Task は取り消されているので、そのまま送るとすぐ `.cancelled` になる）
            busy = false
            if let mode = pendingMode {
                pendingMode = nil
                Task { await self.apply(mode) }
            }
            return true
        }
        handle(result)
        let suspected = failure == .unreachable ? await vpnCheck() : false
        // 経路の確認中に接続先が変わっていたら、その結果は前の接続先のものなので使わない
        guard gen == generation else { return false }
        vpnSuspected = suspected
        busy = false
        onResult?(ViewerResult(trigger: trigger, targetName: targetLabel, previousState: before.state, previousFailure: before.failure, state: state, failure: failure))
        // 処理中に選ばれた倍率があれば、ここで送る。ただし届かなかった直後は送り直さない
        // （選んだものは保存済みなので、カードを押すか選び直した時に適用される）
        if let mode = pendingMode {
            pendingMode = nil
            if failure != .unreachable { await apply(mode) }
        }
        return false
    }

    private func handle(_ result: Result<RemoteState, ViewerFailure>) {
        switch result {
        case .success(let s):
            state = s; failure = nil; failureDetail = nil; refusedAsPaused = false
            targetUnconfirmed = false   // 照合済みの応答が通れば確定（帳簿は `TargetSession` が書く）
        case .failure(let f):
            // Host が断った時（`set` への「一時停止中」、`set`・`status` への「処理中」）は状態を捨てない（照合済みの Host の応答で、接続はできている）。
            // 画面は直前の状態のまま読む（`connectionFailure`）。ただし、直前が接続できない失敗だった時は、手元の状態は届かなくなる前の古いもの
            // なので捨てる（古い状態を「今の状態」として出さない。状態をまだ知らない時と同じ見え方＝バッジ「未接続」・カードのバッジなし。点検 2i）
            if f.isRefusal, connectionFailure != nil { state = nil }
            failure = f
            if f.isRefusal { targetUnconfirmed = false }   // 断ったのは照合済みの Host（このペアリングは確定している。帳簿は `TargetSession` が書く。計画 2i）
            if f == .paused { state?.paused = true; refusedAsPaused = true }   // Host が「一時停止中」と答えた（次に取り直すまで、フッタとメニューの 1 行に出す）
            if !f.isRefusal { refusedAsPaused = false }    // 接続できなくなったら忘れる（「処理中」で断られた時は、覚えたまま）
            if case .other(let raw) = f { failureDetail = raw } else { failureDetail = nil }
        }
    }

    /// 接続できていない失敗（問い合わせそのものが通らなかった）。Host が照合済みの応答で断った時（一時停止中・処理中。`isRefusal`）は nil:
    /// 接続はできているので、接続のバッジ・メニューの 1 行・見出し・カードは直前の状態のままにし、何が起きたかは案内だけが言う（計画 2i）
    public var connectionFailure: ViewerFailure? { failure.flatMap { $0.isRefusal ? nil : $0 } }

    /// 接続先が一時停止中（直前の状態、または切り替えを「一時停止中」で断られた。状態をまだ知らない時にも分かるように、失敗の側も見る）
    public var hostPaused: Bool { connectionFailure == nil && (state?.paused == true || refusedAsPaused) }

    /// 接続先の機種名（接続できていない時は nil＝記号は一般の Mac）
    public var targetModel: String? { connectionFailure == nil ? state?.model : nil }

    // MARK: - カードごとの倍率

    /// そのディスプレイで使う倍率。選んでいなければ、その画面に合ったもの
    public func chosenMode(for d: LocalDisplay) -> DisplayMode {
        _ = preferenceVersion
        return preferences.mode(for: d) ?? d.recommended
    }

    /// 倍率を選んだ。覚えて、その場で適用する。処理中なら、終わった後に送る
    public func choose(_ mode: DisplayMode, for d: LocalDisplay) async {
        preferences.setMode(mode, for: d)
        preferenceVersion += 1
        if busy { pendingMode = mode; return }
        await apply(mode)
    }

    /// カードを押した。そのディスプレイ用に選んである倍率を適用する。処理中なら、終わった後に送る（最後に押したものだけ）
    public func applyChosen(for d: LocalDisplay) async {
        let mode = chosenMode(for: d)
        if busy { pendingMode = mode; return }
        await apply(mode)
    }

    // MARK: - 表示内容

    /// その画面向けの設定が選ばれている（保存されている）。枠の強調に使う
    public func isActive(_ d: LocalDisplay) -> Bool {
        guard connectionFailure == nil, let mode = state?.mode else { return false }
        return mode == chosenMode(for: d)
    }

    public enum CardBadge: Equatable { case none, applied, selected }

    /// カードのバッジ。「適用中」は仮想ディスプレイの倍率が実際に一致しているときだけ。
    /// 保存されているだけ（未接続・特定不能・反映待ち）なら「選択中」
    public func badge(for d: LocalDisplay) -> CardBadge {
        guard connectionFailure == nil, let s = state, let mode = s.mode, mode == chosenMode(for: d) else { return .none }
        if s.sessionActive, !s.virtualAmbiguous, let vd = s.virtualDisplay, vd.scaling == mode { return .applied }
        return .selected
    }

    /// 「適用する設定」の値（等幅で出す。解像度と倍率だけ）
    public func settingText(for d: LocalDisplay) -> String {
        let m = chosenMode(for: d)
        guard connectionFailure == nil, let v = state?.virtualDisplay else { return m.rawValue }
        return "\(v.logical.framebuffer(for: m)) · \(m.rawValue)"
    }

    /// 値の横に添える注記（ふつうの字で出す。等幅の値の中に入れると英語が語の途中で折り返すため。仕上げ 2026-09-30）。
    /// 画面共有が未接続のときだけ「接続後に適用」。状態が分からない・接続中で特定できない場合は付けない（画面共有の話に読めるため）。
    /// 付けるのは、接続先が保っている倍率（`mode`。オフでない）がこのカードで選んだ倍率と同じ時だけ（バッジが「選択中」のカード）。
    /// 違うカードは、案内のとおりクリックしないと適用されないため（点検 2f-1）
    public func settingNote(for d: LocalDisplay) -> String? {
        guard connectionFailure == nil, let s = state, s.virtualDisplay == nil, !s.sessionActive,
              let m = s.mode, m != .off, chosenMode(for: d) == m else { return nil }
        return tr("（接続後に適用）", "(applies when connected)")
    }

    /// VoiceOver 用。要点（ディスプレイ名・パネルの種類・倍率・状態）だけを読む
    public func accessibilityLabel(for d: LocalDisplay) -> String {
        let status: String
        switch badge(for: d) {
        case .applied: status = tr("適用中", "applied")
        case .selected: status = tr("選択中", "selected")
        case .none: status = tr("未適用", "not applied")
        }
        return tr("\(d.name)、\(d.panelLabel)。\(chosenMode(for: d).rawValue)、\(status)",
                  "\(d.name), \(d.panelLabel). \(chosenMode(for: d).rawValue), \(status)")
    }

    /// 調査用にコピーできる生の内容（通信の失敗、または接続先で記録された切り替えの失敗）
    public var copyableDetail: String? { failureDetail ?? (failure == nil ? state?.lastError : nil) }

    /// 見出しの名前: 利用者が付けた名前、無ければ相手のコンピュータ名（届かなければ帳簿の名前）
    public var title: String {
        if targetLabelIsAlias { return targetLabel }
        return (connectionFailure == nil ? state?.computerName : nil) ?? targetLabel
    }

    /// 接続先の設定（候補アドレス・ペアリング）を見直すべき失敗か（設定画面を開く導線を出す）
    public var suggestsSettings: Bool {
        switch failure {
        case .unreachable?, .notPaired?, .handshakeFailed?, .localNetworkDenied?: return true
        case .unsupportedVersion?, .paused?, .busy?, .timedOut?, .cancelled?, .other?, nil: return false
        }
    }

    /// 見出しの 2 行目。問い合わせに失敗した時は nil（出さない。何が起きたかは案内の見出しが 1 回だけ言う。
    /// 見出しの状態・接続のバッジ・案内の見出しの 3 か所で同じことを言っていた。計画 2f-1）。
    /// Host が断った時（一時停止中・処理中）は、直前の状態の 2 行目のまま（接続はできている。計画 2i）。
    /// 画面共有中で、接続先が選んだ倍率を実際に保っている時は「<倍率> を自動で保っています」（計画 2f-1 案 4。
    /// 解像度を並べると 1 行に収まらなかったため、この時は解像度を出さない。解像度はカードの「適用する設定」にある）
    public var headerDetail: String? {
        if busy && state == nil { return tr("確認しています…", "Checking…") }
        if connectionFailure != nil { return nil }
        guard let s = state else { return failure == nil ? tr("状態を取得できません", "Status unavailable") : nil }
        if s.virtualAmbiguous { return tr("仮想ディスプレイを特定できません", "Can’t identify the virtual display") }
        // 画面共有が未接続で仮想ディスプレイも無い時は出さない（バッジ「未接続」と案内「画面共有を始めると…」が言う。2f-1「2f-2 への注記」）
        guard let vd = s.virtualDisplay else { return s.sessionActive ? tr("仮想ディスプレイはありません", "No virtual display") : nil }
        if s.sessionActive, !s.paused, s.lastError == nil, let m = s.mode, m != .off, vd.scaling == m {
            return tr("\(m.label) を自動で保っています", "Keeping \(m.label) automatically")
        }
        return tr("仮想ディスプレイ", "Virtual display") + " \(vd.logical) · \(vd.scaling.label)"
    }

    /// フッタの 2 行目（接続先が倍率を自動で保っているか）。「自動維持」は分かりにくかったため、用語集に合わせて言い換えた（実機確認 2026-09-30）。
    /// 理由（一時停止・特定できない・取得できない）は見出しと案内が示すので、ここでは状態の語だけにする。倍率は見出しとカードにあるので重ねない。
    /// 接続できない間は「不明」（手元の状態は、届かなくなる前のもの。見出し・カードと同じく、今の状態として出さない。点検 2i）
    public var footerText: String {
        let label = tr("表示倍率を自動で保つ: ", "Keep display scale automatically: ")
        guard connectionFailure == nil, let s = state, let mode = s.mode else { return label + tr("不明", "unknown") }
        if mode != .off, s.paused { return label + tr("一時停止中", "paused") }
        if mode != .off, s.virtualAmbiguous { return label + tr("停止中", "stopped") }
        return label + (mode == .off ? tr("オフ", "off") : tr("オン", "on"))
    }

    /// 接続のバッジとメニューの 1 行の元（`connected`・`disconnected` は画面共有の接続。`failed` は接続先に接続できない）。
    /// Host が断った時（一時停止中・処理中）は `failed` にしない（接続はできている。直前の状態のまま。計画 2i）。
    /// 状態をまだ知らない時は、問い合わせる前と同じ `disconnected`
    public enum Connection: Equatable { case checking, failed, connected, disconnected }
    public var connection: Connection {
        if busy { return .checking }
        if connectionFailure != nil { return .failed }
        return state?.sessionActive == true ? .connected : .disconnected
    }

    /// 案内（優先度の高い順に1つだけ。`ViewerNotice`）。接続先が未登録なら「接続先を追加」
    public var notice: ViewerNotice.Text? {
        guard client != nil else {
            return ViewerNotice.Text(tr("接続先がまだありません", "No targets yet"),
                                     tr("接続先の Mac で ShareScale Host のメニューから「接続元の Mac を追加…」を選び、表示された接続コードを「接続先を追加」に貼り付けてください。",
                                        "On the Host, choose Add a Mac to Connect From… in the ShareScale Host menu, then paste the pairing code into Add Target."))
        }
        return ViewerNotice.make(state: state, failure: failure, targetName: targetLabel, unconfirmed: targetUnconfirmed, vpnSuspected: vpnSuspected,
                                 chosen: displays.map { chosenMode(for: $0) })
    }
}
