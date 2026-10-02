import Combine
import Foundation

/// 「ShareScale を取り除く」の窓の状態（設定の「一般」と、起動時の「Homebrew から削除されました。取り除きますか？」から開く）。
/// 窓は 1 つ（`Window(id: "uninstall")`）で、この値の段階を並べる: 確かめ（何が消えるかの一覧）→ 取り除き中 → 結果。
/// - ログイン項目を登録・解除している間は始めない。取り除き中・取り除いた後はログイン項目のスイッチを押せなくする（点検 F）
/// - 窓を閉じたら `windowClosed()`: 確かめの途中なら取りやめ、中止の結果なら始め直せる状態に戻す（点検 O）
/// - 起動時に分かった「Homebrew から削除された」は覚えておき、設定から開いた時にも `brew uninstall` の案内を出さない（点検 O）
/// - 取り除いた後（中止でない結果）は `didRemove` が真になり、組み立ては帳簿の読み直し・環境設定の書き戻しを止める（点検 N）
@MainActor
public final class UninstallFlow: ObservableObject {
    public enum Stage: Equatable, Sendable { case idle, confirming, running, finished }
    @Published public private(set) var stage: Stage = .idle
    /// 起動時に複製元（Homebrew 側）が消えていた。主の窓が問いかける（「あとで」で下ろす）
    @Published public var askAfterHomebrewRemoval = false
    @Published public private(set) var uninstaller: Uninstaller?
    /// 取り除いた（中止でない結果が出た）。以後、帳簿の読み直し・環境設定の書き戻しをしない
    @Published public private(set) var didRemove = false
    public private(set) var homebrewRemoved = false

    public let role: AppRole
    public let paths: AppPaths
    private let targets: ViewerTargets
    private let loginItems: LoginItemController?
    /// 「ログイン時に ShareScale を開く」（取り除きの間と後は押せない。計画 2f-2）
    private let openAtLogin: OpenAtLoginController?
    private let makePorts: () -> UninstallPorts

    public init(role: AppRole, paths: AppPaths, targets: ViewerTargets, loginItems: LoginItemController? = nil, openAtLogin: OpenAtLoginController? = nil,
                makePorts: @escaping () -> UninstallPorts) {
        self.role = role; self.paths = paths; self.targets = targets; self.loginItems = loginItems; self.openAtLogin = openAtLogin; self.makePorts = makePorts
    }

    /// 起動時に複製元が消えていた（問いかけを出し、以後の取り除きでも brew の案内を出さない）
    public func noteHomebrewRemoved() {
        homebrewRemoved = true
        askAfterHomebrewRemoval = true
    }

    /// 押せるか（複製だけ。ログイン項目を登録・解除している間と、取り除いた後は押せない）と、押せない時の理由
    /// 「ログイン時に開く」を登録し直している間（3 秒待つ間を含む）も押せない（再点検 2f-2）
    public var available: Bool { role.canUninstall && !loginItemsBusy && !didRemove }
    private var loginItemsBusy: Bool { (loginItems?.busy ?? false) || (openAtLogin?.busy ?? false) }
    public var note: String {
        if !role.canUninstall { return Self.unavailableNote }
        if didRemove { return tr("ShareScale は削除されました。ShareScale を終了してください。", "ShareScale was removed. Quit ShareScale.") }
        if loginItemsBusy {
            return tr("ログイン項目を変更しています。終わってから削除してください。", "The login item is being changed. Remove ShareScale after it finishes.")
        }
        return Self.availableNote
    }
    /// 「一般」の説明（書き出しでも使う）
    public static var availableNote: String {
        tr("ログイン項目・ペアリングの鍵・設定・ログと、このアプリを削除します。接続先には、この Mac の登録を解除するよう伝えます。",
           "Removes the login item, pairing keys, settings, logs and this app. Targets are asked to remove this Mac.")
    }
    public static var unavailableNote: String {
        tr("完全な削除は ~/Applications の ShareScale からだけ行えます。", "Complete removal is only available from ShareScale in ~/Applications.")
    }

    /// 確かめの一覧
    public var plannedItems: [String] {
        Uninstaller.plannedItems(paths: paths, targetNames: targets.loaded.sortedByName.map(\.displayName), homebrewRemoved: homebrewRemoved)
    }

    /// 確かめを始める（中止の結果からも始め直せる）
    public func begin() {
        guard available else { return }
        switch stage {
        case .idle, .confirming: break
        case .finished where uninstaller?.report?.aborted != nil: uninstaller = nil; loginItems?.unlockAfterRemoval(); openAtLogin?.unlockAfterRemoval()
        case .running, .finished: return
        }
        askAfterHomebrewRemoval = false
        targets.reload()
        stage = .confirming
    }

    /// 確かめの窓の「やめる」（取り除き中・結果の時は何もしない）
    public func cancel() { if stage == .confirming { stage = .idle } }

    /// 取り除く（画面に結び付かない Task で進める）。始める時にもう一度、ログイン項目の処理中でないことを確かめる
    public func confirm() {
        guard stage == .confirming, available else { return }
        let u = Uninstaller(paths: paths, ports: makePorts())
        uninstaller = u
        stage = .running
        loginItems?.lockForRemoval(); openAtLogin?.lockForRemoval()
        let list = targets.loaded.sortedByName.map { (id: $0.id, name: $0.displayName) }
        let removed = homebrewRemoved
        Task {
            let report = await u.run(targets: list, homebrewRemoved: removed)
            self.stage = .finished
            if report.aborted == nil { self.didRemove = true }
        }
    }

    /// 窓を閉じた: 確かめの途中なら取りやめ、中止の結果なら始め直せる状態に戻す（取り除き中・取り除いた後はそのまま）
    public func windowClosed() {
        switch stage {
        case .confirming: stage = .idle
        case .finished where uninstaller?.report?.aborted != nil:
            stage = .idle; uninstaller = nil
            loginItems?.unlockAfterRemoval(); openAtLogin?.unlockAfterRemoval()
        default: break
        }
    }
}
