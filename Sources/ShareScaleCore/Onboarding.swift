import Combine
import Foundation

/// 初回のガイドの段の移り変わり（計画 2f-2 案 3。純粋な状態機械）。
/// 1 画面目で「したいこと」を選ぶ: (a) この Mac から別の Mac を操作する → 接続先を追加する、
/// (b) この Mac を操作される側にする → この Mac を接続先にする → 接続元の Mac を追加する、(c) 両方 → (b) の後に (a)
public struct OnboardingFlow: Equatable, Sendable {
    public enum Goal: Equatable, Sendable, CaseIterable { case connectFrom, beTarget, both }
    public enum Step: Equatable, Sendable { case choose, hostSwitch, hostCode, addTarget }
    /// 「次へ」の結果（進んだ・ガイドを終える・まだ進めない）
    public enum Advance: Equatable, Sendable { case moved, finished, blocked }

    public private(set) var step: Step = .choose
    public private(set) var goal: Goal?
    public init() {}

    /// 起動時に出すか（接続先が 0 件・この Mac の接続先の役がオフ・ガイドを見た印が無い）
    public static func shouldShow(hasTargets: Bool, hostRoleOn: Bool, seen: Bool) -> Bool { !hasTargets && !hostRoleOn && !seen }

    public mutating func choose(_ g: Goal) {
        guard step == .choose else { return }
        goal = g
        step = g == .connectFrom ? .addTarget : .hostSwitch
    }

    /// 次へ。「この Mac を接続先にする」の段は Host が動いている時だけ進む。(b) は接続元の Mac を追加する段で、(a)(c) は接続先を追加する段で終わる
    public mutating func next(hostRunning: Bool) -> Advance {
        switch step {
        case .choose: return .blocked
        case .hostSwitch:
            guard hostRunning else { return .blocked }
            step = .hostCode; return .moved
        case .hostCode:
            if goal == .both { step = .addTarget; return .moved }
            return .finished
        case .addTarget: return .finished
        }
    }

    public mutating func back() {
        switch step {
        case .choose: break
        case .hostSwitch: step = .choose; goal = nil
        case .hostCode: step = .hostSwitch
        case .addTarget:
            if goal == .both { step = .hostCode } else { step = .choose; goal = nil }
        }
    }

    /// 段の番号と数（「1 / 3」。1 画面目は nil）
    public var progress: (index: Int, count: Int)? {
        guard let g = goal else { return nil }
        let steps: [Step]
        switch g {
        case .connectFrom: steps = [.addTarget]
        case .beTarget: steps = [.hostSwitch, .hostCode]
        case .both: steps = [.hostSwitch, .hostCode, .addTarget]
        }
        guard let i = steps.firstIndex(of: step) else { return nil }
        return (i + 1, steps.count)
    }
}

/// ガイドの 1 画面に出すもの（純粋な値。`OnboardingPage.make`）
public struct OnboardingPage: Equatable, Sendable {
    /// 1 画面目の選択肢（図は SF Symbols の 2 台の Mac と矢印）
    public struct Option: Equatable, Sendable {
        public let goal: OnboardingFlow.Goal
        public let title: String
        public let detail: String
        public let left: String, arrow: String, right: String
    }
    public struct PageButton: Equatable, Sendable {
        public let title: String
        public let enabled: Bool
    }
    public var title: String
    public var lead: String?
    public var options: [Option] = []
    /// 手順（番号を付けて並べる）
    public var steps: [String] = []
    /// 「この Mac を接続先にする」のスイッチを出す（`LoginItemController.model` を使う）
    public var showsHostSwitch = false
    /// Host が動いた時の一言
    public var hostStatus: String?
    /// 段の中の操作（「接続元の Mac を追加…」）
    public var action: PageButton?
    /// 右下の既定のボタン（「接続先を追加…」「次へ」「完了」）
    public var primary: PageButton?
    public var back: String?
    public var later: String
    public var progress: String?
    /// 図の下の呼び名
    public static var thisMac: String { tr("この Mac", "This Mac") }
    public static var otherMac: String { tr("別の Mac", "Another Mac") }

    /// - `hostRunning`: この Mac で ShareScale Host が動いている
    /// - `canAddTarget`: 「接続先を追加」を押せる（帳簿が使え、上限でない）
    /// - `issueCode`: 「接続元の Mac を追加…」の題名と押せるか（`HostPanelModel.issueCodeTitle`・`canIssueCode`）
    public static func make(_ flow: OnboardingFlow, hostRunning: Bool, canAddTarget: Bool, issueCode: (title: String, enabled: Bool)) -> OnboardingPage {
        let later = tr("あとで", "Later")
        let back = tr("戻る", "Back")
        // 段が 1 つだけの道（(a)）では「1 / 1」を出さない（点検 2f-2）
        let progress = flow.progress.flatMap { $0.count > 1 ? "\($0.index) / \($0.count)" : nil }
        switch flow.step {
        case .choose:
            return OnboardingPage(
                title: tr("ShareScale でしたいこと", "What do you want to do with ShareScale?"),
                lead: tr("選ぶと、必要な準備を順に案内します。", "Choose one, and ShareScale walks you through the setup."),
                options: [
                    Option(goal: .connectFrom, title: tr("この Mac から、画面共有で別の Mac を操作する", "Control another Mac from this Mac with Screen Sharing"),
                           detail: tr("別の Mac の表示倍率を、この Mac から切り替えます。", "Switch the other Mac’s display scale from this Mac."),
                           left: "laptopcomputer", arrow: "arrow.right", right: "desktopcomputer"),
                    Option(goal: .beTarget, title: tr("この Mac を、別の Mac から画面共有で操作される側にする", "Let another Mac control this Mac with Screen Sharing"),
                           detail: tr("別の Mac から、この Mac の表示倍率を切り替えられるようにします。", "Let other Macs switch this Mac’s display scale."),
                           left: "laptopcomputer", arrow: "arrow.left", right: "desktopcomputer"),
                    Option(goal: .both, title: tr("両方", "Both"),
                           detail: tr("この Mac から別の Mac を操作し、別の Mac からもこの Mac を操作します。", "Control other Macs from this Mac, and let other Macs control this Mac."),
                           left: "laptopcomputer", arrow: "arrow.left.arrow.right", right: "desktopcomputer"),
                ],
                later: later)
        case .addTarget:
            return OnboardingPage(
                title: tr("接続先を追加する", "Add a Target"),
                steps: [tr("接続先の Mac に ShareScale を入れて開き、設定 › この Mac の接続先で「この Mac を接続先にする」をオンにします。",
                           "On the Mac you want to control, install and open ShareScale, then turn on Use This Mac as a Target in Settings › This Mac as a Target."),
                        tr("接続先の Mac で「接続元の Mac を追加…」をクリックすると、接続コードが表示されます。",
                           "On that Mac, click Add a Mac to Connect From… to show a pairing code."),
                        tr("この Mac で「接続先を追加…」をクリックし、そのコードを貼り付けます。", "On this Mac, click Add Target… and paste the code.")],
                primary: PageButton(title: tr("接続先を追加…", "Add Target…"), enabled: canAddTarget),
                back: back, later: later, progress: progress)
        case .hostSwitch:
            return OnboardingPage(
                // 題名はスイッチ（「この Mac を接続先にする」）と同じ言葉にしない。説明はスイッチの下の文（`LoginItemController.model.note`）が言うので重ねない
                title: tr("この Mac を操作される側にする", "Get This Mac Ready to Be Controlled"),
                // ShareScale は画面共有そのものは入れないので、macOS の画面共有をオンにすることを先に言う（点検 2f-2）
                lead: tr("別の Mac から操作するには、この Mac で macOS の画面共有をオンにしておきます（システム設定 › 一般 › 共有 › 画面共有。ShareScale は画面共有そのものはオンにしません）。",
                         "To be controlled from another Mac, turn on Screen Sharing on this Mac (System Settings › General › Sharing › Screen Sharing). ShareScale doesn’t turn on Screen Sharing itself."),
                showsHostSwitch: true,
                hostStatus: hostRunning ? tr("ShareScale Host が動いています。", "ShareScale Host is running.") : nil,
                primary: PageButton(title: tr("次へ", "Next"), enabled: hostRunning),
                back: back, later: later, progress: progress)
        case .hostCode:
            return OnboardingPage(
                title: tr("接続元の Mac を追加する", "Add a Mac to Connect From"),
                steps: [tr("下の「接続元の Mac を追加…」をクリックすると、ShareScale Host の「接続コード」ウインドウに接続コードが表示されます。",
                           "Click Add a Mac to Connect From… below. The pairing code appears in ShareScale Host’s Pairing Code window."),
                        tr("接続元の Mac で ShareScale を開き、「接続先を追加…」にそのコードを貼り付けます。",
                           "On the Mac you’ll connect from, open ShareScale, click Add Target…, and paste the code."),
                        tr("この Mac に「接続元の Mac を追加」のウインドウが出たら、両方の Mac の確認番号が同じであることを見てから「追加する」をクリックします。",
                           "When the Add a Mac to Connect From window appears on this Mac, check that both Macs show the same confirmation number, then click Add.")],
                action: PageButton(title: issueCode.title, enabled: issueCode.enabled && hostRunning),
                primary: PageButton(title: flow.goal == .both ? tr("次へ", "Next") : tr("完了", "Done"), enabled: true),
                back: back, later: later, progress: progress)
        }
    }
}

/// 初回のガイドを出すか・どの段か（計画 2f-2 案 3）。ガイドを見た印は環境設定の `onboarding.seen`。
/// 「あとで」・「完了」・最後の段の操作で閉じ、印を付ける（次の起動からは出さない。設定 › 一般 の「はじめに…」でもう一度開ける）
@MainActor
public final class OnboardingGuide: ObservableObject {
    /// 出しているガイド（nil なら出していない）
    @Published public private(set) var flow: OnboardingFlow?
    private let store: StringStore
    public init(store: StringStore) { self.store = store }

    public var seen: Bool { store.string(forKey: "onboarding.seen") == "1" }

    /// 起動した時: 条件を満たせば出す
    public func showIfNeeded(hasTargets: Bool, hostRoleOn: Bool) {
        guard flow == nil, OnboardingFlow.shouldShow(hasTargets: hasTargets, hostRoleOn: hostRoleOn, seen: seen) else { return }
        flow = OnboardingFlow()
    }
    /// 設定 › 一般 の「はじめに…」: 1 画面目から出す
    public func open() { flow = OnboardingFlow() }
    /// 閉じる（「あとで」・完了）。印を付ける
    public func close() {
        flow = nil
        store.set("1", forKey: "onboarding.seen")
    }
    public func choose(_ g: OnboardingFlow.Goal) { flow?.choose(g) }
    public func back() { flow?.back() }
    /// 次へ。ガイドの最後なら閉じて `.finished` を返す（接続先を追加する段なら、呼び出し側が追加の窓を開く）
    @discardableResult
    public func next(hostRunning: Bool) -> OnboardingFlow.Advance {
        guard var f = flow else { return .blocked }
        let a = f.next(hostRunning: hostRunning)
        switch a {
        case .moved: flow = f
        case .finished: close()
        case .blocked: break
        }
        return a
    }
}
