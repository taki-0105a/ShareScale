import Combine
import Foundation

/// 常駐している間に、Homebrew の新しい版を見つける（点検 2f-2。メニューバーに常駐するので、起動し直さないと引き渡しが起きにくい）。
/// 起動時と同じ判定（`Handoff.copyLaunch`）を、**ファイルを読むだけ**で行う（`app-state.json`・Homebrew 側の Info.plist と署名・バンドルの中の持ち主と権限）。
/// 前面に来た時・メニューを開いた時に呼ばれ、10 分に 1 回に間引く。読む処理は画面を止めないよう裏のスレッドで行う。
/// 見つけたら主の窓とメニューに「新しいバージョンがあります」と「ShareScale を終了して開き直す…」を出し、押されたら
/// 起動時の引き渡しと同じく、試みを記録してから Homebrew 側を開き、自分は終了する（Homebrew 側が複製を置き換えて開く）
@MainActor
public final class UpdateWatcher: ObservableObject {
    /// 引き渡せる新しい版（無ければ nil）
    public struct Pending: Equatable, Sendable {
        public let attempt: AppState.Attempt
        public let realPath: String
    }
    @Published public private(set) var pending: Pending?
    public static let interval: Duration = .seconds(600)

    private let role: AppRole
    private let stateFile: AppStateFile
    private let own: BundleFacts
    private let readSource: @Sendable (String) -> Handoff.SourceFacts
    private let safety: @Sendable (String) -> HandoffSafety.Problem?
    private let clock: () -> ContinuousClock.Instant
    private var lastCheck: ContinuousClock.Instant?
    private var checking = false

    /// - `own`: 自分（複製）の版と CDHash
    /// - `readSource`・`safety`: 実物は `Handoff.readSource`・`HandoffSafety.check`（起動時と同じ。読むだけ）
    public init(role: AppRole, stateFile: AppStateFile, own: BundleFacts,
                readSource: @escaping @Sendable (String) -> Handoff.SourceFacts = { Handoff.readSource($0) },
                safety: @escaping @Sendable (String) -> HandoffSafety.Problem?,
                clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.role = role; self.stateFile = stateFile; self.own = own; self.readSource = readSource; self.safety = safety; self.clock = clock
    }

    /// 確かめる（複製だけ。`force` でなければ 10 分に 1 回）
    public func check(force: Bool = false) async {
        guard role == .copy, !checking else { return }
        let now = clock()
        if !force, let last = lastCheck, now - last < Self.interval { return }
        lastCheck = now
        checking = true
        defer { checking = false }
        let (file, own, readSource, safety) = (stateFile, self.own, self.readSource, self.safety)
        let found = await Task.detached { Self.decide(state: file.load().state, own: own, readSource: readSource, safety: safety) }.value
        if found != pending { pending = found; failed = false }
    }

    /// 起動時と同じ判定（純粋に近い。読むのは `readSource`・`safety` の口だけ）
    nonisolated static func decide(state: AppState, own: BundleFacts, readSource: (String) -> Handoff.SourceFacts,
                                   safety: (String) -> HandoffSafety.Problem?) -> Pending? {
        let source = state.source.map(readSource)
        if case let .handoff(attempt, real) = Handoff.copyLaunch(state: state, source: source, own: own, safety: safety) {
            return Pending(attempt: attempt, realPath: real)
        }
        return nil
    }

    /// 切り替えられなかった（押した時に確かめ直して条件を満たさなくなった・開けなかった。再点検 2f-2）
    @Published public private(set) var failed = false

    /// 主の窓の案内（切り替えられなかった時はその 1 行を先に）
    public var notice: ViewerNotice.Text? {
        if failed { return Self.failureText }
        return pending == nil ? nil : Self.noticeText
    }
    public static var noticeText: ViewerNotice.Text {
        ViewerNotice.Text(tr("新しいバージョンがあります", "A new version is available"),
                          tr("ShareScale を終了して開き直すと切り替わります。", "Quit and reopen ShareScale to switch to it."))
    }
    public static var failureText: ViewerNotice.Text {
        ViewerNotice.Text(tr("新しいバージョンに切り替えられませんでした", "Couldn’t switch to the new version"),
                          tr("Homebrew でのアップデートが終わってから、もう一度選択してください。", "Wait for the Homebrew update to finish, then try again."))
    }
    public static var actionTitle: String { tr("ShareScale を終了して開き直す…", "Quit and Reopen ShareScale…") }

    /// 切り替える: **押した時に裏のスレッドで判定をもう一度行い**、見つけた時と同じ版・同じ実体の時だけ、試みを記録してから Homebrew 側を開き、
    /// 開けたら自分を終了する（起動時の引き渡しと同じ。見つけてから押すまでの間に Homebrew 側が変わった・条件を満たさなくなった時は開かない。再点検 2f-2）。
    /// 記録できない・開けない・確かめ直しで違った時は `failed`（主の窓に 1 行）。開けたら真
    @discardableResult
    public func handoff(open: (URL) -> Bool, terminate: () -> Void) async -> Bool {
        guard let p = pending, !checking else { return false }
        checking = true
        let (file, own, readSource, safety) = (stateFile, self.own, self.readSource, self.safety)
        let again = await Task.detached { Self.decide(state: file.load().state, own: own, readSource: readSource, safety: safety) }.value
        checking = false
        guard again == p, (try? stateFile.update { $0.attemptedHandoff = p.attempt }) != nil else {
            pending = again; failed = true
            return false
        }
        pending = nil
        guard open(URL(fileURLWithPath: p.realPath, isDirectory: true)) else { failed = true; return false }
        failed = false
        terminate()
        return true
    }
}
